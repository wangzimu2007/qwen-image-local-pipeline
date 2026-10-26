param(
    [Parameter(Mandatory = $true)]
    [string]$Prompt,
    [int]$Width = 1024,
    [int]$Height = 1024,
    [int]$Steps = 8,
    [int]$Seed = -1,
    [string]$Negative = "",
    [string]$Out = "",
    # 图生图：给初始图 + 重绘强度（实测这个模型 0.7 以下几乎不变，0.85 整体重绘）
    [string]$InitImage = "",
    [double]$Strength = 0.85
)

$ErrorActionPreference = "Stop"
$root = "D:\qwen-image-2.1"
$exe = Join-Path $root "bin\sdcpp\sd-cli.exe"
if (-not (Test-Path $exe)) {
    $alt = Join-Path $root "bin\sd-cli.exe"
    if (Test-Path $alt) { $exe = $alt } else { throw "sd-cli not found under $root\bin" }
}

if (-not $Out) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $Out = Join-Path $root "output\qwen-$stamp.png"
}

$sigmas = "1.0,0.978453,0.95418,0.926626,0.89508,0.845148,0.704534,0.414568,0.0"
$args = @(
    "--diffusion-model", (Join-Path $root "models\diffusion_models\Qwen-Image-2.1-Turbo-AD-Q6_K.gguf"),
    "--llm", (Join-Path $root "models\text_encoders\Qwen-Image-2.1-Turbo-Uncensored-Q8_0.gguf"),
    "--vae", (Join-Path $root "models\vae\qwen_image_2.1_vae_bf16.safetensors"),
    "-p", $Prompt,
    "--steps", "$Steps",
    "--cfg-scale", "1.0",
    "--sampling-method", "euler",
    "--sigmas", $sigmas,
    "-W", "$Width",
    "-H", "$Height",
    "--diffusion-fa",
    "-o", $Out
)
if ($Negative) { $args += @("--negative-prompt", $Negative) }
if ($Seed -ge 0) { $args += @("--seed", "$Seed") }
if ($InitImage) {
    if (-not (Test-Path $InitImage)) { throw "找不到初始图：$InitImage" }
    $args += @("-i", $InitImage, "--strength", "$Strength")
}

Write-Host "Running: $exe" -ForegroundColor Cyan
Write-Host "Output : $Out" -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()
& $exe @args
$code = $LASTEXITCODE
$sw.Stop()
Write-Host ("Exit {0}, took {1:N1}s" -f $code, $sw.Elapsed.TotalSeconds)
if (Test-Path $Out) { Write-Host "Saved: $Out" -ForegroundColor Green }
exit $code
