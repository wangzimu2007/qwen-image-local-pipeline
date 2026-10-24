# 视频续接：取末帧 → 再生成一段 → 与原片拼接（显存不够时做长片就用这个）
# 用法：scripts\extend.ps1 -Video x.mp4 -Segments 2 -Prompt "镜头继续推进"
param(
    [Parameter(Mandatory = $true)][string]$Video,
    [string]$Prompt = '镜头继续推进，动作与画面自然延续',
    [int]$Segments = 1,
    [int]$Seconds = 5,
    [int]$Fps = 24,
    [int]$Steps = 20,
    [switch]$NoInfo
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\output.ps1"
. "$PSScriptRoot\lib\info.ps1"
$cfg = Get-PipelineConfig
$py  = Get-Python $cfg
$tools = Join-Path $PSScriptRoot 'lib\video_tools.py'

# 允许只写文件名（自动到输出目录找）
$videoPath = $Video
if (-not (Test-Path $videoPath)) {
    $cand = Join-Path $cfg.OutVideoDir $Video
    if (Test-Path $cand) { $videoPath = $cand } else { throw ("找不到视频：" + $Video) }
}
$videoPath = (Resolve-Path $videoPath).Path

Write-Head '视频续接'
$info = & $py $tools info $videoPath 2>&1
Write-Info $info
if ($info -match 'fps=([\d\.]+)') { $Fps = [int][math]::Round([double]$Matches[1]) }
Write-Info ("每段 {0} 秒，共 {1} 段" -f $Seconds, $Segments)

$tmp = Ensure-Dir (Join-Path $env:TEMP 'pipeline-extend')
$current = $videoPath
$parts = @($videoPath)
$swAll = [Diagnostics.Stopwatch]::StartNew()

for ($i = 1; $i -le $Segments; $i++) {
    Write-Head ("第 {0}/{1} 段" -f $i, $Segments)

    # 1) 取末帧
    $frame = Join-Path $tmp ("last-{0}.png" -f (Get-Date -Format 'HHmmss'))
    & $py $tools lastframe $current $frame 2>&1 | ForEach-Object { Write-Info $_ }
    if (-not (Test-Path $frame)) { Write-Warn2 '取末帧失败，终止'; break }

    # 2) 生成新段（复用 i2v.ps1）
    $before = @(Get-ChildItem $cfg.OutVideoDir -Filter '*.mp4' -ErrorAction SilentlyContinue).Count
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'i2v.ps1') `
        -Image $frame -Prompt $Prompt -Seconds $Seconds -Fps $Fps -Steps $Steps
    $after = @(Get-ChildItem $cfg.OutVideoDir -Filter '*.mp4' -ErrorAction SilentlyContinue).Count
    if ($after -le $before) { Write-Warn2 '本段生成失败，终止'; break }
    $newSeg = Get-ChildItem $cfg.OutVideoDir -Filter '*.mp4' | Sort-Object Name -Descending | Select-Object -First 1
    $parts += $newSeg.FullName

    # 3) 拼接
    $joined = Join-Path $tmp ("join-{0}.mp4" -f (Get-Date -Format 'HHmmss'))
    & $py $tools concatuniform $joined 'auto' @parts 2>&1 | ForEach-Object { Write-Info $_ }
    if (Test-Path $joined) { $current = $joined } else { Write-Warn2 '拼接失败，终止'; break }
}

$swAll.Stop()
if ($parts.Count -lt 2) { Write-Warn2 '没有生成任何新段'; exit 1 }

$final = Copy-VideoOutput -Config $cfg -SourceFile $current -Kind 'wan'
Write-Ok ("续接完成，总耗时 {0:N1} 分钟" -f $swAll.Elapsed.TotalMinutes)
Write-Ok ("成品：" + $final)
if (-not $NoInfo) { Show-MediaInfo -Path $final -Python $py -Extra @{ '流程' = ("续接 {0} 段" -f $Segments) } }
exit 0
