# PiD 4× 超分（NVIDIA PiD pixel-diffusion decoder，1024→4096，4 步）
#
# ⚠ 许可：NVIDIA NSCLv1 / nvidia-license，**仅限非商业**（研究/评估），输出同样受限。
# 实测：1024² → 4096² 约 37 秒，显存峰值 ~20 GB（RTX 5090 Laptop 24GB 刚好够）
# 对比：SeedVR2 到 4K 约 100 秒；FlashVSR+ 是视频路线
#
# 用法：
#   .\PiD超分.ps1 -Image x.png
#   .\PiD超分.ps1 -Image x.png -MaxInput 1024 -Seed 1234
param(
    [Parameter(Mandatory = $true)][string]$Image,
    [int]$MaxInput = 1024,      # 输入先缩到这个长边（PiD 训练于 1024→4096）
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

Write-H 'PiD 4× 超分（像素扩散解码器 / 非商业许可）'
Write-WarnP 'NSCLv1 许可：仅限非商业（研究/评估），输出同样受限'

if (-not (Test-Path $Image)) { Write-Host ('  ✗ 找不到图片：' + $Image) -ForegroundColor Red; exit 1 }

# 输入先缩到 MaxInput（避免超出 PiD 训练范围）
$srcStem = [System.IO.Path]::GetFileNameWithoutExtension($Image)
$safeIn  = Join-Path $inDir ('pid-in-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.png')
$tmpThumb = Join-Path ([System.IO.Path]::GetTempPath()) ('pid-src-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.png')
Copy-Item -LiteralPath $Image -Destination $tmpThumb -Force
. (Join-Path $PSScriptRoot '_ui.ps1')
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '修图.ps1') `
    -Image $tmpThumb -Ops ("thumb={0},{0}" -f $MaxInput) -Out $safeIn -NoOpen -NoInfo -NoMeta | Out-Null
if (-not (Test-Path $safeIn)) { Copy-Item $tmpThumb $safeIn -Force }
Remove-Item $tmpThumb -Force -ErrorAction SilentlyContinue

# ---- 显存快照（PiD 峰值 ~20 GB）----
$vramState = $null
trap {
    Write-Host ''
    Write-Host ('  X 出错: ' + $_.Exception.Message) -ForegroundColor Red
    try { Restore-VramPrep $vramState } catch { }
    exit 1
}
if (-not $KeepChatBackend) {
    $free = Get-FreeVramMiB
    if ($free -lt 21000) {
        Write-WarnP ("显存不足：{0} MB（PiD 需要约 21000 MB），自动快照并卸载本地模型…" -f $free)
        $vramState = Start-VramPrep -NeedMiB 21000 -TimeoutSec 180
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

# ---- 输出尺寸 = 输入 × 4 ----
$imgName = Split-Path $safeIn -Leaf
Add-Type -AssemblyName System.Drawing
$im0 = [System.Drawing.Image]::FromFile($safeIn)
$inW = $im0.Width; $inH = $im0.Height; $im0.Dispose()
$outW = [Math]::Min(4096, $inW * 4); $outH = [Math]::Min(4096, $inH * 4)
$outW = [int]([Math]::Floor($outW / 16) * 16); $outH = [int]([Math]::Floor($outH / 16) * 16)
Write-In ("输入 {0}×{1} → 输出 {2}×{3}" -f $inW, $inH, $outW, $outH)

$graph = @{
    '1'  = @{ class_type = 'LoadImage'; inputs = @{ image = $imgName } }
    '2'  = @{ class_type = 'VAELoader'; inputs = @{ vae_name = 'qwen_image_vae.safetensors' } }
    '3'  = @{ class_type = 'VAEEncode'; inputs = @{ pixels = @('1', 0); vae = @('2', 0) } }
    '4'  = @{ class_type = 'UNETLoader'; inputs = @{ unet_name = 'pid_qwenimage_1024_to_4096_4step_bf16.safetensors'; weight_dtype = 'default' } }
    '5'  = @{ class_type = 'CLIPLoader'; inputs = @{ clip_name = 'gemma_2_2b_it_elm_bf16.safetensors'; type = 'pixeldit'; device = 'default' } }
    '6'  = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('5', 0); text = '' } }
    '7'  = @{ class_type = 'ConditioningZeroOut'; inputs = @{ conditioning = @('6', 0) } }
    '8'  = @{ class_type = 'PiDConditioning'; inputs = @{ positive = @('6', 0); latent = @('3', 0); latent_format = 'qwenimage'; degrade_sigma = 0.0 } }
    '9'  = @{ class_type = 'BasicScheduler'; inputs = @{ model = @('4', 0); scheduler = 'simple'; steps = 4; denoise = 1.0 } }
    '10' = @{ class_type = 'KSamplerSelect'; inputs = @{ sampler_name = 'lcm' } }
    '11' = @{ class_type = 'EmptyChromaRadianceLatentImage'; inputs = @{ width = $outW; height = $outH; batch_size = 1 } }
    '12' = @{ class_type = 'SamplerCustom'; inputs = @{
            model = @('4', 0); add_noise = $true; noise_seed = $Seed; cfg = 1.0
            positive = @('8', 0); negative = @('7', 0); sampler = @('10', 0); sigmas = @('9', 0); latent_image = @('11', 0) } }
    '13' = @{ class_type = 'VAELoader'; inputs = @{ vae_name = 'pixel_space' } }
    '14' = @{ class_type = 'VAEDecode'; inputs = @{ samples = @('12', 0); vae = @('13', 0) } }
    '15' = @{ class_type = 'SaveImage'; inputs = @{ images = @('14', 0); filename_prefix = 'pid4x' } }
}

Write-In '提交超分…'
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
    if ($sw.Elapsed.TotalSeconds -gt 1800) { $err = 'timeout'; $done = $true }
}
$sw.Stop()
if ($err) {
    Restore-VramPrep $vramState
    Write-Host ('  ✗ 超分失败：' + ($err -split "`n")[0]) -ForegroundColor Red
    exit 1
}
Write-Ok ("完成，用时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds)

$produced = Get-ChildItem $outComfy -Filter 'pid4x*.png' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $produced) { $produced = Get-ChildItem (Join-Path $inst 'output') -Filter 'pid4x*.png' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
if (-not $produced) { Restore-VramPrep $vramState; Write-Host '  ✗ 没找到输出' -ForegroundColor Red; exit 1 }

$final = Get-NextImagePath -OutDir $OutDir -Kind 'pidup'
Copy-Item $produced.FullName $final -Force
Write-MediaMeta -Path $final -Extra @{
    Model = 'PiD 1.5 qwenimage 4-step (pixel-diffusion decoder)'
    License = 'NVIDIA NSCLv1 / nvidia-license - NON-COMMERCIAL only'
    License_ZH = '非商业（研究/评估）；输出同样受限'
    Source = $Image
    InSize = ("{0}x{1}" -f $inW, $inH)
    OutSize = ("{0}x{1}" -f $outW, $outH)
    Steps = '4'
    Sampler = 'lcm/simple'
    Seed = "$Seed"
}
Write-Ok ('成品：' + $final)

if (-not $NoOpen) { Start-Process $final }
if (-not $NoInfo) {
    $infScript = Join-Path $PSScriptRoot '_info.ps1'
    if (Test-Path $infScript) {
        . $infScript
        Show-MediaInfo -Path $final -Extra @{
            '模型' = 'PiD 4×（Qwen-Image latent → 4096，4 步 lcm）'
            '档位' = ("{0}×{1} → {2}×{3} / 4 步" -f $inW, $inH, $outW, $outH)
            '许可' = 'NSCLv1 仅限非商业'
        }
    }
}

if (-not $KeepServer -and $startedHere) {
    Get-Process python -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*Comfy-Desktop*' } |
        ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
}
Restore-VramPrep $vramState
if (-not $NoPause) { Write-Host ''; Write-Host '窗口将在 8 秒后自动关闭…' -ForegroundColor DarkGray; Start-Sleep -Seconds 8 }
exit 0
