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
    [string]$Video = '',
    [string]$Negative = '',
    [int]$Width = 0,
    [int]$Height = 0,
    [int]$Steps = 0,
    [int]$Resolution = 0,
    [int]$NeedMiB = 0,
    [int]$Count = 1,        # 一次提交多张（同一批只卸载/恢复一次）
    [string]$Seeds = '',    # 逗号分隔种子，例 101,202,303
    [string]$Extra = '',
    [switch]$Wait,          # 阻塞等待：作业跑完 + 守护批末标记 + 本地聊天后端恢复就绪后返回
    [int]$TimeoutSec = 600,   # -Wait 最长等多久（守护不受影响，超时只是脚本先返回）
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
    'aiup'     = @{ step = 'aiup';     script = 'AI超分.ps1';       need = 16500; desc = 'SeedVR2 视频 AI 超分（720p/1080p）' }
    'sfx'      = @{ step = 'sfx';      script = '音效生成.ps1';     need = 14000; desc = '文生音效/BGM（AudioLDM2）' }
    'h3'       = @{ step = 'h3';       script = '文本生视频H3快照.ps1'; need = 22000; desc = 'H3 带音频视频（约 113 秒）' }
    'i2v'      = @{ step = 'i2v';      script = '图生视频.ps1';     need = 17000; desc = 'Wan 图生视频（无声）' }
    'smarti2v' = @{ step = 'smarti2v'; script = '智能出片.ps1'; need = 17000; desc = '智能图生视频（自动单段/插帧/续接）' }
    'videodub' = @{ step = 'videodub'; script = 'D:\audio-tools\视频配音提示词.ps1'; need = 14000; desc = '视频自动配音（视觉理解+旁白+TTS+字幕）' }
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
if ($Video) { $argsList += @('-Video', $Video) }
if ($Negative) { $argsList += @('-Negative', $Negative) }
if ($Width -gt 0) { $argsList += @('-Width', "$Width") }
if ($Height -gt 0) { $argsList += @('-Height', "$Height") }
if ($Steps -gt 0) { $argsList += @('-Steps', "$Steps") }
if ($Resolution -gt 0) { $argsList += @('-Resolution', "$Resolution") }
if ($Task -eq 'videodub') {
    if ($Extra -notmatch 'Mode=') { $argsList += @('-Mode', 'auto') }
    if ($Extra -notmatch 'BurnSubtitles') { $argsList += '-BurnSubtitles' }
    if ($Extra -match 'KeepOriginal') { $argsList += '-KeepOriginal' }
}
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

# ---- 提交前校验：目标脚本是否支持这些参数（避免白跑一次卸载/恢复，2026-10-25 踩坑）----
$scriptPathForCheck = if ([IO.Path]::IsPathRooted($def.script)) { $def.script } else { Join-Path $PSScriptRoot $def.script }
$sup = Get-ScriptParamSet $scriptPathForCheck
$badParams = @()
if ($argsList.Count -gt 0) {
    for ($bi = 0; $bi -lt $argsList.Count; $bi++) {
        $tok = [string]$argsList[$bi]
        if ($tok -like '-*') {
            $pname = $tok.TrimStart('-')
            if (-not $sup.ContainsKey($pname.ToLower())) { $badParams += $tok }
        }
    }
}
if ($badParams.Count -gt 0) {
    Write-Host ''
    Write-Host ('  ✗ 任务 ' + $Task + ' 不支持参数：' + ($badParams -join ', ')) -ForegroundColor Red
    Write-Host ('    该任务的脚本是 ' + $def.script + '，支持的参数：') -ForegroundColor Yellow
    Write-Host ('      ' + (($sup.Keys | Sort-Object | ForEach-Object { '-' + $_ }) -join ' ')) -ForegroundColor DarkGray
    switch ($Task) {
        'krea2' { Write-Host '    提示：Krea2 是纯文生图（没有 -Image）。要按图改图请用 -Task edit；要风格化请加 -Extra "Lora=softwatercolor:0.8"' -ForegroundColor Yellow }
        'zimage' { Write-Host '    提示：Z画图支持 -Image 做图生图/局部重绘（配 -Denoise）；纯文生图只给 -Prompt。' -ForegroundColor Yellow }
        'moss'  { Write-Host '    提示：MOSS 是纯文生图，不接受 -Image。' -ForegroundColor Yellow }
        'pixeldit' { Write-Host '    提示：PixelDiT 是纯文生图，不接受 -Image。' -ForegroundColor Yellow }
        default { Write-Host '    请对照上面的参数列表改写本次调用。' -ForegroundColor Yellow }
    }
    Write-Host '    未提交任何作业（没有占用队列/显存）。' -ForegroundColor DarkGray
    exit 1
}

