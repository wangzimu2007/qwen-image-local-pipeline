# Z-Image Turbo 文生图（含 LoRA 支持）— 用官方桌面版后端（8188）
# 特点：4~6 秒/张，支持挂 LoRA（KOOK 朦胧质感等），失败自动降级
# 降级顺序：原配置 → 关闭 LoRA → 分辨率 ×0.75 → 两者都降
# 用法：
#   .\Z画图.ps1 -Prompt "森林雾气中的白裙女孩"
#   .\Z画图.ps1 -Prompt "..." -Lora Kook_Zimage_ruhmeng.safetensors -LoraStrength 0.8
#   .\Z画图.ps1 -Prompt "..." -Image x.png -Denoise 0.5
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
    [switch]$NoOpen,
    [switch]$KeepServer,
    [switch]$NoInfo,
    [switch]$NoFallback,
    [switch]$ForceSlow,
    [switch]$KeepChatBackend,
    [string]$OutDir = ''      # 输出目录（测试图可指向 …\测试）
)

$ErrorActionPreference = 'Stop'
$inst = 'D:\Comfy-Desktop\ComfyUI-Installs\ComfyUI (1)\ComfyUI'
$py = Join-Path $inst '.venv\Scripts\python.exe'
$imgDir = 'C:\Users\wangzimu\Desktop\Qwen 图片'
if ($OutDir) { $imgDir = $OutDir }
$port = 8188

function Write-H { param([string]$t) Write-Host ''; Write-Host ("== " + $t + " ==") -ForegroundColor Cyan }
function Write-Ok { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Green }
function Write-In { param([string]$t) Write-Host ("  " + $t) -ForegroundColor DarkGray }
function Write-Warn { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Yellow }
function Test-C { try { $null = Invoke-RestMethod ("http://127.0.0.1:$port/system_stats") -TimeoutSec 3; return $true } catch { return $false } }

function Get-EngineKind {
    try {
        $r = Invoke-RestMethod ("http://127.0.0.1:$port/object_info/UNETLoader") -TimeoutSec 8
        $list = $r.UNETLoader.input.required.unet_name[0]
        if (@($list | Where-Object { $_ -match 'moss_image' }).Count -gt 0) { return 'selfbuilt' }
        if (@($list | Where-Object { $_ -match 'z_image' }).Count -gt 0) { return 'desktop' }
        return 'unknown'
    } catch { return 'unknown' }
}

if ($Seed -le 0) { $Seed = Get-Random -Minimum 1 -Maximum 2147483646 }

Write-H 'Z-Image Turbo 文生图'
Write-In ("{0}×{1} / {2} 步{3} / seed {4}{5}" -f $Width, $Height, $Steps,
    $(if($Lora){ " / LoRA $Lora @ $LoraStrength" } else { ' / 无 LoRA' }), $Seed,
    $(if($Image){ " / 图生图 denoise $Denoise" } else { '' }))

# （显存检查已并入下面的快照步骤，释放后统一判断）

# ---- 显存：够用就跳过，不够才快照 / 卸载 / 出图后恢复 ----
. (Join-Path $PSScriptRoot '_vram.ps1')
. (Join-Path $PSScriptRoot '_meta.ps1')
$vramLockOk = Enter-ImageVramLock -TimeoutSeconds 300
if (-not $vramLockOk) { exit 3 }
$vramState = $null
trap { try { Restore-VramPrep $vramState } catch { }; exit 1 }
$needMB = 14000
$engineRunning = Test-C
if ($ForceSlow) {
    Write-In '指定了 -ForceSlow，跳过显存快照与检查'
} else {
    if ($KeepChatBackend -and -not $engineRunning) {
        Write-Warn '显存不足时会忽略 -KeepChatBackend，自动快照卸载'
    }
    $vramState = Ensure-VramForImage -NeedMiB $needMB -TimeoutSeconds 150 -EngineAlreadyRunning:$engineRunning
}
$freeNow = Get-FreeVramMiB
if (-not (Test-C) -and $freeNow -lt $needMB -and -not $ForceSlow) {
    Write-Host ''
    Write-Host ("  ✗ 可用显存 $freeNow MB，低于 Z-Image 需要的 $needMB MB") -ForegroundColor Red
    Write-Host '    继续跑不会报错，但驱动会回退到系统内存 —— 慢 5~10 倍' -ForegroundColor Yellow
    Write-Host '    处理：1) .\显存体检.ps1 -Kill   2) 关掉占显存的聊天客户端' -ForegroundColor Yellow
    Write-Host '    确实想慢慢跑：加 -ForceSlow' -ForegroundColor DarkGray
    Get-VramHolders -Top 5 | ForEach-Object { Write-Host ('      {0,-26} PID {1,-7} {2,6:N2} GB' -f $_.Name, $_.PID, $_.GB) -ForegroundColor DarkGray }
    Restore-VramPrep $vramState
    exit 2
}

