# 视频接视频：多段按顺序拼成一条（自动统一分辨率与帧率）
# 用法：scripts\concat.ps1 -Videos "a.mp4,b.mp4" [-Fps auto|24]
param(
    [Parameter(Mandatory = $true)][string]$Videos,
    [string]$Fps = 'auto',
    [switch]$NoInfo
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\output.ps1"
. "$PSScriptRoot\lib\info.ps1"
$cfg = Get-PipelineConfig
$py  = Get-Python $cfg
$tools = Join-Path $PSScriptRoot 'lib\video_tools.py'

# -File 调用时数组会被拍平成一个字符串，这里统一按逗号拆
$list = $Videos -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if (@($list).Count -lt 2) { Write-Warn2 '至少需要两段视频'; exit 1 }

$resolved = @()
foreach ($v in $list) {
    if (Test-Path $v) { $resolved += (Resolve-Path $v).Path; continue }
    $cand = Join-Path $cfg.OutVideoDir $v
    if (Test-Path $cand) { $resolved += (Resolve-Path $cand).Path; continue }
    Write-Warn2 ("找不到视频：" + $v); exit 1
}

Write-Head '视频拼接'
foreach ($r0 in $resolved) { Write-Info ((Split-Path $r0 -Leaf) + '  ' + (& $py $tools info $r0 2>&1)) }

$tmp = Ensure-Dir (Join-Path $env:TEMP 'pipeline-concat')
$out = Join-Path $tmp ("join-{0}.mp4" -f (Get-Date -Format 'HHmmss'))
$sw = [Diagnostics.Stopwatch]::StartNew()
& $py $tools concatuniform $out $Fps @resolved 2>&1 | ForEach-Object { Write-Info $_ }
$sw.Stop()

if (-not (Test-Path $out)) { Write-Warn2 '拼接失败'; exit 1 }
$final = Save-VideoOutput -Config $cfg -SourceFile $out -Kind 'join'
Write-Ok ("拼接完成，用时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds)
Write-Ok ("成品：" + $final)
if (-not $NoInfo) { Show-MediaInfo -Path $final -Python $py -Extra @{ '流程' = ("拼接 {0} 段" -f $resolved.Count) } }
exit 0
