# 流水线执行器：按配方（JSON）把多个工具串起来跑，每步留痕
#
# 用法：
#   .\流水线.ps1 -Recipe 图生带字幕视频 -Set 'Image=C:\path\a.png' -Out 项目A
#   .\流水线.ps1 -Recipe 图生带字幕视频 -Set "Image=..." -DryRun       # 只打印命令
#   .\流水线.ps1 -Recipe audio-chain -Set "Audio=..." -Only "denoise,transcribe"
#   .\流水线.ps1 -Recipe ... -Resume                                  # 断点续跑
#
# 约定：
#   · 配方在 D:\qwen-image-2.1\recipes\*.json
#   · 任务目录：桌面\流水线\<配方名>-<时间>\
#   · 每步产物落到 <任务目录>\<序号>-<步骤id>\
#   · manifest.json 记录每步参数/耗时/产物，可据此 Resume
param(
    [Parameter(Mandatory = $true)][string]$Recipe,
    [string]$Set = '',                   # key=value，多个用分号分隔：Audio=x.wav;Language=zh
    [string]$Out = '',                    # 任务目录名（默认 配方名-时间戳）
    [string]$Only = '',                  # 只跑这些步骤 id（逗号分隔）
    [switch]$DryRun,
    [switch]$Resume,
    [switch]$KeepIntermediate,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$root = 'D:\qwen-image-2.1'
$recipeDir = Join-Path $root 'recipes'
$desktop = [Environment]::GetFolderPath('Desktop')
$pipelineRoot = Join-Path $desktop '流水线'

function Write-H { param([string]$t) Write-Host ''; Write-Host ("== " + $t + " ==") -ForegroundColor Cyan }
function Write-Ok { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Green }
function Write-In { param([string]$t) Write-Host ("  " + $t) -ForegroundColor DarkGray }
function Write-WarnP { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Yellow }

# ---- 工具注册表：配方里的 tool 名 → 实际脚本 ----
$tools = @{
    'img-t2i'        = @{ path = Join-Path $root '画图.ps1' }
    'img-zimage'     = @{ path = Join-Path $root 'Z画图.ps1' }
    'img-moss'       = @{ path = Join-Path $root 'MOSS画图.ps1' }
    'img-pixeldit'   = @{ path = Join-Path $root 'PixelDiT画图.ps1' }
    'img-ops'        = @{ path = Join-Path $root '修图.ps1' }
    'img-inpaint'    = @{ path = Join-Path $root '局部重绘.ps1' }
    'img-upscale'    = @{ path = Join-Path $root '图片超分.ps1' }
    'img-pid'        = @{ path = Join-Path $root 'PiD超分.ps1' }
    'video-i2v'      = @{ path = Join-Path $root '图生视频.ps1' }
    'video-h3'       = @{ path = Join-Path $root '文本生视频H3快照.ps1' }
    'video-extend'   = @{ path = Join-Path $root '续接视频.ps1' }
    'video-join'     = @{ path = Join-Path $root '拼接视频.ps1' }
    'video-post'     = @{ path = Join-Path $root '后期处理.ps1' }
    'video-upscale'  = @{ path = Join-Path $root 'AI超分.ps1' }
    'video-flashvsr' = @{ path = Join-Path $root 'AI超分FlashVSR.ps1' }
    'audio-split'    = @{ path = 'D:\audio-tools\分离音频.ps1' }
    'audio-clone'    = @{ path = 'D:\audio-tools\声音克隆.ps1' }
    'audio-denoise'  = @{ path = 'D:\audio-tools\降噪增强.ps1' }
    'audio-sr'       = @{ path = 'D:\audio-tools\音频超分.ps1' }
    'audio-diarize'  = @{ path = 'D:\audio-tools\说话人分离.ps1' }
    'audio-midi'     = @{ path = 'D:\audio-tools\音频转MIDI.ps1' }
    'audio-subtitle' = @{ path = 'D:\audio-tools\录音转字幕.ps1' }
  'video-dub'      = @{ path = 'D:\audio-tools\视频配音提示词.ps1' }
  'video-dublipsync' = @{ path = 'D:\audio-tools\口型同步.ps1' }
  'image-dub'     = @{ path = 'D:\audio-tools\图像配音.ps1' }
  'audio-mod'     = @{ path = 'D:\audio-tools\音频模块.ps1' }
}

# ---- 加载配方 ----
$recipePath = $Recipe
if (-not (Test-Path $recipePath)) {
    $recipePath = Join-Path $recipeDir ($Recipe + '.json')
}
if (-not (Test-Path $recipePath)) {
    Write-Host ('  ✗ 找不到配方：' + $Recipe) -ForegroundColor Red
    Write-In ('可用配方：' + ((Get-ChildItem $recipeDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName }) -join ', '))
    if (-not $NoPause) { Start-Sleep -Seconds 6 }
    exit 1
}
$recipeObj = [System.IO.File]::ReadAllText($recipePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$recipeName = if ($recipeObj.name) { $recipeObj.name } else { [System.IO.Path]::GetFileNameWithoutExtension($recipePath) }

Write-H ('流水线：' + $recipeName)
if ($recipeObj.description) { Write-In $recipeObj.description }

# ---- 变量：配方默认值 + -Set 覆盖 ----
$vars = @{}
if ($recipeObj.vars) {
    foreach ($p in $recipeObj.vars.PSObject.Properties) { $vars[$p.Name] = $p.Value }
}
foreach ($kv in ($Set -split ';')) {
    $i = $kv.IndexOf('=')
    if ($i -gt 0) {
        $vars[$kv.Substring(0, $i).Trim()] = $kv.Substring($i + 1)
    }
}
Write-In ('变量：' + (($vars.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { $_.Key + '=' + $_.Value }) -join '  '))

function Expand-Tpl {
    param([string]$text)
    if (-not $text) { return $text }
    $out = $text
    foreach ($k in $vars.Keys) {
        $out = $out.Replace('{{' + $k + '}}', [string]$vars[$k])
    }
    # 上一步产物引用：{{step.<id>.out}}
    foreach ($k in $vars.Keys) {
        if ($k -like 'out.*') {
            $out = $out.Replace('{{' + $k + '}}', [string]$vars[$k])
        }
    }
    return $out
}

# ---- 任务目录 ----
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$taskName = if ($Out) { $Out } else { ($recipeName + '-' + $stamp) }
$taskDir = Join-Path $pipelineRoot $taskName
$manifestPath = Join-Path $taskDir 'manifest.json'
$manifest = $null
if ($Resume -and (Test-Path $manifestPath)) {
    $manifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Write-In ('续跑：' + $taskDir)
} else {
    New-Item -ItemType Directory -Force -Path $taskDir | Out-Null
    $manifest = [PSCustomObject]@{ recipe = $recipeName; created = (Get-Date).ToString('s'); vars = $vars; steps = @() }
    Write-In ('任务目录：' + $taskDir)
}

$stepIndex = 0
$failed = $false
$prevOut = ''

foreach ($step in $recipeObj.steps) {
    $stepIndex++
    $sid = $step.id
    if (-not $sid) { $sid = 'step' + $stepIndex }
    $onlyList = @($Only -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (@($onlyList).Count -gt 0 -and ($onlyList -notcontains $sid)) {
        Write-In ('跳过 ' + $sid + '（不在 -Only 里）')
        continue
    }

    # 已完成的跳过
    if ($Resume -and $manifest.steps) {
        $done = $manifest.steps | Where-Object { $_.id -eq $sid -and $_.status -eq 'done' } | Select-Object -First 1
        if ($done) {
            Write-In ('已完成，跳过 ' + $sid + ' → ' + $done.output)
            if ($done.output -and (Test-Path $done.output)) { $prevOut = $done.output; $vars['out.' + $sid] = $done.output; continue }
        }
    }

    $stepDir = Join-Path $taskDir (('{0:D2}-{1}' -f $stepIndex, $sid))
    $vars['taskDir'] = $taskDir
    $vars['stepDir'] = $stepDir
    New-Item -ItemType Directory -Force -Path $stepDir | Out-Null

    # 组装命令
    $argv = @()
    $label = ''
    if ($step.tool) {
        $t = $tools[$step.tool]
        if (-not $t) { Write-Host ('  ✗ 未知工具：' + $step.tool) -ForegroundColor Red; exit 1 }
        $label = $step.tool
        $argv += @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $t.path + '"'))
        if ($step.params) {
            foreach ($p in $step.params.PSObject.Properties) {
                $val = Expand-Tpl ([string]$p.Value)
                if ($val -eq '') { continue }
                if ($p.Value -is [bool] -or $val -eq 'true') { $argv += ('-' + $p.Name) }
                else { $argv += @(('-' + $p.Name), ('"' + $val + '"')) }
            }
        }
        # 参数去重：配方里已经写了 -NoPause 之类就不要再加（否则"参数被指定了多次"）
        if ($argv -notcontains '-NoPause') { $argv += @('-NoPause') }
        $seenArg = @{}
        $dedup = New-Object System.Collections.ArrayList
        foreach ($a in $argv) {
            if ($a -like '-*') {
                $k = $a.ToLower()
                if ($seenArg.ContainsKey($k)) { continue }
                $seenArg[$k] = $true
            }
            [void]$dedup.Add($a)
        }
        $argv = $dedup.ToArray()
    } elseif ($step.shell) {
        $label = 'shell'
        $cmd = Expand-Tpl $step.shell
        # 写成临时脚本再 -File 执行：-Command 处理嵌套引号会崩
        $shPath = Join-Path $stepDir 'run.ps1'
        [System.IO.File]::WriteAllText($shPath, ('$ErrorActionPreference = ''Continue''' + "`r`n" + $cmd), (New-Object System.Text.UTF8Encoding($true)))
        $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $shPath)
    } else {
        Write-Host ('  ✗ 步骤 ' + $sid + ' 既没有 tool 也没有 shell') -ForegroundColor Red
        exit 1
    }

    $cmdLine = ($argv -join ' ')
    Write-Host ''
    Write-Host ('── 步骤 {0}/{1}  {2}  [{3}]' -f $stepIndex, @($recipeObj.steps).Count, $sid, $label) -ForegroundColor Yellow
    Write-In $cmdLine

    if ($DryRun) { $vars['out.' + $sid] = ('<步骤' + $stepIndex + '产物>'); continue }

    $entry = [PSCustomObject]@{ id = $sid; tool = $label; cmd = $cmdLine; dir = $stepDir; started = (Get-Date).ToString('s'); status = 'running'; output = ''; seconds = 0 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' @argv 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    $sw.Stop()
    $outText = ($out | ForEach-Object { [string]$_ }) -join "`n"
    $outFile = Join-Path $stepDir 'log.txt'
    [System.IO.File]::WriteAllText($outFile, $outText, (New-Object System.Text.UTF8Encoding($false)))

    # 从输出里抓产物路径（各脚本统一打印「成品：路径」）
    $prod = ''
    # 产品标签：成品 / 视频完成 / 音频完成 / 输出文件 / 结果文件 / 输出（取最后一条）
    $rm = [regex]::Matches($outText, 'RESULT=([^\s"''<>]+\.(?:mp4|wav|srt|png|jpg|mov))')
    if ($rm.Count -gt 0) {
        $vals = @($rm | ForEach-Object { $_.Groups[1].Value.Trim() })
        $videoPick = @($vals | Where-Object { $_ -match '\.(mp4|mov)$' })
        $prod = if ($videoPick.Count -gt 0) { $videoPick[$videoPick.Count - 1] } else { $vals[$vals.Count - 1] }
    } else {
        $prodMatches = [regex]::Matches($outText, '(?:成品|视频完成|音频完成|输出文件|结果文件|输出)[：:]\s*([^\s]+\.(?:mp4|wav|srt|png|jpg|mov))')
        if ($prodMatches.Count -gt 0) { $prod = $prodMatches[$prodMatches.Count - 1].Groups[1].Value.Trim() }
    }
    if (-not $prod -and $step.output) {
        # shell 步骤：用配方声明的输出路径
        $cand = Expand-Tpl $step.output
        if (Test-Path $cand) { $prod = $cand }
    }

    $entry.seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $entry.output = $prod
    if ($step.expect -and $step.expect -eq 'none') { $code = 0 }
    if ($code -ne 0 -or ($step.expect -and $step.expect -ne 'none' -and -not $prod)) {
        $entry.status = 'failed'
        Write-Host ('  ✗ 失败（退出码 ' + $code + '），日志：' + $outFile) -ForegroundColor Red
        $tail = ($outText -split "`n" | Select-Object -Last 10) -join "`n"
        Write-Host $tail -ForegroundColor DarkGray
        $failed = $true
    } else {
        $entry.status = 'done'
        Write-Ok ('完成 {0:N1} 秒' -f $sw.Elapsed.TotalSeconds + $(if ($prod) { ' → ' + $prod } else { '' }))
        if ($prod) { $vars['out.' + $sid] = $prod; $prevOut = $prod }
    }

    $manifest.steps += $entry
    [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    if ($failed) { break }
}

if (-not $DryRun) {
    $summary = [PSCustomObject]@{
        recipe  = $recipeName
        taskDir = $taskDir
        steps   = @($manifest.steps | ForEach-Object { [PSCustomObject]@{ id = $_.id; status = $_.status; seconds = $_.seconds; output = $_.output } })
    }
    [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    Write-H '汇总'
    $summary.steps | ForEach-Object { '  {0,-14} {1,-7} {2,7:N1}s  {3}' -f $_.id, $_.status, $_.seconds, $_.output }
    Write-In ('manifest：' + $manifestPath)
}

if (-not $KeepIntermediate) {
    Write-In '（中间文件都保留在各步骤目录，方便复查；-KeepIntermediate 目前等价于保留）'
}
if (-not $NoPause) { Write-Host ''; Write-Host '窗口将在 10 秒后关闭…' -ForegroundColor DarkGray; Start-Sleep -Seconds 10 }
if ($failed) { exit 1 }
exit 0
