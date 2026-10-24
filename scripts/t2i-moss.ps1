# 文生图：MOSS-Image（ComfyUI，写实人像强，支持风格 LoRA、失败自动降级、显存快照）
# 实测（RTX 5090 Laptop 24GB）：1024²/12 步约 10~16 秒；加风格 LoRA 12~22 秒
# 注意：加速 LoRA（8 步 DMD）必须排在风格 LoRA 之前，否则步数蒸馏失效
# 用法：
#   .\t2i-moss.ps1 -Prompt "Editorial portrait, soft window light, 85mm"
#   .\t2i-moss.ps1 -Prompt "..." -Lora KOOK-MOSS-SFT-guanlan.safetensors -LoraStrength 0.8
param(
    [Parameter(Mandatory = $true)][string]$Prompt,
    [string]$Negative = 'nsfw, worst quality, bad anatomy, watermark, jpeg artifacts, lowres, text artifacts',
    [int]$Width = 1024,
    [int]$Height = 1024,
    [int]$Steps = 12,
    [double]$Cfg = 1.0,
    [string]$Sampler = 'er_sde',
    [int]$Seed = 0,
    [string]$Lora = '',
    [double]$LoraStrength = 0.8,
    [string]$OutDir = '',
    [switch]$NoAccelLora,
    [switch]$NoOpen,
    [switch]$NoFallback,
    [switch]$KeepChatBackend
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\vram.ps1"
. "$PSScriptRoot\lib\info.ps1"

$C = Get-PipelineConfig
$outDir = if ($OutDir) { $OutDir } elseif ($C.OutImageDir) { $C.OutImageDir } else { Ensure-Dir (Join-Path $script:RepoRoot 'output\images') }
Ensure-Dir $outDir | Out-Null
if ($Seed -le 0) { $Seed = Get-Random -Minimum 1 -Maximum 2147483646 }

Write-Head 'MOSS-Image 文生图'
Write-Info ("{0}×{1} / {2} 步 / cfg {3}{4} / seed {5}" -f $Width, $Height, $Steps, $Cfg,
    $(if ($Lora) { " / 风格LoRA $Lora @ $LoraStrength" } else { '' }), $Seed)

# ---- 显存快照 ----
$vramState = $null
trap { try { Restore-VramPrep -Config $C -State $vramState } catch { }; exit 1 }
if (-not $KeepChatBackend) { $vramState = Start-VramPrep -Config $C -NeedMB 16000 -TimeoutSec 180 }

$startedHere = Start-ComfyIfNeeded -Config $C
if ($startedHere) { Write-Ok 'ComfyUI 已就绪' }

function New-MossGraph {
    param([string]$StyleLora, [int]$W, [int]$H, [int]$St)
    $g = @{
        '1'  = @{ class_type = 'UNETLoader'; inputs = @{ unet_name = $(if ($C.MossUnet) { $C.MossUnet } else { 'moss_image_sft_int8_convrot.safetensors' }); weight_dtype = 'default' } }
        '3'  = @{ class_type = 'CLIPLoader'; inputs = @{ clip_name = $(if ($C.MossClip) { $C.MossClip } else { 'qwen3.5_9b_w4a8_gptq.safetensors' }); type = 'moss_image'; device = 'default' } }
        '4'  = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('3', 0); text = $Prompt } }
        '5'  = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('3', 0); text = $Negative } }
        '6'  = @{ class_type = 'VAELoader'; inputs = @{ vae_name = $(if ($C.MossVae) { $C.MossVae } else { 'flux2-vae.safetensors' }) } }
        '7'  = @{ class_type = 'EmptyFlux2LatentImage'; inputs = @{ width = $W; height = $H; batch_size = 1 } }
        '9'  = @{ class_type = 'VAEDecode'; inputs = @{ samples = @('8', 0); vae = @('6', 0) } }
        '10' = @{ class_type = 'SaveImage'; inputs = @{ images = @('9', 0); filename_prefix = 'pipe-moss' } }
    }
    $ref = @('1', 0)
    if (-not $NoAccelLora) {
        $accel = if ($C.MossAccelLora) { $C.MossAccelLora } else { 'moss_image_sft_8steps_dmd.safetensors' }
        $g['2'] = @{ class_type = 'LoraLoaderModelOnly'; inputs = @{ model = $ref; lora_name = $accel; strength_model = 1.0 } }
        $ref = @('2', 0)
    }
    if ($StyleLora) {
        $g['30'] = @{ class_type = 'LoraLoaderModelOnly'; inputs = @{ model = $ref; lora_name = $StyleLora; strength_model = $LoraStrength } }
        $ref = @('30', 0)
    }
    $g['8'] = @{ class_type = 'KSampler'; inputs = @{
        model = $ref; seed = $Seed; steps = $St; cfg = $Cfg
        sampler_name = $Sampler; scheduler = 'simple'
        positive = @('4', 0); negative = @('5', 0); latent_image = @('7', 0); denoise = 1.0 } }
    return $g
}

