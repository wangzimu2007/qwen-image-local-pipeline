# 局部重绘 / 去物（Z-Image Turbo + latent mask，0 下载、纯本地）
#
# 用途：把图里某块区域重新生成（换物体、去杂物、补背景），其余部分保持不变。
# 显存：约 14 GB（Z-Image 全栈），出图前会快照卸载本地聊天模型。
#
# 用法：
#   # 矩形区域（x1,y1,x2,y2），提示词描述"重绘后想要什么"
#   .\局部重绘.ps1 -Image x.png -Rect "860,340,1180,620" -Prompt "empty stone wall, moss"
#   # 只想删掉：提示词写目标背景
#   .\局部重绘.ps1 -Image x.png -Rect "..." -Prompt "clean background, same lighting"
#   # 多个区域用分号
#   .\局部重绘.ps1 -Image x.png -Rect "100,100,300,300;500,500,700,700" -Prompt "..."
#   # 已有黑白 mask（白=重绘）也可
#   .\局部重绘.ps1 -Image x.png -Mask mask.png -Prompt "..."
param(
    [Parameter(Mandatory = $true)][string]$Image,
    [string]$Prompt = 'same style background, seamless, natural',
    [string]$Rect = '',
    [string]$Mask = '',
    [int]$Feather = 12,
    [double]$Denoise = 0.85,
    [int]$Steps = 8,
    [double]$Cfg = 1.0,
    [int]$Seed = 0,
    [string]$OutDir = '',
    [switch]$KeepServer,
    [switch]$KeepChatBackend,
    [switch]$NoOpen,
    [switch]$NoInfo,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_vram.ps1')
. (Join-Path $PSScriptRoot '_ui.ps1')
. (Join-Path $PSScriptRoot '_meta.ps1')

$inst     = 'D:\Comfy-Desktop\ComfyUI-Installs\ComfyUI (1)\ComfyUI'
$pyExe    = Join-Path $inst '.venv\Scripts\python.exe'
$workPy   = 'D:\deepseek harness\resources\runtime\primary-runtime\dependencies\python\python.exe'
$inDir    = Join-Path $inst 'input'
$outComfy = 'C:\Users\wangzimu\Desktop\ComfyUI 输出'
if (-not $OutDir) { $OutDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Qwen 图片' }
foreach ($d in @($OutDir, $outComfy, $inDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
if ($Seed -le 0) { $Seed = Get-Random -Minimum 1 -Maximum 2147483646 }

function Write-H { param([string]$t) Write-Host ''; Write-Host ("== " + $t + " ==") -ForegroundColor Cyan }
function Write-Ok { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Green }
function Write-In { param([string]$t) Write-Host ("  " + $t) -ForegroundColor DarkGray }
function Write-WarnP { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Yellow }
function Test-EngineHere { try { $null = Invoke-RestMethod 'http://127.0.0.1:8188/system_stats' -TimeoutSec 3; return $true } catch { return $false } }

Write-H '局部重绘（Z-Image Turbo + latent mask）'
if (-not (Test-Path $Image)) { Write-Host ('  ✗ 找不到图片：' + $Image) -ForegroundColor Red; exit 1 }
Write-In ('提示词：' + $Prompt)
Write-In ("{0} 步 / cfg {1} / denoise {2} / feather {3}" -f $Steps, $Cfg, $Denoise, $Feather)

# ---- 准备输入图与 mask ----
$stamp = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$safeImg  = Join-Path $inDir ('inp-img-' + $stamp + '.png')
$safeMask = Join-Path $inDir ('inp-mask-' + $stamp + '.png')

$maskScript = Join-Path ([System.IO.Path]::GetTempPath()) ('mkmask-' + $stamp + '.py')
$maskCode = @'
import sys, os
from PIL import Image, ImageDraw, ImageFilter
src, dst, rects, feather = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
im = Image.open(src).convert("RGB")
im.save(os.path.splitext(src)[0] + "_clean.png")  # 原样转 png
m = Image.new("L", im.size, 0)
d = ImageDraw.Draw(m)
n = 0
for part in rects.split(";"):
    part = part.strip()
    if not part:
        continue
    v = [int(float(x)) for x in part.split(",")]
    d.rectangle(v[:4], fill=255)
    n += 1
if feather > 0:
    m = m.filter(ImageFilter.GaussianBlur(feather))
m.save(dst)
print("%d regions, size %dx%d" % (n, im.width, im.height))
'@
[System.IO.File]::WriteAllText($maskScript, $maskCode, (New-Object System.Text.UTF8Encoding($false)))
$env:PYTHONIOENCODING = 'utf-8'

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$tmpPng = $safeImg
Copy-Item -LiteralPath $Image -Destination $tmpPng -Force
$maskOut = ''
if ($Mask -and (Test-Path $Mask)) {
    Copy-Item -LiteralPath $Mask -Destination $safeMask -Force
    Write-In ('使用提供的 mask：' + (Split-Path $Mask -Leaf))
} else {
    if (-not $Rect) { $ErrorActionPreference = $prevEap; Write-Host '  ✗ 需要 -Rect 或 -Mask' -ForegroundColor Red; exit 1 }
    $maskOut = & $workPy $maskScript $tmpPng $safeMask $Rect $Feather 2>&1
    Write-In ('mask：' + ($maskOut -join ' '))
}
$ErrorActionPreference = $prevEap
if (-not (Test-Path $safeMask)) { Write-Host '  ✗ mask 生成失败' -ForegroundColor Red; exit 1 }

# ---- 显存快照（Z-Image ~14 GB）----
$vramState = $null
trap {
    Write-Host ''
    Write-Host ('  X 出错: ' + $_.Exception.Message) -ForegroundColor Red
    try { Restore-VramPrep $vramState } catch { }
    exit 1
}
if (-not $KeepChatBackend) {
    $free = Get-FreeVramMiB
    if ($free -lt 14000) {
        Write-WarnP ("显存不足：{0} MB（需要约 14000 MB），自动快照并卸载本地模型…" -f $free)
        $vramState = Start-VramPrep -NeedMiB 14000 -TimeoutSeconds 150
    } else { Write-In ("显存充足（{0:N1} GB 可用）" -f ($free / 1024)) }
}

# ---- 引擎 ----
$startedHere = $false
if (-not (Test-EngineHere)) {
    Write-In '启动桌面版 ComfyUI…'
    Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
    $argList = @('main.py', '--port', '8188', '--listen', '127.0.0.1', ('--output-directory="' + $outComfy + '"'))
    Start-Process -FilePath $pyExe -ArgumentList $argList -WorkingDirectory $inst -WindowStyle Hidden
    $startedHere = $true
    $ok = $false
    for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Seconds 2; if (Test-EngineHere) { $ok = $true; break } }
    if (-not $ok) { throw 'ComfyUI 启动超时' }
}

$graph = @{
    '1'  = @{ class_type = 'LoadImage'; inputs = @{ image = (Split-Path $safeImg -Leaf) } }
    '2'  = @{ class_type = 'VAELoader'; inputs = @{ vae_name = 'ae.safetensors' } }
    '3'  = @{ class_type = 'VAEEncode'; inputs = @{ pixels = @('1', 0); vae = @('2', 0) } }
    '4'  = @{ class_type = 'LoadImage'; inputs = @{ image = (Split-Path $safeMask -Leaf) } }
    '5'  = @{ class_type = 'ImageToMask'; inputs = @{ image = @('4', 0); channel = 'red' } }
    '6'  = @{ class_type = 'SetLatentNoiseMask'; inputs = @{ samples = @('3', 0); mask = @('5', 0) } }
    '7'  = @{ class_type = 'UNETLoader'; inputs = @{ unet_name = 'z_image_turbo_nvfp4.safetensors'; weight_dtype = 'default' } }
    '8'  = @{ class_type = 'ModelSamplingAuraFlow'; inputs = @{ model = @('7', 0); shift = 3.0 } }
    '9'  = @{ class_type = 'CLIPLoader'; inputs = @{ clip_name = 'qwen_3_4b.safetensors'; type = 'lumina2'; device = 'default' } }
    '10' = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('9', 0); text = $Prompt } }
    '11' = @{ class_type = 'ConditioningZeroOut'; inputs = @{ conditioning = @('10', 0) } }
    '12' = @{ class_type = 'KSampler'; inputs = @{
            model = @('8', 0); seed = $Seed; steps = $Steps; cfg = $Cfg
            sampler_name = 'res_multistep'; scheduler = 'simple'
            positive = @('10', 0); negative = @('11', 0); latent_image = @('6', 0); denoise = $Denoise } }
    '13' = @{ class_type = 'VAEDecode'; inputs = @{ samples = @('12', 0); vae = @('2', 0) } }
    '14' = @{ class_type = 'SaveImage'; inputs = @{ images = @('13', 0); filename_prefix = 'zinpaint' } }
}

Write-In '提交重绘…'
$sw = [Diagnostics.Stopwatch]::StartNew()
$body = @{ prompt = $graph } | ConvertTo-Json -Depth 12 -Compress
try {
    $resp = Invoke-RestMethod 'http://127.0.0.1:8188/prompt' -Method POST -ContentType 'application/json' `
        -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60
} catch {
    $msg = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    throw ('提交失败：' + ($msg -split "`n")[0])
}
$id = $resp.prompt_id
$done = $false; $err = ''
while (-not $done) {
    Start-Sleep -Seconds 2
    try { $h = Invoke-RestMethod ('http://127.0.0.1:8188/history/' + $id) -TimeoutSec 10 } catch { continue }
    if (-not $h.$id) { continue }
    if ($h.$id.status.status_str -eq 'error') {
        $err = ($h.$id.status.messages | Where-Object { $_[0] -eq 'execution_error' } | ForEach-Object { $_[1].exception_message }) -join ' | '
        $done = $true
    } elseif ($h.$id.outputs) { $done = $true }
    if ($sw.Elapsed.TotalSeconds -gt 900) { $err = 'timeout'; $done = $true }
}
$sw.Stop()
if ($err) {
    Restore-VramPrep $vramState
    Write-Host ('  ✗ 重绘失败：' + ($err -split "`n")[0]) -ForegroundColor Red
    exit 1
}
Write-Ok ("完成，用时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds)

$produced = Get-ChildItem $outComfy -Filter 'zinpaint*.png' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $produced) { $produced = Get-ChildItem (Join-Path $inst 'output') -Filter 'zinpaint*.png' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
if (-not $produced) { Restore-VramPrep $vramState; Write-Host '  ✗ 没找到输出' -ForegroundColor Red; exit 1 }

$final = Get-NextImagePath -OutDir $OutDir -Kind 'inpaint'
Copy-Item $produced.FullName $final -Force
Write-MediaMeta -Path $final -Extra @{
    Model = 'Z-Image Turbo nvfp4 + latent mask (inpainting)'
    Prompt = $Prompt
    Rect = $(if ($Rect) { $Rect } else { 'mask file' })
    Feather = "$Feather"; Denoise = "$Denoise"; Steps = "$Steps"; Cfg = "$Cfg"; Seed = "$Seed"
    Source = $Image
}
Write-Ok ('成品：' + $final)

if (-not $NoOpen) { Start-Process $final }
if (-not $NoInfo) {
    $infScript = Join-Path $PSScriptRoot '_info.ps1'
    if (Test-Path $infScript) {
        . $infScript
        Show-MediaInfo -Path $final -Extra @{
            '模型' = 'Z-Image Turbo + latent mask（局部重绘）'
            '档位' = ("{0} 步 / cfg {1} / denoise {2}" -f $Steps, $Cfg, $Denoise)
            '区域' = $(if ($Rect) { $Rect } else { 'mask' })
        }
    }
}

Remove-Item $safeImg, $safeMask -Force -ErrorAction SilentlyContinue
if (-not $KeepServer -and $startedHere) {
    Get-Process python -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*Comfy-Desktop*' } |
        ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
}
Restore-VramPrep $vramState
if (-not $NoPause) { Write-Host ''; Write-Host '窗口将在 8 秒后自动关闭…' -ForegroundColor DarkGray; Start-Sleep -Seconds 8 }
exit 0
