# 文本生成视频 + 音频（MiniMax H3，本地）— 带显存快照版
# 特点：一次生成「画面 + 32kHz 立体声」，这是 Wan 2.2 做不到的
# 用法：
#   .\文本生视频H3.ps1 -Prompt "海边灯塔，黄昏，海浪拍礁石" -Seconds 5
#   .\文本生视频H3.ps1 -Prompt "..." -Width 1344 -Height 768 -Seconds 5    # 全画布（约 5.5 分钟）
#   .\文本生视频H3.ps1 -Prompt "..." -Width 640 -Height 360                # 快速草稿（约 1 分钟）
param(
    [Parameter(Mandatory = $true)][string]$Prompt,
    [int]$Width = 960,
    [int]$Height = 540,
    [int]$Seconds = 5,
    [int]$Steps = 8,             # Turbo LoRA 建议 8；不用 LoRA 时 20
    [int]$Seed = 0,              # 0 = 随机
    [switch]$NoLora,
    [switch]$KeepServer,
    [switch]$NoInfo,
    [switch]$KeepChatBackend,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$aki = 'D:\ComfyUI-aki-v3.2'
$akiPy = Join-Path $aki 'python\python.exe'
$victimDir = 'C:\Users\wangzimu\Desktop\视频'
$comfyOutDir = 'C:\Users\wangzimu\Desktop\ComfyUI 输出'
$tools = Join-Path $PSScriptRoot '_video_tools.py'

function Write-HeadH3 { param([string]$t) Write-Host ''; Write-Host ("== " + $t + " ==") -ForegroundColor Cyan }
function Write-OkH3 { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Green }
function Write-InH3 { param([string]$t) Write-Host ("  " + $t) -ForegroundColor DarkGray }
function Test-ComfyH3 { param([int]$p) try { $null = Invoke-RestMethod ("http://127.0.0.1:{0}/system_stats" -f $p) -TimeoutSec 3; return $true } catch { return $false } }

# ---- 帧数对齐 17k+5（模型硬性要求）----
$length = 17 * [int][Math]::Round(($Seconds * 24 - 5) / 17.0) + 5
if ($length -lt 5) { $length = 5 }
if ($Seed -le 0) { $Seed = Get-Random -Minimum 1 -Maximum 2147483646 }

Write-HeadH3 'MiniMax H3 文生视频（带音频）'
Write-InH3 ("{0}×{1} / {2} 帧 @24fps ≈ {3:N1} 秒 / {4} 步 / seed {5}{6}" -f `
    $Width, $Height, $length, ($length / 24), $Steps, $Seed, $(if($NoLora){' / 无 LoRA'}else{' / Turbo LoRA'}))

# ---- 显存快照 / 释放（本脚本独占管理，秋叶启动脚本不再自己快照）----
. (Join-Path $PSScriptRoot '_vram.ps1')
$vramState = $null
trap { try { Restore-VramPrep $vramState } catch { }; exit 1 }
if (-not $KeepChatBackend) {
    Write-InH3 '检查本地模型占用（Strata / Ollama）…'
    $vramState = Start-VramPrep -NeedMiB 16000 -TimeoutSeconds 180
} else {
    Write-InH3 '跳过显存快照（-KeepChatBackend）'
}

# ---- 前置：显存够不够（H3 需要 ~21 GB，不够会慢但不出错）----
$freeNow = Get-FreeVramMiB
if (-not (Test-ComfyH3) -and $freeNow -lt 21000 -and -not $ForceSlow) {
    Write-Host ''
    Write-Host ("  ✗ 可用显存 $freeNow MB，低于 MiniMax H3 需要的 21000 MB") -ForegroundColor Red
    Write-Host '    继续跑不会报错，但驱动会回退到系统内存 —— 慢 5~10 倍' -ForegroundColor Yellow
    Write-Host '    处理：1) .\显存体检.ps1 -Kill   2) 关掉占显存的聊天客户端' -ForegroundColor Yellow
    Get-VramHolders -Top 5 | ForEach-Object { Write-Host ('      {0,-26} PID {1,-7} {2,6:N2} GB' -f $_.Name, $_.PID, $_.GB) -ForegroundColor DarkGray }
    Restore-VramPrep $vramState
    exit 2
}

# ---- 启动 ComfyUI ----
$startedHere = $false
if (-not (Test-ComfyH3 -p 8189)) {
    Write-InH3 '启动秋叶 ComfyUI（含显存快照）…'
    Start-Process 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $aki 'start-aki.ps1'),'-KeepChatBackend','-NoBrowser','-NoPause') -WindowStyle Hidden
    $startedHere = $true
    $ok = $false
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Seconds 3
        if (Test-ComfyH3 -p 8189) { $ok = $true; Write-OkH3 ("ComfyUI 就绪（" + ($i * 3 + 3) + " 秒）"); break }
    }
    if (-not $ok) { throw 'ComfyUI 启动超时' }
} else { Write-InH3 'ComfyUI 已在运行' }

# ---- 降级计划（显存不足自动降档）----
function Snap32 { param([int]$v) $x = [int]([math]::Round($v / 32.0) * 32); if ($x -lt 512) { $x = 512 }; if ($x -gt 1344) { $x = 1344 }; return $x }
$w1 = Snap32 ([int]($Width * 0.78)); $h1 = Snap32 ([int]($Height * 0.78))
$w2 = Snap32 ([int]($Width * 0.6));  $h2 = Snap32 ([int]($Height * 0.6))
$sizePlan = @(
    [pscustomobject]@{ Tag = '原配置'; W = $Width; H = $Height }
)
if ($w1 -lt $Width -or $h1 -lt $Height) { $sizePlan += [pscustomobject]@{ Tag = ("降档 {0}×{1}" -f $w1, $h1); W = $w1; H = $h1 } }
if ($w2 -lt $w1 -or $h2 -lt $h1)       { $sizePlan += [pscustomobject]@{ Tag = ("降档 {0}×{1}" -f $w2, $h2); W = $w2; H = $h2 } }
$okDone = $false; $usedTag = ''; $firstErr = ''
foreach ($sz in $sizePlan) {
    $Width = $sz.W; $Height = $sz.H
    $length = 17 * [int][Math]::Round(($Seconds * 24 - 5) / 17.0) + 5
    if ($length -lt 5) { $length = 5 }
    Write-InH3 ("尝试：" + $sz.Tag + (" {0}×{1} / {2} 帧" -f $Width, $Height, $length))

# ---- 组图 ----
# 注意：视频 VAE 必须用 fp16 版；int8_convrot 版实测解出全黑画面
$vid   = 'minimax_h3_fl2va_pruned_int8_convrot.safetensors'
$te    = 'qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors'
$vvae  = 'minimax_h3_video_vae_fp16.safetensors'
$avae  = 'minimax_h3_audio_vae_fp32.safetensors'
$lora  = 'minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors'

$graph = @{
    '1'  = @{ class_type = 'UNETLoader'; inputs = @{ unet_name = $vid; weight_dtype = 'default' } }
    '3'  = @{ class_type = 'CLIPLoader'; inputs = @{ clip_name = $te; type = 'minimax'; device = 'default' } }
    '4'  = @{ class_type = 'VAELoader'; inputs = @{ vae_name = $vvae } }
    '5'  = @{ class_type = 'VAELoader'; inputs = @{ vae_name = $avae } }
    '6'  = @{ class_type = 'MiniMaxH3ImageToVideo'; inputs = @{
                clip = @('3', 0); vae = @('4', 0); prompt = $Prompt
                width = $Width; height = $Height; length = $length } }
    '8'  = @{ class_type = 'BasicScheduler'; inputs = @{ model = @('2', 0); scheduler = 'simple'; steps = $Steps; denoise = 1.0 } }
    '9'  = @{ class_type = 'KSamplerSelect'; inputs = @{ sampler_name = 'res_multistep' } }
    '10' = @{ class_type = 'RandomNoise'; inputs = @{ noise_seed = $Seed } }
    '11' = @{ class_type = 'SamplerCustomAdvanced'; inputs = @{
                noise = @('10', 0); guider = @('7', 0); sampler = @('9', 0)
                sigmas = @('8', 0); latent_image = @('6', 1) } }
    '12' = @{ class_type = 'VAEDecode'; inputs = @{ samples = @('11', 0); vae = @('4', 0) } }
    '13' = @{ class_type = 'VAEDecodeAudio'; inputs = @{ samples = @('11', 0); vae = @('5', 0) } }
    '14' = @{ class_type = 'CreateVideo'; inputs = @{ images = @('12', 0); audio = @('13', 0); fps = 24 } }
    '15' = @{ class_type = 'SaveVideo'; inputs = @{
                video = @('14', 0); filename_prefix = 'h3-out'; format = 'mp4'; codec = 'h264' } }
}
if ($NoLora) {
    $graph['2'] = @{ class_type = 'UNETLoader'; inputs = @{ unet_name = $vid; weight_dtype = 'default' } }
    $graph['7'] = @{ class_type = 'BasicGuider'; inputs = @{ model = @('1', 0); conditioning = @('6', 0) } }
    $graph['8'].inputs.model = @('1', 0)
} else {
    $graph['2'] = @{ class_type = 'LoraLoaderModelOnly'; inputs = @{ model = @('1', 0); lora_name = $lora; strength_model = 1.0 } }
    $graph['7'] = @{ class_type = 'BasicGuider'; inputs = @{ model = @('2', 0); conditioning = @('6', 0) } }
}

# ---- 提交 + 轮询 ----
$body = @{ prompt = $graph } | ConvertTo-Json -Depth 12 -Compress
$sw = [Diagnostics.Stopwatch]::StartNew()
$id = $null
$submitErr = ''
try {
    $resp = Invoke-RestMethod 'http://127.0.0.1:8189/prompt' -Method POST -ContentType 'application/json' `
        -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60
    $id = $resp.prompt_id
    Write-InH3 ('任务已提交 prompt_id=' + $id)
} catch {
    $submitErr = ''
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $submitErr = $_.ErrorDetails.Message }
    if (-not $submitErr) { $submitErr = $_.Exception.Message }
    $sw.Stop()
}

