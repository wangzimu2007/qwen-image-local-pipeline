# 文生图：Z-Image Turbo（ComfyUI，支持风格 LoRA、图生图、失败自动降级、显存快照）
# 实测（RTX 5090 Laptop 24GB）：1024²/8 步约 4 秒；832×1216 + LoRA 约 5 秒
# 用法：
#   .\t2i-zimage.ps1 -Prompt "森林雾气中的白裙女孩" -Width 832 -Height 1216
#   .\t2i-zimage.ps1 -Prompt "..." -Lora Kook_Zimage_ruhmeng.safetensors -LoraStrength 0.8
#   .\t2i-zimage.ps1 -Prompt "..." -Image x.png -Denoise 0.5
param(
    [Parameter(Mandatory = $true)][string]$Prompt,
    [int]$Width = 1024,
    [int]$Height = 1024,
    [int]$Steps = 8,
    [double]$Cfg = 1.0,
    [string]$Sampler = 'res_multistep',
    [double]$Shift = 3.0,
    [int]$Seed = 0,
    [string]$Lora = '',
    [double]$LoraStrength = 0.8,
    [string]$Negative = '',
    [string]$Image = '',
    [double]$Denoise = 0.5,
    [string]$OutDir = '',
    [switch]$NoOpen,
    [switch]$NoFallback,
    [switch]$KeepChatBackend
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\vram.ps1"
. "$PSScriptRoot\lib\info.ps1"

$C = Get-PipelineConfig
$port = if ($C.ZImagePort) { $C.ZImagePort } else { 8188 }
$outDir = if ($OutDir) { $OutDir } elseif ($C.OutImageDir) { $C.OutImageDir } else { Ensure-Dir (Join-Path $script:RepoRoot 'output\images') }
Ensure-Dir $outDir | Out-Null
if ($Seed -le 0) { $Seed = Get-Random -Minimum 1 -Maximum 2147483646 }

Write-Head 'Z-Image Turbo 文生图'
Write-Info ("{0}×{1} / {2} 步{3} / seed {4}{5}" -f $Width, $Height, $Steps,
    $(if ($Lora) { " / LoRA $Lora @ $LoraStrength" } else { ' / 无 LoRA' }), $Seed,
    $(if ($Image) { " / 图生图 denoise $Denoise" } else { '' }))

# ---- 显存快照 ----
$vramState = $null
trap { try { Restore-VramPrep -Config $C -State $vramState } catch { }; exit 1 }
if (-not $KeepChatBackend) { $vramState = Start-VramPrep -Config $C -NeedMB 12000 -TimeoutSec 150 }

# ---- 启动 ComfyUI ----
$startedHere = Start-ComfyIfNeeded -Config $C
if ($startedHere) { Write-Ok 'ComfyUI 已就绪' }

# ---- 图生图输入 ----
$inputName = ''
if ($Image) {
    $inputName = Copy-ToComfyInput -Config $C -FilePath (Assert-FilePath -Path $Image -Label '输入图片')
    Write-Info ('图生图输入：' + $inputName)
}

function New-ZGraph {
    param([string]$UseLora, [int]$W, [int]$H)
    $g = @{
        '1'  = @{ class_type = 'UNETLoader'; inputs = @{ unet_name = $(if ($C.ZImageUnet) { $C.ZImageUnet } else { 'z_image_turbo_nvfp4.safetensors' }); weight_dtype = 'default' } }
        '3'  = @{ class_type = 'CLIPLoader'; inputs = @{ clip_name = $(if ($C.ZImageClip) { $C.ZImageClip } else { 'qwen_3_4b.safetensors' }); type = 'lumina2'; device = 'default' } }
        '4'  = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('3', 0); text = $Prompt } }
        '5'  = @{ class_type = 'ConditioningZeroOut'; inputs = @{ conditioning = @('4', 0) } }
        '6'  = @{ class_type = 'VAELoader'; inputs = @{ vae_name = $(if ($C.ZImageVae) { $C.ZImageVae } else { 'ae.safetensors' }) } }
        '10' = @{ class_type = 'VAEDecode'; inputs = @{ samples = @('9', 0); vae = @('6', 0) } }
        '11' = @{ class_type = 'SaveImage'; inputs = @{ images = @('10', 0); filename_prefix = 'pipe-zimage' } }
    }
    if ($UseLora) {
        $g['2'] = @{ class_type = 'LoraLoaderModelOnly'; inputs = @{ model = @('1', 0); lora_name = $UseLora; strength_model = $LoraStrength } }
        $g['8'] = @{ class_type = 'ModelSamplingAuraFlow'; inputs = @{ model = @('2', 0); shift = $Shift } }
    } else {
        $g['8'] = @{ class_type = 'ModelSamplingAuraFlow'; inputs = @{ model = @('1', 0); shift = $Shift } }
    }
    if ($Negative) {
        $g['12'] = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('3', 0); text = $Negative } }
        $negRef = @('12', 0)
    } else { $negRef = @('5', 0) }
    if ($inputName) {
        $g['20'] = @{ class_type = 'LoadImage'; inputs = @{ image = $inputName } }
        $g['21'] = @{ class_type = 'VAEEncode'; inputs = @{ pixels = @('20', 0); vae = @('6', 0) } }
        $latent = @('21', 0); $den = $Denoise
    } else {
        $g['7'] = @{ class_type = 'EmptySD3LatentImage'; inputs = @{ width = $W; height = $H; batch_size = 1 } }
        $latent = @('7', 0); $den = 1.0
    }
    $g['9'] = @{ class_type = 'KSampler'; inputs = @{
        model = @('8', 0); seed = $Seed; steps = $Steps; cfg = $Cfg
        sampler_name = $Sampler; scheduler = 'simple'
        positive = @('4', 0); negative = $negRef; latent_image = $latent; denoise = $den } }
    return $g
}

