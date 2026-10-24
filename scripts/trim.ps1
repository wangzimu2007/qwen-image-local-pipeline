# 视频裁剪：按秒截取一段
# 用法：scripts\trim.ps1 -Video x.mp4 -Start 1 -Duration 3
param(
    [Parameter(Mandatory = $true)][string]$Video,
    [double]$Start = 0,
    [double]$Duration = 0,      # 0 = 到结尾
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

Write-Head '裁剪'
Write-Info ((Split-Path $videoPath -Leaf) + '  ' + (& $py $tools info $videoPath 2>&1))

$tmp = Ensure-Dir (Join-Path $env:TEMP 'pipeline-trim')
$out = Join-Path $tmp ("trim-{0}.mp4" -f (Get-Date -Format 'HHmmss'))
& $py $tools trim $videoPath $out $Start $Duration 2>&1 | ForEach-Object { Write-Info $_ }

if (-not (Test-Path $out)) { Write-Warn2 '裁剪失败'; exit 1 }
$final = Save-VideoOutput -Config $cfg -SourceFile $out -Kind 'trim'
Write-Ok ("成品：" + $final)
if (-not $NoInfo) { Show-MediaInfo -Path $final -Python $py -Extra @{ '流程' = ("裁剪 {0}s 起 {1}s" -f $Start, $Duration) } }
exit 0
