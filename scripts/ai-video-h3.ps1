# 文生视频 + 音频：MiniMax H3（ComfyUI，一次出画面与 32kHz 立体声）
# 实测（RTX 5090 Laptop 24GB，124 帧 ≈5.2 秒，Turbo 8 步）：
#   640×360 约 43 秒 / 960×540 约 113 秒 / 1344×768 约 324 秒（显存 20~23 GB）
# 注意：视频 VAE 必须用 fp16 版；int8_convrot 版会解出全黑画面（实测）
# 用法：
#   .\ai-video-h3.ps1 -Prompt "海边灯塔，黄昏，海浪声，海鸟鸣叫" -Seconds 5
#   .\ai-video-h3.ps1 -Prompt "..." -Width 1344 -Height 768
param(
    [Parameter(Mandatory = $true)][string]$Prompt,
    [int]$Width = 960,
    [int]$Height = 540,
    [int]$Seconds = 5,
    [int]$Steps = 8,
    [int]$Seed = 0,
    [string]$OutDir = '',
    [switch]$NoTurboLora,
    [switch]$NoFallback,
    [switch]$KeepServer,
    [switch]$KeepChatBackend
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\vram.ps1"
. "$PSScriptRoot\lib\info.ps1"

$C = Get-PipelineConfig
$outDir = if ($OutDir) { $OutDir } elseif ($C.OutVideoDir) { $C.OutVideoDir } else { Ensure-Dir (Join-Path $script:RepoRoot 'output\videos') }
Ensure-Dir $outDir | Out-Null
if ($Seed -le 0) { $Seed = Get-Random -Minimum 1 -Maximum 2147483646 }

function Get-H3Length { param([int]$Sec) $l = 17 * [int][math]::Round(($Sec * 24 - 5) / 17.0) + 5; if ($l -lt 5) { $l = 5 }; return $l }
$length = Get-H3Length -Sec $Seconds

Write-Head 'MiniMax H3 文生视频（带音频）'
Write-Info ("{0}×{1} / {2} 帧 @24fps ≈ {3:N1} 秒 / {4} 步 / seed {5}" -f $Width, $Height, $length, ($length / 24), $Steps, $Seed)

# ---- 显存快照 ----
$vramState = $null
trap { try { Restore-VramPrep -Config $C -State $vramState } catch { }; exit 1 }
if (-not $KeepChatBackend) { $vramState = Start-VramPrep -Config $C -NeedMB 16000 -TimeoutSec 180 }

$startedHere = Start-ComfyIfNeeded -Config $C
if ($startedHere) { Write-Ok 'ComfyUI 已就绪' }

function New-H3Graph {
    param([int]$W, [int]$H, [int]$Len)
    $g = @{
        '1'  = @{ class_type = 'UNETLoader'; inputs = @{ unet_name = $(if ($C.H3Unet) { $C.H3Unet } else { 'minimax_h3_fl2va_pruned_int8_convrot.safetensors' }); weight_dtype = 'default' } }
        '3'  = @{ class_type = 'CLIPLoader'; inputs = @{ clip_name = $(if ($C.H3Clip) { $C.H3Clip } else { 'qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors' }); type = 'minimax'; device = 'default' } }
        '4'  = @{ class_type = 'VAELoader'; inputs = @{ vae_name = $(if ($C.H3VideoVae) { $C.H3VideoVae } else { 'minimax_h3_video_vae_fp16.safetensors' }) } }
        '5'  = @{ class_type = 'VAELoader'; inputs = @{ vae_name = $(if ($C.H3AudioVae) { $C.H3AudioVae } else { 'minimax_h3_audio_vae_fp32.safetensors' }) } }
        '6'  = @{ class_type = 'MiniMaxH3ImageToVideo'; inputs = @{
                    clip = @('3', 0); vae = @('4', 0); prompt = $Prompt
                    width = $W; height = $H; length = $Len } }
        '8'  = @{ class_type = 'BasicScheduler'; inputs = @{ model = @('2', 0); scheduler = 'simple'; steps = $Steps; denoise = 1.0 } }
        '9'  = @{ class_type = 'KSamplerSelect'; inputs = @{ sampler_name = 'res_multistep' } }
        '10' = @{ class_type = 'RandomNoise'; inputs = @{ noise_seed = $Seed } }
        '11' = @{ class_type = 'SamplerCustomAdvanced'; inputs = @{
                    noise = @('10', 0); guider = @('7', 0); sampler = @('9', 0)
                    sigmas = @('8', 0); latent_image = @('6', 1) } }
        '12' = @{ class_type = 'VAEDecode'; inputs = @{ samples = @('11', 0); vae = @('4', 0) } }
        '13' = @{ class_type = 'VAEDecodeAudio'; inputs = @{ samples = @('11', 0); vae = @('5', 0) } }
        '14' = @{ class_type = 'CreateVideo'; inputs = @{ images = @('12', 0); audio = @('13', 0); fps = 24 } }
        '15' = @{ class_type = 'SaveVideo'; inputs = @{ video = @('14', 0); filename_prefix = 'pipe-h3'; format = 'mp4'; codec = 'h264' } }
    }
    if ($NoTurboLora) {
        $g['2'] = @{ class_type = 'UNETLoader'; inputs = @{ unet_name = $(if ($C.H3Unet) { $C.H3Unet } else { 'minimax_h3_fl2va_pruned_int8_convrot.safetensors' }); weight_dtype = 'default' } }
        $g['7'] = @{ class_type = 'BasicGuider'; inputs = @{ model = @('1', 0); conditioning = @('6', 0) } }
        $g['8'].inputs.model = @('1', 0)
    } else {
        $lora = if ($C.H3TurboLora) { $C.H3TurboLora } else { 'minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors' }
        $g['2'] = @{ class_type = 'LoraLoaderModelOnly'; inputs = @{ model = @('1', 0); lora_name = $lora; strength_model = 1.0 } }
        $g['7'] = @{ class_type = 'BasicGuider'; inputs = @{ model = @('2', 0); conditioning = @('6', 0) } }
    }
    return $g
}

# ---- 降级计划（按比例缩小，32 的倍数，最小 512）----
function Snap32 { param([int]$v) $x = [int]([math]::Round($v / 32.0) * 32); if ($x -lt 512) { $x = 512 }; if ($x -gt 1344) { $x = 1344 }; return $x }
$plan = @([pscustomobject]@{ Tag = '原配置'; W = $Width; H = $Height })
if (-not $NoFallback) {
    $w1 = Snap32 ([int]($Width * 0.78)); $h1 = Snap32 ([int]($Height * 0.78))
    $w2 = Snap32 ([int]($Width * 0.6));  $h2 = Snap32 ([int]($Height * 0.6))
    if ($w1 -lt $Width -or $h1 -lt $Height) { $plan += [pscustomobject]@{ Tag = ("降档 {0}×{1}" -f $w1, $h1); W = $w1; H = $h1 } }
    if ($w2 -lt $w1 -or $h2 -lt $h1) { $plan += [pscustomobject]@{ Tag = ("降档 {0}×{1}" -f $w2, $h2); W = $w2; H = $h2 } }
}

$ok = $false; $usedTag = ''; $firstErr = ''; $seconds = 0; $length = Get-H3Length -Sec $Seconds
foreach ($a in $plan) {
    $length = Get-H3Length -Sec $Seconds
    Write-Info ("尝试：" + $a.Tag + (" {0}×{1} / {2} 帧" -f $a.W, $a.H, $length))
    $r = Invoke-ComfyPrompt -Config $C -Graph (New-H3Graph -W $a.W -H $a.H -Len $length) -DoneNode '15'
    if ($r.Ok) { $ok = $true; $usedTag = $a.Tag; $Width = $a.W; $Height = $a.H; $seconds = $r.Seconds; break }
    if (-not $firstErr) { $firstErr = ($r.Error -split "`n")[0] }
    Write-Warn2 ('  失败：' + ($r.Error -split "`n")[0])
}

if (-not $ok) {
    if (-not $KeepServer) { Stop-ComfyIfOwned -Config $C -StartedHere $startedHere }
    Restore-VramPrep -Config $C -State $vramState
    Fail ('全部尝试均失败：' + $firstErr)
}
Write-Ok ("生成完成，用时 {0:N1} 秒（{1:N1} 分钟）" -f $seconds, ($seconds / 60))
if ($usedTag -ne '原配置') { Write-Warn2 ('已自动降级：' + $usedTag) }

# ---- 取视频 ----
$produced = Get-NewestFile -Dir $C.ComfyOutputDir -Filter 'pipe-h3*.mp4'
if (-not $produced) { $produced = Get-NewestFile -Dir (Join-Path $C.ComfyRoot 'output') -Filter 'pipe-h3*.mp4' }
if (-not $produced) {
    if (-not $KeepServer) { Stop-ComfyIfOwned -Config $C -StartedHere $startedHere }
    Restore-VramPrep -Config $C -State $vramState
    Fail '没找到输出视频（检查 ComfyOutputDir 配置）'
}
$final = Join-Path $outDir ('h3-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.mp4')
Copy-Item $produced.FullName $final -Force
Write-Ok ('成品：' + $final)
Show-MediaInfo -Path $final -Extra @{
    '模型' = 'MiniMax H3 (FL2VA int8 + Turbo 8step)'
    '档位' = ("{0}×{1} / {2} 帧 / {3} 步 / 降级 {4}" -f $Width, $Height, $length, $Steps, $usedTag)
}

if (-not $KeepServer) { Stop-ComfyIfOwned -Config $C -StartedHere $startedHere }
Restore-VramPrep -Config $C -State $vramState
exit 0
