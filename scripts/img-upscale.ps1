# 图片 AI 超分（SeedVR2 单图模式）：2K / 4K
# 用法：
#   scripts\img-upscale.ps1 -Image x.png -Resolution 1440     # 2K
#   scripts\img-upscale.ps1 -Image x.png -Resolution 2160     # 4K
param(
    [Parameter(Mandatory = $true)][string]$Image,
    [int]$Resolution = 2160,     # 短边像素：1080 / 1440(2K) / 2160(4K)
    [string]$Color = 'lab',
    [switch]$NoInfo,
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\output.ps1"
. "$PSScriptRoot\lib\info.ps1"
$cfg = Get-PipelineConfig
$py  = Get-Python $cfg

$cli = Assert-FilePath (Join-Path $cfg.SeedVR2Root 'inference_cli.py') 'SeedVR2 CLI'
Assert-FilePath (Join-Path $cfg.SeedVR2Models $cfg.SeedVR2Dit) 'SeedVR2 3B 模型' '见 NOTICE.md 模型清单' | Out-Null
$svPy = if ($cfg.SeedVR2Python -and (Test-Path $cfg.SeedVR2Python)) { $cfg.SeedVR2Python } else { $py }

$imgPath = $Image
if (-not (Test-Path $imgPath)) {
    $cand = Join-Path $cfg.OutImageDir $Image
    if (Test-Path $cand) { $imgPath = $cand } else { throw ("找不到图片：" + $Image) }
}
$imgPath = (Resolve-Path $imgPath).Path

Add-Type -AssemblyName System.Drawing
$im = [System.Drawing.Image]::FromFile($imgPath)
$sw0 = $im.Width; $sh0 = $im.Height
$im.Dispose()

# CLI 用 OpenCV 读图：中文路径会报 Cannot open image file → 复制到英文临时目录
$tmp = Ensure-Dir (Join-Path $env:TEMP 'pipeline-imgup')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$srcAscii = Join-Path $tmp ("src-$stamp" + [System.IO.Path]::GetExtension($imgPath))
Copy-Item -LiteralPath $imgPath -Destination $srcAscii -Force
$outTmp = Join-Path $tmp ("out-$stamp.png")

Write-Head '图片超分（SeedVR2）'
Write-Info ("输入 {0} × {1} → 目标短边 {2}p" -f $sw0, $sh0, $Resolution)

$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'

$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Exe -Exe $svPy -Arguments @($cli, $srcAscii,
        '--output', $outTmp,
        '--model_dir', $cfg.SeedVR2Models,
        '--resolution', "$Resolution",
        '--color_correction', $Color,
        '--output_format', 'png')
$sw.Stop()

if (-not (Test-Path $outTmp)) {
    Write-Warn2 '超分失败'
    ($r.Output | Where-Object { $_ -match 'ERROR|Error|Traceback|❌' } | Select-Object -Last 8) | ForEach-Object { Write-Info $_ }
    exit 1
}

$final = Save-ImageOutput -Config $cfg -SourceFile $outTmp -Kind 'up'
Write-Ok ("超分完成，用时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds)
Write-Ok ("成品：" + $final)
if (-not $NoInfo) {
    Show-MediaInfo -Path $final -Python $py -Extra @{ '模型' = 'SeedVR2 3B fp8（单图）'; '原尺寸' = ("{0}×{1}" -f $sw0, $sh0) }
}
if (-not $NoOpen) { try { Start-Process $final } catch {} }
exit 0
