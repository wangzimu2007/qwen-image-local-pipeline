# MOSS-Image 文生图（自建版 ComfyUI 0.42.1 / 端口 8188）— 失败自动降级
# 降级顺序：原配置 → 步数 12→8 → 步数 8 + 分辨率 ×0.8 → 关闭风格 LoRA
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
    [switch]$NoLora,
    [switch]$NoOpen,
    [switch]$KeepServer,
    [switch]$NoInfo,
    [switch]$NoFallback,
    [switch]$ForceSlow,
    [switch]$KeepChatBackend,
    [string]$OutDir = ''      # 输出目录（测试图可指向 …\测试）
)

$ErrorActionPreference = 'Stop'
$comfy = 'D:\ComfyUI\ComfyUI'
$imgDir = 'C:\Users\wangzimu\Desktop\Qwen 图片'
if ($OutDir) { $imgDir = $OutDir }
$engineOut = 'D:\moss-image\out'
New-Item -ItemType Directory -Force -Path $engineOut | Out-Null

function Write-H { param([string]$t) Write-Host ''; Write-Host ("== " + $t + " ==") -ForegroundColor Cyan }
function Write-Ok { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Green }
function Write-In { param([string]$t) Write-Host ("  " + $t) -ForegroundColor DarkGray }
function Write-Warn { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Yellow }
function Test-Comfy { try { $null = Invoke-RestMethod 'http://127.0.0.1:8188/system_stats' -TimeoutSec 3; return $true } catch { return $false } }

function Get-EngineKind {
    try {
        $r = Invoke-RestMethod 'http://127.0.0.1:8188/object_info/UNETLoader' -TimeoutSec 8
        $list = $r.UNETLoader.input.required.unet_name[0]
        if (@($list | Where-Object { $_ -match 'moss_image' }).Count -gt 0) { return 'selfbuilt' }
        if (@($list | Where-Object { $_ -match 'z_image' }).Count -gt 0) { return 'desktop' }
        return 'unknown'
    } catch { return 'unknown' }
}

if ($Seed -le 0) { $Seed = Get-Random -Minimum 1 -Maximum 2147483646 }