# ---- 降级计划 ----
$plan = @([pscustomobject]@{ Tag = '原配置'; Lora = $Lora; W = $Width; H = $Height })
if (-not $NoFallback) {
    if ($Lora) { $plan += [pscustomobject]@{ Tag = '关闭风格 LoRA'; Lora = ''; W = $Width; H = $Height } }
    $w2 = [int]([math]::Round($Width * 0.75 / 16) * 16); if ($w2 -lt 256) { $w2 = 256 }
    $h2 = [int]([math]::Round($Height * 0.75 / 16) * 16); if ($h2 -lt 256) { $h2 = 256 }
    $plan += [pscustomobject]@{ Tag = ("降分辨率 {0}×{1}" -f $w2, $h2); Lora = $Lora; W = $w2; H = $h2 }
    if ($Lora) { $plan += [pscustomobject]@{ Tag = '关 LoRA + 降分辨率'; Lora = ''; W = $w2; H = $h2 } }
}

$ok = $false; $usedTag = ''; $firstErr = ''; $seconds = 0
foreach ($a in $plan) {
    Write-Info ("尝试：" + $a.Tag + (" {0}×{1}" -f $a.W, $a.H))
    $r = Invoke-ComfyPrompt -Config $C -Graph (New-ZGraph -UseLora $a.Lora -W $a.W -H $a.H) -DoneNode '11'
    if ($r.Ok) { $ok = $true; $usedTag = $a.Tag; $Width = $a.W; $Height = $a.H; $Lora = $a.Lora; $seconds = $r.Seconds; break }
    if (-not $firstErr) { $firstErr = ($r.Error -split "`n")[0] }
    Write-Warn2 ('  失败：' + ($r.Error -split "`n")[0])
}

if (-not $ok) {
    Stop-ComfyIfOwned -Config $C -StartedHere $startedHere
    Restore-VramPrep -Config $C -State $vramState
    Fail ('全部尝试均失败：' + $firstErr)
}
Write-Ok ("生成完成，用时 {0:N1} 秒" -f $seconds)
if ($usedTag -ne '原配置') { Write-Warn2 ('已自动降级：' + $usedTag) }

# ---- 取图 ----
$produced = Get-NewestFile -Dir $C.ComfyOutputDir -Filter 'pipe-zimage*.png'
if (-not $produced) { $produced = Get-NewestFile -Dir (Join-Path $C.ComfyRoot 'output') -Filter 'pipe-zimage*.png' }
if (-not $produced) {
    Stop-ComfyIfOwned -Config $C -StartedHere $startedHere
    Restore-VramPrep -Config $C -State $vramState
    Fail '没找到输出图片（检查 ComfyOutputDir 配置）'
}
$final = Join-Path $outDir ('zimage-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.png')
Copy-Item $produced.FullName $final -Force
Write-Ok ('成品：' + $final)
if (-not $NoOpen) { Start-Process $final }
Show-MediaInfo -Path $final -Extra @{
    '模型' = ('Z-Image Turbo' + $(if ($Lora) { " + $Lora@$LoraStrength" } else { '' }))
    '档位' = ("{0}×{1} / {2} 步 / cfg {3} / {4} / 降级 {5}" -f $Width, $Height, $Steps, $Cfg, $Sampler, $usedTag)
}

Stop-ComfyIfOwned -Config $C -StartedHere $startedHere
Restore-VramPrep -Config $C -State $vramState
exit 0