$peak = 0; $last = 0; $done = $true; $err = $submitErr
if ($id) { $done = $false }
while (-not $done) {
    Start-Sleep -Seconds 3
    $u = ((& nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null) -split "`n")[0]
    $used = 0
    if ([int]::TryParse($u.Trim(), [ref]$used)) { if ($used -gt $peak) { $peak = $used } }
    $el = [int]$sw.Elapsed.TotalSeconds
    if ($el - $last -ge 20) { Write-InH3 ("  {0} 秒… 显存 {1} MB" -f $el, $used); $last = $el }
    try { $h = Invoke-RestMethod ("http://127.0.0.1:8189/history/" + $id) -TimeoutSec 15 } catch { continue }
    if (-not $h.$id) { continue }
    if ($h.$id.status.status_str -eq 'error') {
        $err = ($h.$id.status.messages | Where-Object { $_[0] -eq 'execution_error' } | ForEach-Object { $_[1].exception_message }) -join ' | '
        $done = $true
    } elseif ($h.$id.outputs) { $done = $true }
    if ($sw.Elapsed.TotalSeconds -gt 3600) { $err = 'timeout'; $done = $true }
}
$sw.Stop()

    if ($err) {
        Write-Host ('  ⚠ ' + $sz.Tag + ' 失败：' + (($err -split "`n")[0])) -ForegroundColor Yellow
        if (-not $firstErr) { $firstErr = $err }
        continue
    }
    $okDone = $true; $usedTag = $sz.Tag
    break
}

