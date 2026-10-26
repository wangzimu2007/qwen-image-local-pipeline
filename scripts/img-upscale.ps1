# 图片超分（SeedVR2 官方 CLI 的单图模式）：放大到 2K / 4K，AI 重建细节
#
# 用法：
#   powershell -File D:\qwen-image-2.1\图片超分.ps1 -Image "某图.png" -NoPause          # 默认 2160（4K 短边）
#   ... -Resolution 1440      # 2K 短边
#   ... -Resolution 1080      # 1080p
#
# 输出：桌面「Qwen 图片」里，命名 qwen-<NNNN>-up-<时间戳>.png（与其它成图同一套编号规则）
param(
    [Parameter(Mandatory = $true)]
    [string]$Image,
    [int]$Resolution = 2160,
    [string]$Color = 'lab',
    [double]$MaxScale = 2.0,
    [switch]$NoTwoStep,
    [switch]$NoOpen,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$repo     = 'D:\seedvr2-cli\ComfyUI-SeedVR2_VideoUpscaler-main'
$py       = 'D:\Comfy-Desktop\ComfyUI-Installs\ComfyUI (1)\ComfyUI\.venv\Scripts\python.exe'
$models   = Join-Path $repo 'models\SEEDVR2'
$cli      = Join-Path $repo 'inference_cli.py'
$root     = 'D:\qwen-image-2.1'
$desk     = [Environment]::GetFolderPath('Desktop')
$imgDir   = Join-Path $desk 'Qwen 图片'
$tmp      = Join-Path $env:TEMP 'dsh-imgup'

function Pause-Brief { param([int]$S = 8) if ($NoPause) { return }; Write-Host ''; Write-Host "窗口将在 $S 秒后自动关闭..." -ForegroundColor DarkGray; Start-Sleep -Seconds $S }

if (-not (Test-Path $Image)) { Write-Warning "找不到图片：$Image"; Pause-Brief; exit 1 }
if (-not (Test-Path $tmp)) { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }
$Image = (Resolve-Path $Image).Path

# 取原图尺寸
Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Image]::FromFile($Image)
$sw0 = $img.Width; $sh0 = $img.Height
$img.Dispose()
Write-Host ("输入：{0}（{1}×{2}）" -f (Split-Path $Image -Leaf), $sw0, $sh0) -ForegroundColor Cyan
Write-Host ("目标：短边 {0}p" -f $Resolution) -ForegroundColor Cyan

$OutputTarget = $Resolution
$short0 = [Math]::Min($sw0, $sh0)
$scaleAll = $OutputTarget / [double]$short0
$twoStep = (-not $NoTwoStep) -and ($scaleAll -gt $MaxScale)
if ($twoStep) {
    $Resolution = [int][Math]::Round($short0 * 1.5)
    Write-Host ("放大 {0:N2}× 超过上限 {1}× → 两步走：AI 到短边 {2}，再 Lanczos 到 {3}" -f $scaleAll, $MaxScale, $Resolution, $OutputTarget) -ForegroundColor Yellow
} else {
    Write-Host ("放大 {0:N2}×，单步完成" -f $scaleAll) -ForegroundColor DarkGray
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outTmp = Join-Path $tmp ("imgup-$stamp.png")
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'

# CLI 内部用 OpenCV 读图，中文路径（如「Qwen 图片」）会报 Cannot open image file
# → 先把输入复制到纯英文临时路径
$srcAscii = Join-Path $tmp ("src-$stamp" + [System.IO.Path]::GetExtension($Image))
Copy-Item -LiteralPath $Image -Destination $srcAscii -Force
Write-Host ("  （已复制到英文临时路径：{0}）" -f (Split-Path $srcAscii -Leaf)) -ForegroundColor DarkGray

Write-Host '=== 开始超分 ===' -ForegroundColor Yellow
$sw = [Diagnostics.Stopwatch]::StartNew()
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$log = & $py $cli $srcAscii --output $outTmp --model_dir $models --resolution $Resolution --color_correction $Color --output_format png 2>&1
$ErrorActionPreference = $prevEap
$sw.Stop()
$log | Where-Object { $_ -match 'Resolution|Output|completed|ERROR|❌|Peak|FPS' } | Select-Object -Last 10 | ForEach-Object { '  ' + $_ }

if (-not (Test-Path $outTmp)) { Write-Warning '超分失败，没有输出文件。'; Pause-Brief; exit 1 }
Write-Host ("超分完成，用时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green

if ($twoStep) {
    $tw = [int]([Math]::Round($sw0 * ($OutputTarget / [double]$short0)))
    $th = [int]([Math]::Round($sh0 * ($OutputTarget / [double]$short0)))
    if ($tw % 2 -ne 0) { $tw += 1 }
    if ($th % 2 -ne 0) { $th += 1 }
    Write-Host ("  第二步 Lanczos 补齐到 {0}×{1}" -f $tw, $th) -ForegroundColor DarkGray
    $step2 = Join-Path $tmp ("step2-$stamp.png")
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '修图.ps1') -Image $outTmp -Ops ("resize={0}x{1}" -f $tw, $th) -Out $step2 -NoOpen -NoInfo | Out-Null
    if (Test-Path $step2) { $outTmp = $step2 } else { Write-Warning '  第二步失败，保留第一步结果' }
}

# 用统一编号命名，放进「Qwen 图片」
. (Join-Path $root '_ui.ps1')
if (-not (Test-Path $imgDir)) { New-Item -ItemType Directory -Path $imgDir -Force | Out-Null }
$final = Get-NextImagePath -OutDir $imgDir -Kind 'up'
Copy-Item $outTmp $final -Force

$img2 = [System.Drawing.Image]::FromFile($final)
Write-Host ''
Write-Host ("成品：{0}" -f $final) -ForegroundColor Green
Write-Host ("尺寸：{0}×{1}" -f $img2.Width, $img2.Height) -ForegroundColor Green
$img2.Dispose()

# 参数摘要
. (Join-Path $PSScriptRoot '_info.ps1')
. (Join-Path $PSScriptRoot '_meta.ps1')
Write-MediaMeta -Path $final -Extra @{ Model = "SeedVR2 3B fp8"; Source = "$sw0×$sh0"; Target = "$Resolution"; Color = $Color }
Show-MediaInfo -Path $final -Extra @{ '模型' = 'SeedVR2 3B fp8（单图）'; '原尺寸' = "$sw0×$sh0" }

if (-not $NoOpen) { try { Start-Process $final } catch {} }
Pause-Brief
exit 0
