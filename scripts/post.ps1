# 视频后期：Lanczos 放大 + FILM 插帧（不需要 AI 超分模型，秒级）
# 用法：scripts\post.ps1 -Video x.mp4 -Scale 1.5 -Interp 2
param(
    [Parameter(Mandatory = $true)][string]$Video,
    [double]$Scale = 1.0,
    [int]$Interp = 1,
    [switch]$KeepServer,
    [switch]$NoInfo
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\output.ps1"
. "$PSScriptRoot\lib\info.ps1"
$cfg = Get-PipelineConfig
$py  = Get-Python $cfg
$tools = Join-Path $PSScriptRoot 'lib\video_tools.py'

$videoPath = $Video
if (-not (Test-Path $videoPath)) {
    $cand = Join-Path $cfg.OutVideoDir $Video
    if (Test-Path $cand) { $videoPath = $cand } else { throw ("找不到视频：" + $Video) }
}
$videoPath = (Resolve-Path $videoPath).Path
$tmp = Ensure-Dir (Join-Path $env:TEMP 'pipeline-post')
$current = $videoPath

Write-Head '视频后期'
Write-Info ((Split-Path $videoPath -Leaf) + '  ' + (& $py $tools info $videoPath 2>&1))

# ---- 1. Lanczos 放大 ----
if ($Scale -gt 1.001 -or $Scale -lt 0.999) {
    Write-Info ("放大 ×{0}（Lanczos）" -f $Scale)
    $scaled = Join-Path $tmp ("scaled-{0}.mp4" -f (Get-Date -Format 'HHmmss'))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $py $tools scale $current $scaled $Scale 2>&1 | ForEach-Object { Write-Info $_ }
    $sw.Stop()
    if (Test-Path $scaled) { $current = $scaled; Write-Ok ("放大完成，{0:N1} 秒" -f $sw.Elapsed.TotalSeconds) }
    else { Write-Warn2 '放大失败，跳过' }
}

# ---- 2. FILM 插帧（ComfyUI） ----
$startedHere = $false
if ($Interp -ge 2) {
    $startedHere = Start-ComfyIfNeeded -Config $cfg
    $inName = Copy-ToComfyInput -Config $cfg -FilePath $current
    $info = & $py $tools info $current 2>&1
    $srcFps = 24.0
    if ($info -match 'fps=([\d\.]+)') { $srcFps = [double]$Matches[1] }
    $dstFps = [math]::Round($srcFps * $Interp, 1)

    $graph = @{
        '1' = @{ class_type = 'LoadVideo'; inputs = @{ file = $inName } }
        '2' = @{ class_type = 'GetVideoComponents'; inputs = @{ video = @('1', 0) } }
        '3' = @{ class_type = 'FrameInterpolationModelLoader'; inputs = @{ model_name = $cfg.FilmModel } }
        '4' = @{ class_type = 'FrameInterpolate'; inputs = @{ interp_model = @('3', 0); images = @('2', 0); multiplier = $Interp } }
        '5' = @{ class_type = 'CreateVideo'; inputs = @{ images = @('4', 0); fps = [double]$dstFps } }
        '6' = @{ class_type = 'SaveVideo'; inputs = @{ video = @('5', 0); filename_prefix = 'pipe-post'; format = 'mp4'; codec = 'h264' } }
    }
    Write-Info ("插帧 ×{0}（{1} → {2} fps）" -f $Interp, [int]$srcFps, $dstFps)
    $r = Invoke-ComfyPrompt -Config $cfg -Graph $graph -DoneNode '6'
    if ($r.Ok) {
        $produced = Get-NewestFile -Dir (Get-ComfyOutputDir -Config $cfg) -Filter 'pipe-post*.mp4'
        if ($produced) { $current = $produced.FullName; Write-Ok ("插帧完成，{0:N1} 秒" -f $r.Seconds) }
    } else { Write-Warn2 ('插帧失败：' + $r.Error) }
    Stop-ComfyIfOwned -Config $cfg -StartedHere ($startedHere -and -not $KeepServer)
}

$final = Copy-VideoOutput -Config $cfg -SourceFile $current -Kind 'post'
Write-Ok ("成品：" + $final)
if (-not $NoInfo) {
    Show-MediaInfo -Path $final -Python $py -Extra @{ '流程' = ("Lanczos ×{0} + 插帧 ×{1}" -f $Scale, $Interp) }
}
exit 0
