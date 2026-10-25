# 提交作业：给"本地聊天模型"用的安全出图入口
#
# 为什么需要它：
#   本地聊天模型（Strata / Ollama）如果直接跑出图脚本，脚本会为腾显存把聊天模型自己卸载掉
#   → 对话立刻断线（TRANSPORT Connection error），后续步骤（含恢复）没人执行。
#   本脚本只做两件事：显存够就【同步出图】（不卸载自己）；不够就【写进队列】交给作业守护进程处理，
#   自己立刻返回，绝不卸载聊天后端。
#
# 用法（模型调用）：
#   .\提交作业.ps1 -Task zimage -Prompt "海边灯塔，黄昏"
#   .\提交作业.ps1 -Task edit -Image x.png -Prompt "把外套换成红色"
#   .\提交作业.ps1 -Task krea2 -Prompt "..." -Extra "Lora=softwatercolor:0.8"
#   .\提交作业.ps1 -List          # 看支持哪些 Task
#   .\提交作业.ps1 -Status        # 看队列状态
param(
    [string]$Task = '',
    [string]$Prompt = '',
    [string]$Image = '',
    [string]$Negative = '',
    [int]$Width = 0,
    [int]$Height = 0,
    [int]$Steps = 0,
    [int]$Resolution = 0,
    [int]$NeedMiB = 0,
    [string]$Extra = '',
    [switch]$Wait,          # 排队后在前台等结果（会阻塞，但不会断线）
    [int]$TimeoutSec = 1800,
    [switch]$List,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_vram.ps1')

# 读取脚本支持的参数名，避免给不支持 -NoPause / -KeepChatBackend 的脚本传错参数
function Get-ScriptParamSet {
    param([string]$path)
    $set = @{}
    try {
        $errs = $null; $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errs)
        if ($ast.ParamBlock) {
            foreach ($p in $ast.ParamBlock.Parameters) { $set[$p.Name.VariablePath.UserPath.ToLower()] = $true }
        }
    } catch { }
    return $set
}

# ---- 补丁点：参数过滤 ----
function Add-SupportedSwitch {
    param([System.Collections.ArrayList]$list, $supported, [string]$name)
    if ($supported.ContainsKey($name.ToLower())) { [void]$list.Add('-' + $name) }
}

# 保险：本脚本任何时候都不允许卸载"自己"（允许=1 只给守护进程用）
$env:PIPE_ALLOW_SELF_UNLOAD = '0'