Write-H 'MOSS-Image 文生图'
$accel = if ($NoLora) { '无加速LoRA' } else { '8步DMD' }
$style = if ($Lora) { " / 风格LoRA $Lora @ $LoraStrength" } else { '' }
Write-In ("{0}×{1} / {2} 步 / cfg {3} / {4} / {5}{6} / seed {7}" -f `
    $Width, $Height, $Steps, $Cfg, $Sampler, $accel, $style, $Seed)

# ---- 显存：够用就跳过，不够才快照 / 卸载 / 出图后恢复 ----
. (Join-Path $PSScriptRoot '_vram.ps1')
. (Join-Path $PSScriptRoot '_meta.ps1')
$vramLockOk = Enter-ImageVramLock -TimeoutSeconds 300
if (-not $vramLockOk) { exit 3 }
$vramState = $null
trap { try { Restore-VramPrep $vramState } catch { }; exit 1 }
$needMB = 15000
$engineRunning = Test-Comfy
if ($ForceSlow) {
    Write-In '指定了 -ForceSlow，跳过显存快照与检查'
} else {
    if ($KeepChatBackend -and -not $engineRunning) {
        Write-Warn '显存不足时会忽略 -KeepChatBackend，自动快照卸载'
    }
    $vramState = Ensure-VramForImage -NeedMiB $needMB -TimeoutSeconds 150 -EngineAlreadyRunning:$engineRunning
}
$freeNow = Get-FreeVramMiB
if (-not (Test-Comfy) -and $freeNow -lt $needMB -and -not $ForceSlow) {
    Write-Host ''
    Write-Host ("  ✗ 可用显存 $freeNow MB，低于 MOSS-Image 需要的 $needMB MB") -ForegroundColor Red
    Write-Host '    继续跑不会报错，但驱动会回退到系统内存 —— 慢 5~10 倍' -ForegroundColor Yellow
    Write-Host '    处理：1) .\显存体检.ps1 -Kill   2) 关掉占显存的聊天客户端' -ForegroundColor Yellow
    Write-Host '    确实想慢慢跑：加 -ForceSlow' -ForegroundColor DarkGray
    Get-VramHolders -Top 5 | ForEach-Object { Write-Host ('      {0,-26} PID {1,-7} {2,6:N2} GB' -f $_.Name, $_.PID, $_.GB) -ForegroundColor DarkGray }
    Restore-VramPrep $vramState
    exit 2
}

# ---- 引擎身份判断 + 启动 ----
$startedHere = $false
if (Test-Comfy) {
    $kind = Get-EngineKind
    if ($kind -eq 'desktop') {
        Write-In '⚠ 8188 上是桌面版引擎（Z-Image），先停掉再启自建版…'
        $pyD = 'D:\Comfy-Desktop\ComfyUI-Installs\ComfyUI (1)\ComfyUI\.venv\Scripts\python.exe'
        Get-Process python -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $pyD } |
            ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
        for ($i = 0; $i -lt 25; $i++) { Start-Sleep -Seconds 1; if (-not (Test-Comfy)) { break } }
        $startedHere = $true
    } elseif ($kind -eq 'selfbuilt') {
        Write-In '自建版引擎已在运行'
    } else {
        throw '8188 被占用但不是已知引擎，请手动处理后重试'
    }
}
if (-not (Test-Comfy)) {
    Write-In '启动自建版 ComfyUI（8188）…'
    Start-Process 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','D:\ComfyUI\start-comfyui.ps1') -WindowStyle Hidden
    $startedHere = $true
    $ok = $false
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Seconds 3
        if (Test-Comfy) { $ok = $true; Write-Ok ("ComfyUI 就绪（" + ($i * 3 + 3) + " 秒）"); break }
    }
    if (-not $ok) { throw 'ComfyUI 启动超时' }
}

function New-Graph {
    param([string]$UseStyleLora, [int]$W, [int]$H, [int]$St)
    $g = @{
        '1'  = @{ class_type = 'UNETLoader'; inputs = @{ unet_name = 'moss_image_sft_int8_convrot.safetensors'; weight_dtype = 'default' } }
        '3'  = @{ class_type = 'CLIPLoader'; inputs = @{ clip_name = 'qwen3.5_9b_w4a8_gptq.safetensors'; type = 'moss_image'; device = 'default' } }
        '4'  = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('3', 0); text = $Prompt } }
        '5'  = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('3', 0); text = $Negative } }
        '6'  = @{ class_type = 'VAELoader'; inputs = @{ vae_name = 'flux2-vae.safetensors' } }
        '7'  = @{ class_type = 'EmptyFlux2LatentImage'; inputs = @{ width = $W; height = $H; batch_size = 1 } }
        '9'  = @{ class_type = 'VAEDecode'; inputs = @{ samples = @('8', 0); vae = @('6', 0) } }
        '10' = @{ class_type = 'SaveImage'; inputs = @{ images = @('9', 0); filename_prefix = 'moss-out' } }
    }
    $ref = @('1', 0)
    if (-not $NoLora) {
        $g['2'] = @{ class_type = 'LoraLoaderModelOnly'; inputs = @{ model = $ref; lora_name = 'moss_image_sft_8steps_dmd.safetensors'; strength_model = 1.0 } }
        $ref = @('2', 0)
    }
    if ($UseStyleLora) {
        $g['30'] = @{ class_type = 'LoraLoaderModelOnly'; inputs = @{ model = $ref; lora_name = $UseStyleLora; strength_model = $LoraStrength } }
        $ref = @('30', 0)
    }
    $g['8'] = @{ class_type = 'KSampler'; inputs = @{
        model = $ref; seed = $Seed; steps = $St; cfg = $Cfg
        sampler_name = $Sampler; scheduler = 'simple'
        positive = @('4', 0); negative = @('5', 0); latent_image = @('7', 0); denoise = 1.0 } }
    return $g
}

function Invoke-Attempt {
    param($Graph)
    $body = @{ prompt = $Graph } | ConvertTo-Json -Depth 12 -Compress
    $id = $null
    try {
        $resp = Invoke-RestMethod 'http://127.0.0.1:8188/prompt' -Method POST -ContentType 'application/json' `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60
        $id = $resp.prompt_id
    } catch {
        $msg = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $_.ErrorDetails.Message }
        if (-not $msg) { $msg = $_.Exception.Message }
        return [pscustomobject]@{ Ok = $false; Error = $msg; Seconds = 0 }
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $done = $false; $errText = ''
    while (-not $done) {
        Start-Sleep -Seconds 1
        try { $h = Invoke-RestMethod ('http://127.0.0.1:8188/history/' + $id) -TimeoutSec 10 } catch { continue }
        if (-not $h.$id) { continue }
        if ($h.$id.status.status_str -eq 'error') {
            $errText = ($h.$id.status.messages | Where-Object { $_[0] -eq 'execution_error' } | ForEach-Object { $_[1].exception_message }) -join ' | '
            $done = $true
        } elseif ($h.$id.outputs) { $done = $true }
        if ($sw.Elapsed.TotalSeconds -gt 1800) { $errText = 'timeout'; $done = $true }
    }
    return [pscustomobject]@{ Ok = (-not $errText); Error = $errText; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

# ---- 降级计划 ----
$plan = @()
$plan += [pscustomobject]@{ Tag = '原配置'; Lora = $Lora; W = $Width; H = $Height; Steps = $Steps }
if (-not $NoFallback) {
    if ($Steps -gt 8) { $plan += [pscustomobject]@{ Tag = '步数 12→8'; Lora = $Lora; W = $Width; H = $Height; Steps = 8 } }
    $w2 = [int]([math]::Round($Width * 0.8 / 16) * 16); if ($w2 -lt 256) { $w2 = 256 }
    $h2 = [int]([math]::Round($Height * 0.8 / 16) * 16); if ($h2 -lt 256) { $h2 = 256 }
    $plan += [pscustomobject]@{ Tag = ("步数 8 + 降分辨率 {0}×{1}" -f $w2, $h2); Lora = $Lora; W = $w2; H = $h2; Steps = 8 }
    if ($Lora) { $plan += [pscustomobject]@{ Tag = '关闭风格 LoRA'; Lora = ''; W = $w2; H = $h2; Steps = 8 } }
}

$okResult = $null; $usedTag = ''; $firstErr = ''
foreach ($a in $plan) {
    Write-In ("尝试：" + $a.Tag + (" / {0}×{1} / {2} 步" -f $a.W, $a.H, $a.Steps))
    $g = New-Graph -UseStyleLora $a.Lora -W $a.W -H $a.H -St $a.Steps
    $r = Invoke-Attempt -Graph $g
    if ($r.Ok) { $okResult = $r; $usedTag = $a.Tag; $Width = $a.W; $Height = $a.H; $Steps = $a.Steps; $Lora = $a.Lora; break }
    if (-not $firstErr) { $firstErr = ($r.Error -split "`n")[0] }
    Write-Warn ("  失败：" + ($r.Error -split "`n")[0])
}

if (-not $okResult) {
    Write-Host ''
    Write-Host ('  ✗ 全部尝试均失败：' + $firstErr) -ForegroundColor Red
    if (-not $KeepServer -and $startedHere) { & powershell -NoProfile -ExecutionPolicy Bypass -File 'D:\ComfyUI\stop-comfyui.ps1' 2>&1 | Out-Null }
    exit 1
}
Write-Ok ("生成完成，用时 {0:N1} 秒" -f $okResult.Seconds)
if ($usedTag -ne '原配置') { Write-Warn ('已自动降级：' + $usedTag) }

# ---- 归位 ----
$produced = $null
foreach ($d in @((Join-Path $comfy 'output'), 'C:\Users\wangzimu\Desktop\ComfyUI 输出')) {
    if (-not (Test-Path $d)) { continue }
    $c = Get-ChildItem $d -Filter 'moss-out*.png' -Recurse -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($c) { $produced = $c; break }
}
if (-not $produced) { Write-Host '  ✗ 没找到输出图片' -ForegroundColor Red; exit 1 }

$ui = Join-Path $PSScriptRoot '_ui.ps1'
if ((Test-Path $ui) -and (Test-Path $imgDir)) {
    . $ui
    $final = Get-NextImagePath -OutDir $imgDir -Kind 'moss'
    Copy-Item $produced.FullName $final -Force
} else {
    $final = Join-Path $engineOut ('moss-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.png')
    Copy-Item $produced.FullName $final -Force
}
Write-Ok ('成品：' + $final)
if (-not $NoOpen) { Start-Process $final }
if (-not $NoInfo) {
    $infScript = Join-Path $PSScriptRoot '_info.ps1'
    if (Test-Path $infScript) {
        . $infScript
        $modelName = 'MOSS-Image SFT int8'
        if (-not $NoLora) { $modelName += ' + 8步DMD' }
        if ($Lora) { $modelName += " + $Lora@$LoraStrength" }
Write-MediaMeta -Path $final -Extra @{ Model = ("MOSS-Image" + $(if ($Lora) { " + $Lora@$LoraStrength" } else { "" })); Prompt = $Prompt; Negative = $Negative; Steps = "$Steps"; Cfg = "$Cfg"; Sampler = $Sampler; Seed = "$Seed"; Size = ("{0}x{1}" -f $Width, $Height) }
        Show-MediaInfo -Path $final -Extra @{
            '模型' = $modelName
            '档位' = ("{0}×{1} / {2} 步 / cfg {3} / {4} / 降级 {5}" -f $Width, $Height, $Steps, $Cfg, $Sampler, $usedTag)
        }
    }
}
if (-not $KeepServer -and $startedHere) {
    Write-In '关闭本次启动的 ComfyUI（恢复之前停掉的本地模型）…'
    & powershell -NoProfile -ExecutionPolicy Bypass -File 'D:\ComfyUI\stop-comfyui.ps1' 2>&1 | Select-Object -Last 2 | ForEach-Object { Write-In $_ }
}
Restore-VramPrep $vramState
exit 0