# ---- 引擎身份判断 + 启动 ----
$startedHere = $false
if (Test-C) {
    $kind = Get-EngineKind
    if ($kind -eq 'selfbuilt') {
        Write-In '⚠ 8188 上是自建版引擎（MOSS），先停掉再启桌面版…'
        & powershell -NoProfile -ExecutionPolicy Bypass -File 'D:\ComfyUI\stop-comfyui.ps1' 2>&1 | Out-Null
        for ($i = 0; $i -lt 25; $i++) { Start-Sleep -Seconds 1; if (-not (Test-C)) { break } }
        $startedHere = $true
    } elseif ($kind -eq 'desktop') {
        Write-In '桌面版后端已在运行'
    } else {
        throw '8188 被占用但不是已知引擎，请手动处理后重试'
    }
}
if (-not (Test-C)) {
    Write-In '启动桌面版 ComfyUI 后端（8188）…'
    $env:ELECTRON_RUN_AS_NODE = $null
    Start-Process -FilePath $py -ArgumentList @('main.py','--port',"$port",'--listen','127.0.0.1') -WorkingDirectory $inst -WindowStyle Hidden
    $startedHere = $true
    $ok = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 3
        if (Test-C) { $ok = $true; Write-Ok ("后端就绪（" + ($i*3+3) + " 秒）"); break }
    }
    if (-not $ok) { throw '桌面版后端启动超时' }
}

# ---- 图生图输入准备 ----
$inputName = ''
if ($Image) {
    if (-not (Test-Path $Image)) { throw ("输入图片不存在: " + $Image) }
    $inputDir = Join-Path $inst 'input'
    New-Item -ItemType Directory -Force -Path $inputDir | Out-Null
    $inputName = 'zimg-src-' + (Get-Date -Format 'HHmmssfff') + [System.IO.Path]::GetExtension($Image)
    Copy-Item $Image (Join-Path $inputDir $inputName) -Force
    Write-In ("图生图输入: " + $inputName + " / denoise " + $Denoise)
}

function New-Graph {
    param([string]$UseLora, [int]$W, [int]$H)
    $gn = @{
        '1'  = @{ class_type = 'UNETLoader'; inputs = @{ unet_name = 'z_image_turbo_nvfp4.safetensors'; weight_dtype = 'default' } }
        '3'  = @{ class_type = 'CLIPLoader'; inputs = @{ clip_name = 'qwen_3_4b.safetensors'; type = 'lumina2'; device = 'default' } }
        '4'  = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('3', 0); text = $Prompt } }
        '5'  = @{ class_type = 'ConditioningZeroOut'; inputs = @{ conditioning = @('4', 0) } }
        '6'  = @{ class_type = 'VAELoader'; inputs = @{ vae_name = 'ae.safetensors' } }
        '10' = @{ class_type = 'VAEDecode'; inputs = @{ samples = @('9', 0); vae = @('6', 0) } }
        '11' = @{ class_type = 'SaveImage'; inputs = @{ images = @('10', 0); filename_prefix = 'zimg-out' } }
    }
    if ($UseLora) {
        $gn['2'] = @{ class_type = 'LoraLoaderModelOnly'; inputs = @{ model = @('1', 0); lora_name = $UseLora; strength_model = $LoraStrength } }
        $gn['8'] = @{ class_type = 'ModelSamplingAuraFlow'; inputs = @{ model = @('2', 0); shift = $Shift } }
    } else {
        $gn['8'] = @{ class_type = 'ModelSamplingAuraFlow'; inputs = @{ model = @('1', 0); shift = $Shift } }
    }
    if ($Negative) {
        $gn['12'] = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('3', 0); text = $Negative } }
        $negRef = @('12', 0)
    } else {
        $negRef = @('5', 0)
    }
    if ($inputName) {
        $gn['20'] = @{ class_type = 'LoadImage'; inputs = @{ image = $inputName } }
        $gn['21'] = @{ class_type = 'VAEEncode'; inputs = @{ pixels = @('20', 0); vae = @('6', 0) } }
        $latentRef = @('21', 0)
        $den = $Denoise
    } else {
        $gn['7'] = @{ class_type = 'EmptySD3LatentImage'; inputs = @{ width = $W; height = $H; batch_size = 1 } }
        $latentRef = @('7', 0)
        $den = 1.0
    }
    $gn['9'] = @{ class_type = 'KSampler'; inputs = @{
        model = @('8', 0); seed = $Seed; steps = $Steps; cfg = $Cfg
        sampler_name = $Sampler; scheduler = 'simple'
        positive = @('4', 0); negative = $negRef; latent_image = $latentRef; denoise = $den } }
    return $gn
}