if (-not $okDone) {
    Write-Host ''
    Write-Host ('  ✗ 全部尺寸均失败：' + $firstErr) -ForegroundColor Red
    if (-not $KeepServer -and $startedHere) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $aki 'stop-aki.ps1') -NoRestore 2>&1 | Out-Null
    }
    Restore-VramPrep $vramState
    exit 1
}
if ($usedTag -ne '原配置') { Write-InH3 ('已自动降级：' + $usedTag) }

Write-OkH3 ("生成完成，用时 {0:N1} 秒（{1:N1} 分钟），显存峰值 {2:N1} GB" -f $sw.Elapsed.TotalSeconds, ($sw.Elapsed.TotalSeconds / 60), ($peak / 1024))

# ---- 归位 ----
$produced = Get-ChildItem $comfyOutDir -Filter 'h3-out*.mp4' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $produced) {
    $produced = Get-ChildItem (Join-Path $aki 'ComfyUI\output') -Filter 'h3-out*.mp4' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if (-not $produced) { Write-Host '  ✗ 没找到输出 mp4' -ForegroundColor Red; exit 1 }

$organize = Join-Path $PSScriptRoot '整理视频.ps1'
if (Test-Path $organize) { & powershell -NoProfile -ExecutionPolicy Bypass -File $organize 2>&1 | Out-Null }
$final = Get-ChildItem $victimDir -Filter '*.mp4' | Sort-Object Name -Descending | Select-Object -First 1
if (-not $final) { $final = $produced }

Write-OkH3 ('成品：' + $final.FullName)
if (-not $NoInfo) {
    $infScript = Join-Path $PSScriptRoot '_info.ps1'
    if (Test-Path $infScript) {
        . $infScript
        Show-MediaInfo -Path $final.FullName -Extra @{
            '模型' = 'MiniMax H3 (FL2VA int8 + Turbo 8step)'
            '档位' = ("{0}×{1} / {2} 帧 / {3} 步" -f $Width, $Height, $length, $Steps)
        }
    }
}

if (-not $KeepServer -and $startedHere) {
    Write-InH3 '关闭本次启动的 ComfyUI（恢复之前停掉的本地模型）…'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $aki 'stop-aki.ps1') -NoRestore 2>&1 | Select-Object -Last 2 | ForEach-Object { Write-InH3 $_ }
}
Restore-VramPrep $vramState
exit 0
