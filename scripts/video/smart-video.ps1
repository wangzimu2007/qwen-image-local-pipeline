# 智能出片：根据提示词自动规划并执行图生视频
# 模式：
#   single                 -> 图生视频单段
#   single_lowfps          -> 图生视频 12fps + 后期处理 FILM x2
#   segments_continuation  -> 图生视频第一段 + 续接视频
# >10 秒静止场景的“同首帧+交叉淡化”暂不自动执行（会提示命令）。
param(
    [Parameter(Mandatory = $true)][string]$Image,
    [Parameter(Mandatory = $true)][string]$Prompt,
    [double]$Seconds = 5,
    [int]$Fps = 24,
    [ValidateSet('draft', 'normal', 'high')][string]$Quality = 'normal',
    [switch]$WithAudio,
    [switch]$DryRun,
    [switch]$NoPause,
    [switch]$KeepServer,
    [switch]$KeepChatBackend
)

$ErrorActionPreference = 'Stop'
$root = 'D:\qwen-image-2.1'
$videoDir = Join-Path ([Environment]::GetFolderPath('Desktop')) '视频'
. (Join-Path $PSScriptRoot '_video_plan.ps1')

function Write-Plan {
    param($plan)
    Write-Host ''
    Write-Host '=== 智能出片规划 ===' -ForegroundColor Cyan
    Write-Host ('场景：{0} · 需求：{1}s/{2}fps · 模式：{3}' -f $plan.scene, $plan.seconds, $plan.fps, $plan.mode)
    Write-Host ('显存：可用 {0} MB / 预估 {1} MB（{2} 帧）{3}' -f $plan.vramFreeMB, $plan.vramEstimateMB, $plan.plannedFrames, $(if ($plan.vramRisk) { ' ⚠' } else { '' })) -ForegroundColor $(if ($plan.vramRisk) { 'Red' } else { 'DarkGray' })
    foreach ($n in $plan.notes) { Write-Host ('  · ' + $n) }
}

function Invoke-Step {
    param([string]$Script, [string[]]$StepArgs)
    $started = Get-Date
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Script @StepArgs 2>&1
    $code = $LASTEXITCODE
    $video = $null
    foreach ($line in $out) {
        $s = [string]$line
        Write-Host $s
        if ($s -match '(?:视频|成品)[：:]\s*(.+?\.mp4)') { $video = $Matches[1].Trim() }
    }
    if ($code -ne 0) {
        Write-Warning ('步骤失败（退出码 {0}）：{1}' -f $code, (Split-Path $Script -Leaf))
        return $null
    }
    if (-not $video -or -not (Test-Path $video)) {
        $fresh = Get-ChildItem $videoDir -Filter '*.mp4' -ErrorAction SilentlyContinue |
                 Where-Object { $_.LastWriteTime -gt $started.AddSeconds(-2) } |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($fresh) { $video = $fresh.FullName }
    }
    if (-not $video -or -not (Test-Path $video)) {
        Write-Warning ('步骤没有产出新视频：{0}' -f (Split-Path $Script -Leaf))
        return $null
    }
    return $video
}

if (-not (Test-Path $Image)) {
    Write-Warning "找不到图片：$Image"
    if (-not $NoPause) { Start-Sleep -Seconds 6 }
    exit 1
}
$Image = (Resolve-Path $Image).Path
$plan = Get-VideoPlan -Prompt $Prompt -Image $Image -Seconds $Seconds -Fps $Fps -Quality $Quality -WithAudio:$WithAudio
Write-Plan $plan

if ($DryRun) {
    Write-Host ''
    Write-Host 'DryRun：只规划，不生成。推荐命令：' -ForegroundColor Yellow
    if ($plan.mode -in @('single', 'single_lowfps')) {
        Write-Host ('  图生视频.ps1 -Image "{0}" -Prompt "{1}" -Seconds {2} -Fps {3} -Steps {4}' -f $Image, $Prompt, $plan.useSeconds, $plan.useFps, $plan.steps)
        if ($plan.post -eq 'interp2') { Write-Host '  后期处理.ps1 -Video <成品> -Interp 2' }
    } elseif ($plan.mode -eq 'segments_continuation') {
        Write-Host ('  图生视频.ps1 -Image "{0}" -Prompt "{1}" -Seconds 5 -Fps 24' -f $Image, $Prompt)
        Write-Host ('  续接视频.ps1 -Video <第一段> -Segments {0} -Seconds 5' -f ($plan.segments - 1))
    } else {
        Write-Host '  同首帧多段 + 交叉淡化（自动执行）'
    }
    exit 0
}