$free = Get-FreeVramMiB
$short = if ($Prompt) { $Prompt.Substring(0, [Math]::Min(60, $Prompt.Length)) } else { '(' + $Task + ')' }

# ---- 情况 1：显存够 → 同步跑，不卸载聊天后端 ----
# ---- 情况 1：显存够 且 只提交 1 张 → 同步跑，不卸载聊天后端 ----
if ($free -ge $NeedMiB -and $Count -eq 1) {
    # 同步互斥：两条命令同时提交时，后到的那条必须让路（否则会抢 ComfyUI 端口）
    $syncLock = $null
    try { $syncLock = [System.IO.File]::Open((Join-Path $jobsRoot 'sync.lock'), 'OpenOrCreate', 'ReadWrite', 'None') } catch { $syncLock = $null }
    if (-not $syncLock) {
        Write-Host '  已有同步任务在跑 → 本次改走队列（由守护串行执行）' -ForegroundColor Yellow
    } else {
    try {
            Write-Host ''
            Write-Host ('== 同步执行（显存充足 {0:N1} GB ≥ {1:N1} GB，不卸载聊天模型）==' -f ($free / 1024), ($NeedMiB / 1024)) -ForegroundColor Cyan
            $scriptPath = if ([IO.Path]::IsPathRooted($def.script)) { $def.script } else { Join-Path $PSScriptRoot $def.script }
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
            $reProd = '(?:成品|编辑完成|超分完成|视频完成|音频完成|输出文件|视频|音频|图片|结果文件|输出|产物)[：:]\s*(.+?\.(?:png|jpg|jpeg|webp|mp4|mov|srt|wav|mp3))'
            # 补充：图生视频等脚本产物行是顶格的「视频：<路径>」「音频: <路径>」，上面的正则匹配不到（2026-10-26 踩坑修）
            $reProdLine = '(?m)^\s*(?:视频|音频)[：:]\s*(.{1,300}?\.(?:mp4|mov|wav|mp3))\s*$'
            $m = [regex]::Match($text, $reProd, 'IgnoreCase')
            if (-not $m.Success) { $m = [regex]::Match($text, $reProdLine, 'IgnoreCase') }
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
    } finally {
        if ($syncLock) { try { $syncLock.Dispose() } catch { } }
    }
    }
}
# 提交时刻：-Wait 用它判断 last-batch.json 是否属于本批
$submittedAtLocal = Get-Date

# ---- 情况 2：写队列（支持 -Count / -Seeds，一次提交多张 → 同一批只卸载/恢复一次）----
if ($Seeds) {
    $seedList = @(($Seeds -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($seedList.Count -gt 0 -and $Count -le 1) { $Count = $seedList.Count }
}
if ($Count -lt 1) { $Count = 1 }
if ($Count -gt 16) { $Count = 16 }   # 安全上限，避免一次排太多

$ids = @()
for ($bi = 0; $bi -lt $Count; $bi++) {
    # 每个作业独立的参数副本
    $jobArgs = New-Object System.Collections.ArrayList
    foreach ($a in $argsList) { [void]$jobArgs.Add($a) }

    # 分配种子：优先用 -Seeds 列表；没有就让脚本自己随机
    if ($seedList.Count -gt $bi) {
        $seedVal = $seedList[$bi]
        $si = $jobArgs.IndexOf('-Seed')
        if ($si -ge 0 -and ($si + 1) -lt $jobArgs.Count) {
            $jobArgs[$si + 1] = $seedVal
        } else {
            [void]$jobArgs.Add('-Seed'); [void]$jobArgs.Add($seedVal)
        }
    }

    # 作业 ID：毫秒 + 随机，避免同秒覆盖
    $jid = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + $Task + '-' + (Get-Random -Minimum 100 -Maximum 999)
    $gcnt = 0
    while (Test-Path (Join-Path $pendingDir ($jid + '.json'))) {
        $gcnt++
        if ($gcnt -gt 5) { $jid = (Get-Date -Format 'yyyyMMdd-HHmmss-fff-ffff') + '-' + $Task; break }
        $jid = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + $Task + '-' + (Get-Random -Minimum 100 -Maximum 999)
    }

    $job = [pscustomobject]@{
        id      = $jid
        task    = $Task
        script  = $def.script
        args    = @($jobArgs)
        needMiB = $NeedMiB
        prompt  = $Prompt
        image   = $Image
        seed    = $(if ($seedList.Count -gt $bi) { $seedList[$bi] } else { '' })
        created = (Get-Date).ToString('o')
        status  = 'pending'
    }
    $job | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $pendingDir ($jid + '.json')) -Encoding UTF8
    $ids += $jid
}

Write-Host ''
Write-Host ('== 已排队 {0} 个作业 ==' -f $Count) -ForegroundColor Cyan
Write-Host ('  任务：' + $Task + '（' + $def.desc + '）')
Write-Host ('  内容：' + $short)
Write-Host ('  显存：当前 {0:N1} GB 可用，需要 {1:N1} GB → 守护会卸载聊天模型，跑完自动恢复' -f ($free / 1024), ($NeedMiB / 1024))
for ($i = 0; $i -lt $ids.Count; $i++) {
    $sd = if ($seedList.Count -gt $i) { '  种子 ' + $seedList[$i] } else { '  种子由脚本随机' }
    Write-Host ('    ' + $ids[$i] + $sd)
}
if ($Count -gt 1) {
    Write-Host ('  这 ' + $Count + ' 个作业会由守护进程一次性卸载、连续跑完、再恢复一次（省掉 N-1 次恢复）。') -ForegroundColor Green
}
Write-Host '  说明：本脚本不会卸载聊天模型；跑完守护会自动恢复，结果写入 .jobs\done\' -ForegroundColor DarkGray

# 守护进程在不在？
$guardProc = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match '作业守护\.ps1' }
if (-not $guardProc) {
    Write-Host ''
    Write-Host '  ⚠ 守护进程没在跑，作业不会被立刻执行。' -ForegroundColor Yellow
    Write-Host '  → 请让用户双击桌面「守护 - 全部启动」（本会话没有权限启动守护，也不要用 Start-Process 兜底）。' -ForegroundColor Yellow
    Write-Host '  → 作业已保留在队列里，守护一启动就会自动执行。' -ForegroundColor DarkGray
    exit 2
}