# ---- 降级计划 ----
$plan = @([pscustomobject]@{ Tag = '原配置'; Lora = $Lora; W = $Width; H = $Height; Steps = $Steps })
if (-not $NoFallback) {
    if ($Steps -gt 8) { $plan += [pscustomobject]@{ Tag = '步数 12→8'; Lora = $Lora; W = $Width; H = $Height; Steps = 8 } }
    $w2 = [int]([math]::Round($Width * 0.8 / 16) * 16); if ($w2 -lt 256) { $w2 = 256 }
    $h2 = [int]([math]::Round($Height * 0.8 / 16) * 16); if ($h2 -lt 256) { $h2 = 256 }
    $plan += [pscustomobject]@{ Tag = ("步数 8 + 降分辨率 {0}×{1}" -f $w2, $h2); Lora = $Lora; W = $w2; H = $h2; Steps = 8 }
    if ($Lora) { $plan += [pscustomobject]@{ Tag = '关闭风格 LoRA'; Lora = ''; W = $w2; H = $h2; Steps = 8 } }
}

$ok = $false; $usedTag = ''; $firstErr = ''; $seconds = 0
foreach ($a in $plan) {
    Write-Info ("尝试：" + $a.Tag + (" / {0}×{1} / {2} 步" -f $a.W, $a.H, $a.Steps))
    $r = Invoke-ComfyPrompt -Config $C -Graph (New-MossGraph -StyleLora $a.Lora -W $a.W -H $a.H -St $a.Steps) -DoneNode '10'
    if ($r.Ok) { $ok = $true; $usedTag = $a.Tag; $Width = $a.W; $Height = $a.H; $Steps = $a.Steps; $Lora = $a.Lora; $seconds = $r.Seconds; break }
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

$produced = Get-NewestFile -Dir $C.ComfyOutputDir -Filter 'pipe-moss*.png'
if (-not $produced) { $produced = Get-NewestFile -Dir (Join-Path $C.ComfyRoot 'output') -Filter 'pipe-moss*.png' }
if (-not $produced) {
    Stop-ComfyIfOwned -Config $C -StartedHere $startedHere
    Restore-VramPrep -Config $C -State $vramState
    Fail '没找到输出图片（检查 ComfyOutputDir 配置）'
}
$final = Join-Path $outDir ('moss-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.png')
Copy-Item $produced.FullName $final -Force
Write-Ok ('成品：' + $final)
if (-not $NoOpen) { Start-Process $final }
Show-MediaInfo -Path $final -Extra @{
    '模型' = ('MOSS-Image' + $(if ($Lora) { " + $Lora@$LoraStrength" } else { '' }))
    '档位' = ("{0}×{1} / {2} 步 / {3} / 降级 {4}" -f $Width, $Height, $Steps, $Sampler, $usedTag)
}

Stop-ComfyIfOwned -Config $C -StartedHere $startedHere
Restore-VramPrep -Config $C -State $vramState
exit 0
