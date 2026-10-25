# Krea 2 Turbo 文生图（12B DiT，8 步，Qwen-Image VAE + Qwen3-VL 编码器）
#
# 许可：Krea 2 Community License（商用前务必看 https://huggingface.co/krea/Krea-2-Turbo 的 LICENSE）
# 实测（RTX 5090 Laptop 24GB）：1024² 8 步 —— 冷启动 33.6 秒 / 热启动 **3.1 秒** / 带 LoRA 首次 12.2 秒
# 显存：约 17~18 GB（nvfp4 权重 7.15 GB + qwen3vl_4b 编码器 4.88 GB）
#
# 用法：
#   .\Krea2画图.ps1 -Prompt "high fashion editorial portrait, woman, cinematic lighting"
#   .\Krea2画图.ps1 -Prompt "..." -Lora krea2_softwatercolor -Width 1024 -Height 1024
#   .\Krea2画图.ps1 -Prompt "..." -Lora krea2_retroanime -LoraStrength 1.0
#   .\Krea2画图.ps1 -List                                   # 看有哪些风格 LoRA
param(
    [Parameter(Mandatory = $false)][string]$Prompt = '',
    [string]$Negative = '',
    [int]$Width = 1024,
    [int]$Height = 1024,
    [int]$Steps = 8,
    [double]$Cfg = 1.0,
    [string]$Sampler = 'euler',
    [string]$Scheduler = 'simple',
    [string]$Lora = '',              # 风格 LoRA 名（不带目录，可省 .safetensors）
    [double]$LoraStrength = 0.8,
    [int]$Seed = 0,
    [string]$OutDir = '',
    [switch]$List,
    [switch]$KeepServer,
    [switch]$NoOpen,
    [switch]$NoInfo,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_ui.ps1')
. (Join-Path $PSScriptRoot '_meta.ps1')

$inst     = 'D:\Comfy-Desktop\ComfyUI-Installs\ComfyUI (1)\ComfyUI'
$pyExe    = Join-Path $inst '.venv\Scripts\python.exe'
$outComfy = 'C:\Users\wangzimu\Desktop\ComfyUI 输出'
$loraDir  = 'D:\krea2\models\loras'
if (-not $OutDir) { $OutDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Qwen 图片' }
foreach ($d in @($OutDir, $outComfy)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

function Write-H { param([string]$t) Write-Host ''; Write-Host ("== " + $t + " ==") -ForegroundColor Cyan }
function Write-Ok { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Green }
function Write-In { param([string]$t) Write-Host ("  " + $t) -ForegroundColor DarkGray }
function Write-WarnP { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Yellow }
function Test-EngineHere { try { $null = Invoke-RestMethod 'http://127.0.0.1:8188/system_stats' -TimeoutSec 3; return $true } catch { return $false } }

$styleLoras = @{}
if (Test-Path $loraDir) {
    Get-ChildItem $loraDir -File -Filter 'krea2_*.safetensors' | ForEach-Object {
        $styleLoras[$_.BaseName] = $_.Name
    }
}

if ($List) {
    Write-H '可用风格 LoRA'
    $styleLoras.Keys | Sort-Object | ForEach-Object { '  ' + $_ }
    Write-In '用法：-Lora krea2_softwatercolor（可省略 krea2_ / .safetensors）'
    exit 0
}

if (-not $Prompt) {
    Write-Host '  ✗ 需要 -Prompt（或用 -List 查看 LoRA）' -ForegroundColor Red
    if (-not $NoPause) { Start-Sleep -Seconds 6 }
    exit 1
}
if ($Seed -le 0) { $Seed = Get-Random -Minimum 1 -Maximum 2147483646 }

Write-H 'Krea 2 Turbo 文生图'
Write-WarnP 'Krea 2 Community License：商用前请确认条款'
Write-In ("{0}×{1} / {2} 步 / cfg {3} / {4}+{5} / seed {6}" -f $Width, $Height, $Steps, $Cfg, $Sampler, $Scheduler, $Seed)

# LoRA 名归一化
$loraFile = ''
if ($Lora) {
    $key = $Lora
    if (-not $key.StartsWith('krea2_')) { $key = 'krea2_' + $key }
    if (-not $key.EndsWith('.safetensors')) {
        if ($styleLoras.ContainsKey($key)) { $loraFile = $styleLoras[$key] }
        elseif ($styleLoras.ContainsKey($key + '_bf16')) { $loraFile = $styleLoras[$key + '_bf16'] }
    } else { $loraFile = $Lora }
    if (-not $loraFile) {
        Write-Host ('  ✗ 找不到 LoRA：' + $Lora) -ForegroundColor Red
        Write-In ('可用：' + (($styleLoras.Keys | Sort-Object) -join ', '))
        if (-not $NoPause) { Start-Sleep -Seconds 8 }
        exit 1
    }
    Write-In ('LoRA：' + $loraFile + ' @ ' + $LoraStrength)
}

# ---- 引擎 ----
$startedHere = $false
if (-not (Test-EngineHere)) {
    Write-In '启动桌面版 ComfyUI（8188）…'
    Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
    $argList = @('main.py', '--port', '8188', '--listen', '127.0.0.1', ('--output-directory="' + $outComfy + '"'))
    Start-Process -FilePath $pyExe -ArgumentList $argList -WorkingDirectory $inst -WindowStyle Hidden
    $startedHere = $true
    $ok = $false
    for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Seconds 2; if (Test-EngineHere) { $ok = $true; break } }
    if (-not $ok) { throw 'ComfyUI 启动超时' }
} else { Write-In '引擎已在运行' }

$graph = @{
    '1' = @{ class_type = 'UNETLoader'; inputs = @{ unet_name = 'krea2_turbo_nvfp4.safetensors'; weight_dtype = 'default' } }
    '2' = @{ class_type = 'CLIPLoader'; inputs = @{ clip_name = 'qwen3vl_4b_fp8_scaled.safetensors'; type = 'krea2'; device = 'default' } }
    '3' = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('2', 0); text = $Prompt } }
    '4' = @{ class_type = 'ConditioningZeroOut'; inputs = @{ conditioning = @('3', 0) } }
    '5' = @{ class_type = 'EmptySD3LatentImage'; inputs = @{ width = $Width; height = $Height; batch_size = 1 } }
    '7' = @{ class_type = 'VAELoader'; inputs = @{ vae_name = 'qwen_image_vae.safetensors' } }
    '8' = @{ class_type = 'VAEDecode'; inputs = @{ samples = @('6', 0); vae = @('7', 0) } }
    '9' = @{ class_type = 'SaveImage'; inputs = @{ images = @('8', 0); filename_prefix = 'krea2' } }
}
if ($Negative) {
    $graph['11'] = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('2', 0); text = $Negative } }
    $negRef = @('11', 0)
} else { $negRef = @('4', 0) }

