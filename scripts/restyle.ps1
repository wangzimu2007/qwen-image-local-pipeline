# 视频改风格：抽关键帧 → 逐帧图生图 → 合成低帧率视频 → 插帧补回帧率
# 用法：scripts\restyle.ps1 -Video x.mp4 -Prompt "水彩画风格" -Every 8 -Strength 0.55
# 代价：每张关键帧约 15~25 秒。5 秒视频 Every=8 → 16 帧 ≈ 4~7 分钟
param(
    [Parameter(Mandatory = $true)][string]$Video,
    [Parameter(Mandatory = $true)][string]$Prompt,
    [int]$Every = 8,
    [double]$Strength = 0.55,
    [int]$Width = 0,
    [int]$Height = 0,
    [switch]$KeepFrames,
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
if ($Every -lt 1) { $Every = 1 }

$work = Ensure-Dir (Join-Path $env:TEMP 'pipeline-restyle')
$rawDir = Ensure-Dir (Join-Path $work 'frames')
$styledDir = Ensure-Dir (Join-Path $work 'styled')
Get-ChildItem $rawDir -Filter '*.png' -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem $styledDir -Filter '*.png' -ErrorAction SilentlyContinue | Remove-Item -Force

$info = & $py $tools info $videoPath 2>&1
$srcFps = 24.0
if ($info -match 'fps=([\d\.]+)') { $srcFps = [double]$Matches[1] }
if ($Width -le 0 -or $Height -le 0) {
    if ($info -match 'size=(\d+)x(\d+)') { $Width = [int]$Matches[1]; $Height = [int]$Matches[2] }
    else { $Width = $cfg.DefaultWidth; $Height = $cfg.DefaultHeight }
}
$targetFps = [math]::Max(2, [int][math]::Round($srcFps / $Every))

Write-Head '视频改风格'
Write-Info ($info)
Write-Info ("每 {0} 帧抽 1 张 → 重绘 → {1} fps 合成 → 插帧 ×{0} 补回 {2} fps" -f $Every, $targetFps, [int]$srcFps)

# 1) 抽关键帧
& $py $tools frames $videoPath $rawDir $Every 2>&1 | ForEach-Object { Write-Info $_ }
$rawFrames = Get-ChildItem $rawDir -Filter 'f*.png' | Sort-Object Name
if (-not $rawFrames) { Write-Warn2 '抽帧失败'; exit 1 }
Write-Info ("共 {0} 张关键帧" -f @($rawFrames).Count)

# 2) 逐张重绘
$swAll = [Diagnostics.Stopwatch]::StartNew()
$i = 0
foreach ($f in $rawFrames) {
    $i++
    $idx = [int]($f.BaseName -replace 'f', '')
    $perDir = Ensure-Dir (Join-Path $work "one-$idx")
    Get-ChildItem $perDir -Filter '*.png' -ErrorAction SilentlyContinue | Remove-Item -Force
    Write-Info ("[{0}/{1}] {2}" -f $i, @($rawFrames).Count, $f.Name)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'img2img.ps1') `
        -Image $f.FullName -Prompt $Prompt -Strength $Strength -Width $Width -Height $Height `
        -OutDir $perDir -NoOpen | Out-Null
    $out = Get-ChildItem $perDir -Filter '*.png' | Select-Object -First 1
    $ordered = Join-Path $styledDir ("s{0:D4}.png" -f $idx)
    if ($out) { Copy-Item $out.FullName $ordered -Force }
    else { Copy-Item $f.FullName $ordered -Force; Write-Warn2 '  本帧失败，用原图代替' }
}
$swAll.Stop()
Write-Ok ("重绘完成，{0:N1} 分钟" -f $swAll.Elapsed.TotalMinutes)

# 3) 合成低帧率视频
$styled = Get-ChildItem $styledDir -Filter 's*.png' | Sort-Object Name | ForEach-Object { $_.FullName }
if (-not $styled) { Write-Warn2 '没有重绘结果'; exit 1 }
$low = Join-Path $work ("low-{0}.mp4" -f (Get-Date -Format 'HHmmss'))
& $py $tools fromframes $low $targetFps @styled 2>&1 | ForEach-Object { Write-Info $_ }
if (-not (Test-Path $low)) { Write-Warn2 '合成失败'; exit 1 }

# 4) 插帧补回原帧率
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'post.ps1') `
    -Video $low -Scale 1 -Interp $Every -NoInfo | Out-Null
$final = Get-ChildItem $cfg.OutVideoDir -Filter '*.mp4' | Sort-Object Name -Descending | Select-Object -First 1
if (-not $final) { Write-Warn2 '找不到成品'; exit 1 }

Write-Ok ("成品：" + $final.FullName)
if (-not $NoInfo) {
    Show-MediaInfo -Path $final.FullName -Python $py -Extra @{ '流程' = ("关键帧重绘（每 {0} 帧）" -f $Every) }
}
if (-not $KeepFrames) { Remove-Item $rawDir, $styledDir -Recurse -Force -ErrorAction SilentlyContinue }
exit 0