$baseArgs = @('-Image', $Image, '-Prompt', $Prompt)
if ($NoPause) { $baseArgs += '-NoPause' }
if ($KeepServer) { $baseArgs += '-KeepServer' }
if ($KeepChatBackend) { $baseArgs += '-KeepChatBackend' }

$finalVideo = $null
if ($plan.mode -in @('single', 'single_lowfps')) {
    $args1 = $baseArgs + @('-Seconds', "$($plan.useSeconds)", '-Fps', "$($plan.useFps)", '-Steps', "$($plan.steps)")
    $finalVideo = Invoke-Step (Join-Path $root '图生视频.ps1') $args1
    if (-not $finalVideo) { Write-Warning '图生视频失败，停止后续步骤。'; exit 1 }
    if ($plan.post -eq 'interp2') {
        Write-Host '生成完成，开始 FILM 插帧 ×2...' -ForegroundColor Yellow
        $args2 = @('-Video', $finalVideo, '-Interp', '2', '-NoPause')
        if ($KeepServer) { $args2 += '-KeepServer' }
        if ($KeepChatBackend) { $args2 += '-KeepChatBackend' }
        $interp = Invoke-Step (Join-Path $root '后期处理.ps1') $args2
        if (-not $interp) { Write-Warning '插帧失败。'; exit 1 }
        $finalVideo = $interp
    }
}
elseif ($plan.mode -eq 'segments_continuation') {
    $args1 = $baseArgs + @('-Seconds', '5', '-Fps', '24', '-Steps', "$($plan.steps)")
    $first = Invoke-Step (Join-Path $root '图生视频.ps1') $args1
    if (-not $first) { Write-Warning '第一段生成失败，停止续接。'; exit 1 }
    Write-Host '第一段完成，开始续接...' -ForegroundColor Yellow
    $args2 = @('-Video', $first, '-Segments', "$($plan.segments - 1)", '-Seconds', '5',
               '-Prompt', $Prompt, '-NoPause')
    if ($KeepServer) { $args2 += '-KeepServer' }
    if ($KeepChatBackend) { $args2 += '-KeepChatBackend' }
    $finalVideo = Invoke-Step (Join-Path $root '续接视频.ps1') $args2
    if (-not $finalVideo) { Write-Warning '续接失败。'; exit 1 }
}
else {
    Write-Host ('同首帧生成 {0} 段（每段 {1} 秒），最后交叉淡化...' -f $plan.segments, $plan.segmentSeconds) -ForegroundColor Yellow
    $segs = @()
    for ($i = 0; $i -lt $plan.segments; $i++) {
        $argsSeg = $baseArgs + @('-Seconds', "$($plan.segmentSeconds)", '-Fps', '24',
                                 '-Steps', "$($plan.steps)", '-Seed', "$(1000 + $i)")
        $segVideo = Invoke-Step (Join-Path $root '图生视频.ps1') $argsSeg
        if (-not $segVideo) { Write-Warning ('第 {0} 段失败，停止。' -f ($i + 1)); exit 1 }
        $segs += $segVideo
    }
    $argsJoin = @('-Videos', ($segs -join ','), '-Crossfade', '0.4', '-NoPause')
    $finalVideo = Invoke-Step (Join-Path $root '拼接视频.ps1') $argsJoin
    if (-not $finalVideo) { Write-Warning '交叉淡化拼接失败。'; exit 1 }
}

Write-Host ''
Write-Host ('视频完成：' + $finalVideo) -ForegroundColor Green
if (-not $NoPause) { Start-Sleep -Seconds 2 }
exit 0