function Invoke-Attempt {
    param($Graph)
    $body = @{ prompt = $Graph } | ConvertTo-Json -Depth 12 -Compress
    $id = $null
    try {
        $resp = Invoke-RestMethod ("http://127.0.0.1:$port/prompt") -Method POST -ContentType 'application/json' `
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
        Start-Sleep -Milliseconds 900
        try { $h = Invoke-RestMethod ("http://127.0.0.1:$port/history/" + $id) -TimeoutSec 10 } catch { continue }
        if (-not $h.$id) { continue }
        if ($h.$id.status.status_str -eq 'error') {
            $errText = ($h.$id.status.messages | Where-Object { $_[0] -eq 'execution_error' } | ForEach-Object { $_[1].exception_message }) -join ' | '
            $done = $true
        } elseif ($h.$id.outputs) { $done = $true }
        if ($sw.Elapsed.TotalSeconds -gt 900) { $errText = 'timeout'; $done = $true }
    }
    return [pscustomobject]@{ Ok = (-not $errText); Error = $errText; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

# ---- 降级计划 ----
$plan = @()
$plan += [pscustomobject]@{ Tag = '原配置'; Lora = $Lora; W = $Width; H = $Height }
if ($Lora -and -not $NoFallback) {
    $plan += [pscustomobject]@{ Tag = '关闭风格 LoRA'; Lora = ''; W = $Width; H = $Height }
}
if (-not $NoFallback) {
    $w2 = [int]([math]::Round($Width * 0.75 / 16) * 16); if ($w2 -lt 256) { $w2 = 256 }
    $h2 = [int]([math]::Round($Height * 0.75 / 16) * 16); if ($h2 -lt 256) { $h2 = 256 }
    $plan += [pscustomobject]@{ Tag = ("降分辨率 {0}×{1}" -f $w2, $h2); Lora = $Lora; W = $w2; H = $h2 }
    if ($Lora) { $plan += [pscustomobject]@{ Tag = '关闭 LoRA + 降分辨率'; Lora = ''; W = $w2; H = $h2 } }
}

$okResult = $null; $usedTag = ''; $firstErr = ''
foreach ($a in $plan) {
    Write-In ("尝试：" + $a.Tag + $(if($a.Lora){"（LoRA " + $a.Lora + "）"}else{''}) + (" {0}×{1}" -f $a.W, $a.H))
    $g = New-Graph -UseLora $a.Lora -W $a.W -H $a.H
    $r = Invoke-Attempt -Graph $g
    if ($r.Ok) { $okResult = $r; $usedTag = $a.Tag; $Width = $a.W; $Height = $a.H; $Lora = $a.Lora; break }
    if (-not $firstErr) { $firstErr = ($r.Error -split "`n")[0] }
    Write-Warn ("  失败：" + ($r.Error -split "`n")[0])
}

if (-not $okResult) {
    Write-Host ''
    Write-Host ('  ✗ 全部尝试均失败：' + $firstErr) -ForegroundColor Red
    if (-not $KeepServer -and $startedHere) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File 'D:\ComfyUI\stop-comfyui.ps1' 2>&1 | Out-Null
    }
    Restore-VramPrep $vramState
    exit 1
}
Write-Ok ("生成完成，用时 {0:N1} 秒" -f $okResult.Seconds)
if ($usedTag -ne '原配置') { Write-Warn ('已自动降级：' + $usedTag) }

# ---- 归位 ----
$produced = $null
foreach ($d in @((Join-Path $inst 'output'), 'C:\Users\wangzimu\Desktop\ComfyUI 输出')) {
    if (-not (Test-Path $d)) { continue }
    $c = Get-ChildItem $d -Filter 'zimg-out*.png' -Recurse -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($c) { $produced = $c; break }
}
if (-not $produced) { Write-Host '  ✗ 没找到输出图片' -ForegroundColor Red; exit 1 }

$ui = Join-Path $PSScriptRoot '_ui.ps1'
if ((Test-Path $ui) -and (Test-Path $imgDir)) {
    . $ui
    $final = Get-NextImagePath -OutDir $imgDir -Kind 'zimg'
    Copy-Item $produced.FullName $final -Force
} else {
    $final = Join-Path $env:TEMP ('zimg-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.png')
    Copy-Item $produced.FullName $final -Force
}
Write-Ok ('成品：' + $final)
if (-not $NoOpen) { Start-Process $final }
if (-not $NoInfo) {
    $inf = Join-Path $PSScriptRoot '_info.ps1'
    if (Test-Path $inf) {
        . $inf
        $modelName = 'Z-Image Turbo nvfp4'
        if ($Lora) { $modelName += " + LoRA($Lora @ $LoraStrength)" }
Write-MediaMeta -Path $final -Extra @{ Model = ("Z-Image Turbo" + $(if ($Lora) { " + $Lora@$LoraStrength" } else { "" })); Prompt = $Prompt; Steps = "$Steps"; Cfg = "$Cfg"; Sampler = $Sampler; Seed = "$Seed"; Size = ("{0}x{1}" -f $Width, $Height); Lora = $Lora; LoraStrength = "$LoraStrength" }
        Show-MediaInfo -Path $final -Extra @{
            '模型' = $modelName
            '档位' = ("{0}×{1} / {2} 步 / cfg {3} / {4} / shift {5} / 降级 {6}" -f $Width, $Height, $Steps, $Cfg, $Sampler, $Shift, $usedTag)
        }
    }
}
if (-not $KeepServer -and $startedHere) {
    Write-In '关闭本次启动的后端…'
    Get-Process python -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $py } |
        ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
}
Restore-VramPrep $vramState
exit 0