$modelRef = @('1', 0)
if ($loraFile) {
    $graph['10'] = @{ class_type = 'LoraLoaderModelOnly'; inputs = @{ model = @('1', 0); lora_name = $loraFile; strength_model = $LoraStrength } }
    $modelRef = @('10', 0)
}
$graph['6'] = @{ class_type = 'KSampler'; inputs = @{
        model = $modelRef; seed = $Seed; steps = $Steps; cfg = $Cfg
        sampler_name = $Sampler; scheduler = $Scheduler
        positive = @('3', 0); negative = $negRef; latent_image = @('5', 0); denoise = 1.0 } }

Write-In '提交生成…'
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
    Write-Host ('  ✗ 生成失败：' + ($err -split "`n")[0]) -ForegroundColor Red
    exit 1
}
Write-Ok ("完成 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds)

$produced = Get-ChildItem $outComfy -Filter 'krea2*.png' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $produced) { $produced = Get-ChildItem (Join-Path $inst 'output') -Filter 'krea2*.png' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
if (-not $produced) { Write-Host '  ✗ 没找到输出' -ForegroundColor Red; exit 1 }

$final = Get-NextImagePath -OutDir $OutDir -Kind 'krea2'
Copy-Item $produced.FullName $final -Force
Write-MediaMeta -Path $final -Extra @{
    Model = 'Krea 2 Turbo (12B DiT, nvfp4)'
    Prompt = $Prompt
    Negative = $Negative
    Steps = "$Steps"; Cfg = "$Cfg"; Sampler = "$Sampler/$Scheduler"; Seed = "$Seed"
    Size = ("{0}x{1}" -f $Width, $Height)
    Lora = $loraFile; LoraStrength = "$LoraStrength"
    License = 'Krea 2 Community License - check terms before commercial use'
}
Write-Ok ('成品：' + $final)

if (-not $NoOpen) { Start-Process $final }
if (-not $NoInfo) {
    $infScript = Join-Path $PSScriptRoot '_info.ps1'
    if (Test-Path $infScript) {
        . $infScript
        Show-MediaInfo -Path $final -Extra @{
            '模型' = 'Krea 2 Turbo（12B / nvfp4 / Qwen3-VL 编码器）'
            '档位' = ("{0}×{1} / {2} 步 / cfg {3}" -f $Width, $Height, $Steps, $Cfg)
            'LoRA' = $(if ($loraFile) { $loraFile.Replace('krea2_', '').Replace('.safetensors', '') + " @ $LoraStrength" } else { '无' })
        }
    }
}
if (-not $KeepServer -and $startedHere) {
    Get-Process python -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*Comfy-Desktop*' } |
        ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
}
if (-not $NoPause) { Write-Host ''; Write-Host '窗口将在 8 秒后自动关闭…' -ForegroundColor DarkGray; Start-Sleep -Seconds 8 }
exit 0
