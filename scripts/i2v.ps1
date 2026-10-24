# 图生视频（Wan 2.2 TI2V-5B，ComfyUI API）
# 用法：scripts\i2v.ps1 -Image x.png -Prompt "镜头缓慢推进" -Seconds 5
param(
    [Parameter(Mandatory = $true)][string]$Image,
    [string]$Prompt = '镜头缓慢推进，画面自然地动起来，光影流动',
    [int]$Seconds = 5,
    [int]$Fps = 24,
    [int]$Steps = 20,
    [double]$Cfg = 5.0,
    [int]$Width = 0,      # 0 = 按原图自动（对齐 32，上限约 0.55 MP）
    [int]$Height = 0,
    [int]$Seed = 42,
    [switch]$KeepServer,
    [switch]$NoInfo
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\output.ps1"
. "$PSScriptRoot\lib\info.ps1"
$cfg = Get-PipelineConfig
$py  = Get-Python $cfg

$src = Assert-FilePath $Image '输入图片'
$tools = Join-Path $PSScriptRoot 'lib\video_tools.py'
Assert-FilePath $tools 'video_tools.py' | Out-Null

# ---- 目标分辨率 ----
if ($Width -le 0 -or $Height -le 0) {
    Add-Type -AssemblyName System.Drawing
    $img = [System.Drawing.Image]::FromFile($src)
    $srcW = $img.Width; $srcH = $img.Height
    $img.Dispose()
    $maxPixels = 0.55 * 1000000
    $scale = [math]::Sqrt($maxPixels / ($srcW * $srcH))
    if ($scale -gt 1) { $scale = 1 }
    $Width  = [int]([math]::Round($srcW * $scale / 32.0) * 32)
    $Height = [int]([math]::Round($srcH * $scale / 32.0) * 32)
    if ($Width  -lt 256) { $Width  = 256 }
    if ($Height -lt 256) { $Height = 256 }
    if ($Width  -gt 1280) { $Width  = 1280 }
    if ($Height -gt 1280) { $Height = 1280 }
}
# ---- 帧数必须 4n+1 ----
$frames = [int]([math]::Round($Seconds * $Fps))
$frames = 4 * [int][math]::Round(($frames - 1) / 4.0) + 1
if ($frames -lt 5) { $frames = 5 }

Write-Head '图生视频'
Write-Info ("{0} × {1} / {2} 帧 @ {3}fps ≈ {4:N1} 秒 / {5} 步" -f $Width, $Height, $frames, $Fps, ($frames / $Fps), $Steps)

$startedHere = Start-ComfyIfNeeded -Config $cfg
$inName = Copy-ToComfyInput -Config $cfg -FilePath $src

$graph = @{
    '1'  = @{ class_type = 'UNETLoader';    inputs = @{ unet_name = $cfg.WanUnet; weight_dtype = 'default' } }
    '2'  = @{ class_type = 'ModelSamplingSD3'; inputs = @{ model = @('1', 0); shift = 8.0 } }
    '3'  = @{ class_type = 'CLIPLoader';    inputs = @{ clip_name = $cfg.WanClip; type = 'wan' } }
    '4'  = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('3', 0); text = $Prompt } }
    '5'  = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('3', 0); text = '模糊，低质量，变形，闪烁，画面抖动' } }
    '6'  = @{ class_type = 'VAELoader';     inputs = @{ vae_name = $cfg.WanVae } }
    '12' = @{ class_type = 'LoadImage';     inputs = @{ image = $inName } }
    '7'  = @{ class_type = 'Wan22ImageToVideoLatent'; inputs = @{
                vae = @('6', 0); width = $Width; height = $Height; length = $frames; batch_size = 1; start_image = @('12', 0) } }
    '8'  = @{ class_type = 'KSampler'; inputs = @{
                model = @('2', 0); seed = $Seed; steps = $Steps; cfg = $Cfg;
                sampler_name = 'euler'; scheduler = 'simple';
                positive = @('4', 0); negative = @('5', 0); latent_image = @('7', 0); denoise = 1.0 } }
    '9'  = @{ class_type = 'VAEDecode'; inputs = @{ samples = @('8', 0); vae = @('6', 0) } }
    '10' = @{ class_type = 'CreateVideo'; inputs = @{ images = @('9', 0); fps = [double]$Fps } }
    '11' = @{ class_type = 'SaveVideo'; inputs = @{ video = @('10', 0); filename_prefix = 'pipe-i2v'; format = 'mp4'; codec = 'h264' } }
}

$r = Invoke-ComfyPrompt -Config $cfg -Graph $graph -DoneNode '11'
if (-not $r.Ok) {
    Write-Warn2 ('生成失败：' + $r.Error)
    Stop-ComfyIfOwned -Config $cfg -StartedHere $startedHere
    exit 1
}

$comfyOut = Get-ComfyOutputDir -Config $cfg
$produced = Get-NewestFile -Dir $comfyOut -Filter 'pipe-i2v*.mp4'
if (-not $produced) { Write-Warn2 '找不到生成的视频'; Stop-ComfyIfOwned -Config $cfg -StartedHere $startedHere; exit 1 }

$final = Save-VideoOutput -Config $cfg -SourceFile $produced.FullName -Kind 'wan'
Write-Ok ("生成完成，用时 {0:N1} 秒" -f $r.Seconds)
Write-Ok ("成品：" + $final)
if (-not $NoInfo) { Show-MediaInfo -Path $final -Python $py -Extra @{ '模型' = 'Wan 2.2 TI2V-5B'; '流程' = '图生视频' } }

Stop-ComfyIfOwned -Config $cfg -StartedHere ($startedHere -and -not $KeepServer)
exit 0