if ($Wait) {
    Write-Host ''
    Write-Host ('  等待 {0} 个作业执行完、聊天后端恢复就绪…' -f $ids.Count) -ForegroundColor DarkGray
    . (Join-Path $PSScriptRoot '_wait.ps1')
    if (-not (Get-Command Get-LocalBackends -ErrorAction SilentlyContinue)) {
        try { . (Join-Path $PSScriptRoot '_backend.ps1') } catch { }
    }
    # DSH 当前模型是不是本地 chat 后端？只有本地会话才需要等后端就绪
    $isLocalChat = $false
    try {
        $dsh = Get-DshDefaultModel
        if ($dsh -and $dsh.provider -match '^(strata|ollama|ninfer)') { $isLocalChat = $true }
    } catch { }

    $r = Wait-BatchReady -Ids $ids -JobsRoot $jobsRoot -SubmittedAt $submittedAtLocal -TimeoutSec $TimeoutSec -RequireBackend $isLocalChat
    Write-Host ''
    $okCount = 0
    foreach ($qid in $ids) {
        $dp = Join-Path $doneDir ($qid + '.json')
        if (-not (Test-Path $dp)) {
            Write-Host ('  {0}  仍在执行/超时' -f $qid) -ForegroundColor Yellow
            continue
        }
        $rr = Get-Content $dp -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($rr.status -eq 'done') {
            $okCount++
            Write-Host ('  ✓ {0}  {1:N0}s  {2}' -f $qid, [double]$rr.seconds, (Split-Path $rr.product -Leaf)) -ForegroundColor Green
            if ($rr.product) { Write-Host ('     ' + $rr.product) -ForegroundColor DarkGray }
        } else {
            Write-Host ('  ✗ {0}  失败：{1}' -f $qid, $rr.error) -ForegroundColor Red
        }
    }
    Write-Host ''
    if ($isLocalChat -and -not $r.beOk) {
        Write-Host ('  ⚠ 聊天后端可能还没完全就绪（{0}）；作业已结束，可稍等再试。' -f $r.backendDesc) -ForegroundColor Yellow
    } elseif ($isLocalChat) {
        Write-Host ('  ✓ 聊天后端已就绪：{0}（等待 {1} 秒）' -f $r.backendDesc, $r.elapsedSec) -ForegroundColor Green
        Write-Host '  → 可以直接继续下一步，不需要用户再发消息。' -ForegroundColor DarkGray
    } else {
        Write-Host ('  ✓ 作业已结束（云端会话，不需要等本地后端；等待 {0} 秒）' -f $r.elapsedSec) -ForegroundColor Green
    }
    if ($r.timedOut) { Write-Host '  ⚠ 等待超时：守护可能仍在跑批，用 提交作业.ps1 -Status 查看进度。' -ForegroundColor Yellow }
    Write-Host ('  完成 {0}/{1}' -f $okCount, $ids.Count) -ForegroundColor $(if ($okCount -eq $ids.Count) { 'Green' } else { 'Yellow' })
    exit $(if ($okCount -eq $ids.Count) { 0 } else { 1 })
}
exit 0