$jobsRoot = Join-Path $PSScriptRoot '.jobs'
$pendingDir = Join-Path $jobsRoot 'pending'
$doneDir = Join-Path $jobsRoot 'done'
$runningDir = Join-Path $jobsRoot 'running'
foreach ($d in @($jobsRoot, $pendingDir, $doneDir, $runningDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# ---- 任务表：task → 脚本 + 参数构造 + 显存需求 ----
$tasks = @{
    'zimage'   = @{ step = 'zimage';   script = 'Z画图.ps1';        need = 14000; desc = 'Z-Image 快速出图（4~5 秒）' }
    'moss'     = @{ step = 'moss';     script = 'MOSS画图.ps1';     need = 15000; desc = 'MOSS 写实人像（10~14 秒）' }
    't2i'      = @{ step = 't2i';      script = '画图.ps1';         need = 16000; desc = 'Qwen-Image Turbo（约 15 秒）' }
    'krea2'    = @{ step = 'krea2';    script = 'Krea2画图.ps1';    need = 19000; desc = 'Krea 2 审美/风格（3~12 秒）' }
    'pixeldit' = @{ step = 'pixeldit'; script = 'PixelDiT画图.ps1'; need = 11000; desc = 'PixelDiT 1.3B（约 12 秒）' }
    'edit'     = @{ step = 'edit';     script = '编辑.ps1';         need = 21000; desc = '指令编辑 Qwen-Edit-2511（约 190 秒）' }
    'inpaint'  = @{ step = 'inpaint';  script = '局部重绘.ps1';     need = 14000; desc = '局部重绘/去物（约 10 秒）' }
    'pid'      = @{ step = 'pid';      script = 'PiD超分.ps1';      need = 21000; desc = 'PiD 4× 超分（12~37 秒）' }
    'upscale'  = @{ step = 'upscale';  script = '图片超分.ps1';     need = 16000; desc = 'SeedVR2 图片超分（含 4K）' }
    'h3'       = @{ step = 'h3';       script = '文本生视频H3快照.ps1'; need = 22000; desc = 'H3 带音频视频（约 113 秒）' }
    'i2v'      = @{ step = 'i2v';      script = '图生视频.ps1';     need = 17000; desc = 'Wan 图生视频（无声）' }
}

function Show-Tasks {
    Write-Host ''
    Write-Host '== 可用任务 ==' -ForegroundColor Cyan
    $tasks.Keys | Sort-Object | ForEach-Object {
        $t = $tasks[$_]
        '  {0,-10} 需要 {1,6:N0} MiB  {2}' -f $_, $t.need, $t.desc
    }
    Write-Host ''
    Write-Host '  用法：-Task zimage -Prompt "..." [-Width 832 -Height 1216 -Steps 8 -Extra "Lora=xxx"]'
}

function Show-Status {
    Write-Host ''
    Write-Host '== 作业队列 ==' -ForegroundColor Cyan
    foreach ($pair in @(@{ n='等待中'; d=$pendingDir }, @{ n='执行中'; d=$runningDir }, @{ n='已完成'; d=$doneDir })) {
        $files = @(Get-ChildItem $pair.d -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        Write-Host ('  [' + $pair.n + '] ' + $files.Count + ' 个')
        $files | Select-Object -First 5 | ForEach-Object {
            try {
                $j = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                '    {0}  {1,-8} {2}' -f $_.BaseName, $j.task, $(if ($j.prompt) { $j.prompt.Substring(0, [Math]::Min(40, $j.prompt.Length)) } else { '' })
                if ($j.status -eq 'done' -and $j.product) { '      成品: ' + $j.product }
                if ($j.status -eq 'failed') { '      失败: ' + $j.error }
            } catch { '    ' + $_.BaseName }
        }
    }
}

if ($List -or (-not $Task)) { Show-Tasks; if (-not $Task) { Write-Host ''; Write-Host '  ⚠ 没给 -Task' -ForegroundColor Yellow }; exit 0 }
if ($Status) { Show-Status; exit 0 }
if (-not $tasks.ContainsKey($Task)) {
    Write-Host ('  ✗ 未知任务：' + $Task) -ForegroundColor Red
    Show-Tasks
    exit 1
}

$def = $tasks[$Task]
if ($NeedMiB -le 0) { $NeedMiB = $def.need }

# ---- 组装参数 ----
$argsList = @()
if ($Prompt) { $argsList += @('-Prompt', $Prompt) }
if ($Image) { $argsList += @('-Image', $Image) }
if ($Negative) { $argsList += @('-Negative', $Negative) }
if ($Width -gt 0) { $argsList += @('-Width', "$Width") }
if ($Height -gt 0) { $argsList += @('-Height', "$Height") }
if ($Steps -gt 0) { $argsList += @('-Steps', "$Steps") }
if ($Resolution -gt 0) { $argsList += @('-Resolution', "$Resolution") }
if ($Extra) {
    foreach ($kv in ($Extra -split ';')) {
        $kv = $kv.Trim()
        if (-not $kv) { continue }
        $i = $kv.IndexOf('=')
        if ($i -gt 0) {
            # 注意：@('-' + $a, $b) 在 PowerShell 里会拼成一个字符串，必须分两步加
            $pname = $kv.Substring(0, $i).Trim()
            $pval = $kv.Substring($i + 1).Trim()
            $argsList += ('-' + $pname)
            $argsList += $pval
        }
    }
}

$free = Get-FreeVramMiB
$short = if ($Prompt) { $Prompt.Substring(0, [Math]::Min(60, $Prompt.Length)) } else { '(' + $Task + ')' }

# ---- 情况 1：显存够 → 同步跑，不卸载聊天后端 ----
if ($free -ge $NeedMiB) {
    Write-Host ''
    Write-Host ('== 同步执行（显存充足 {0:N1} GB ≥ {1:N1} GB，不卸载聊天模型）==' -f ($free / 1024), ($NeedMiB / 1024)) -ForegroundColor Cyan
    $scriptPath = Join-Path $PSScriptRoot $def.script
    $sup = Get-ScriptParamSet $scriptPath
    $switches = New-Object System.Collections.ArrayList
    Add-SupportedSwitch $switches $sup 'KeepChatBackend'
    Add-SupportedSwitch $switches $sup 'NoPause'
    Add-SupportedSwitch $switches $sup 'NoOpen'
    $runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $argsList + @($switches)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' @runArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    $sw.Stop()
    $text = ($out | ForEach-Object { [string]$_ }) -join "`n"
    $prod = ''
    $m = [regex]::Match($text, '成品[：:]\s*(.+?)(\r?\n|$)')
    if ($m.Success) { $prod = ($m.Groups[1].Value -split '\s{2,}')[0].Trim() }
    if ($code -eq 0 -and $prod) {
        Write-Host ''
        Write-Host ('  完成 {0:N1} 秒' -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
        Write-Host ('  成品：' + $prod) -ForegroundColor Green
        Write-Host '  （聊天模型未被卸载，对话未中断）' -ForegroundColor DarkGray
        exit 0
    }
    Write-Host ('  ✗ 同步执行失败（退出码 ' + $code + '）') -ForegroundColor Red
    ($text -split "`n" | Select-Object -Last 12) | ForEach-Object { '  ' + $_ }
    Write-Host '  改走队列（由守护进程卸载聊天模型后重试）…' -ForegroundColor Yellow
}

# ---- 情况 2：显存不够 → 写队列，交给守护进程 ----
# 作业 ID：毫秒 + 随机后缀，避免同秒提交互相覆盖（实测过这个坑）
$id = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + $Task + '-' + (Get-Random -Minimum 100 -Maximum 999)
$guard = 0
while (Test-Path (Join-Path $pendingDir ($id + '.json'))) {
    $guard++
    if ($guard -gt 5) {
        $id = (Get-Date -Format 'yyyyMMdd-HHmmss-fff-ffff') + '-' + $Task
        break
    }
    $id = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + $Task + '-' + (Get-Random -Minimum 100 -Maximum 999)
}
$job = [pscustomobject]@{
    id        = $id
    task      = $Task
    script    = $def.script
    args      = $argsList
    needMiB   = $NeedMiB
    prompt    = $Prompt
    image     = $Image
    created   = (Get-Date).ToString('o')
    status    = 'pending'
}
$jobPath = Join-Path $pendingDir ($id + '.json')
$job | ConvertTo-Json -Depth 6 | Set-Content -Path $jobPath -Encoding UTF8

Write-Host ''
Write-Host '== 已排队 ==' -ForegroundColor Cyan
Write-Host ('  任务：' + $Task + '（' + $def.desc + '）')
Write-Host ('  内容：' + $short)
Write-Host ('  显存：当前 {0:N1} GB 可用，需要 {1:N1} GB → 由守护进程卸载聊天模型后再跑' -f ($free / 1024), ($NeedMiB / 1024))
Write-Host ('  作业号：' + $id)
Write-Host '  说明：聊天模型不会被本脚本卸载，对话保持连接；' -ForegroundColor DarkGray
Write-Host '        守护进程会在跑完后自动恢复聊天模型，结果写入 .jobs\done\' -ForegroundColor DarkGray

# 守护进程在不在？
$guard = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match '作业守护\.ps1' }
if (-not $guard) {
    Write-Host ''
    Write-Host '  ⚠ 守护进程没在跑！作业不会被执行。请先双击「作业守护 - 启动」' -ForegroundColor Yellow
    exit 2
}

if ($Wait) {
    Write-Host ''
    Write-Host '  等待守护进程执行…' -ForegroundColor DarkGray
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $donePath = Join-Path $doneDir ($id + '.json')
        if (Test-Path $donePath) {
            $r = Get-Content $donePath -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Host ''
            if ($r.status -eq 'done') {
                Write-Host ('  完成：' + $r.product) -ForegroundColor Green
                Write-Host ('  耗时：{0:N1} 秒' -f [double]$r.seconds)
            } else {
                Write-Host ('  失败：' + $r.error) -ForegroundColor Red
            }
            Write-Host '  （聊天模型已由守护进程恢复）' -ForegroundColor DarkGray
            exit $(if ($r.status -eq 'done') { 0 } else { 1 })
        }
    }
    Write-Host '  等待超时，作业可能还在跑；用 -Status 查看进度。' -ForegroundColor Yellow
    exit 3
}
exit 0
