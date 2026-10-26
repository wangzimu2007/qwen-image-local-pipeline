# AI 超分（FlashVSR+ 官方环境，高分辨率档）
# 用法：
#   .\AI超分FlashVSR.ps1 -Video x.mp4                      # 默认 832×480 ×2 → 1664×896
#   .\AI超分FlashVSR.ps1 -Video x.mp4 -Scale 4             # → 3328×1920（很慢，可能 OOM）
#   .\AI超分FlashVSR.ps1 -Video x.mp4 -Width 512 -Height 288 -Scale 2   # 低档更快
# 说明：走 ComfyUI（秋叶版 8189）+ FlashVSR+ turbo 权重 + triton_block_sparse 稀疏注意力
param(
    [Parameter(Mandatory = $true)][string]$Video,
    [int]$Width = 832,          # 处理分辨率（短边由它决定；显存由它主导）
    [int]$Height = 480,
    [int]$Scale = 2,            # 放大倍数（1~4）
    [string]$PlusTemporal = '4',# 每 latent 帧输入帧数；大运动建议 2 或 1（更慢）
    [int]$Port = 8189,
    [switch]$KeepServer,
    [switch]$NoInfo,
    [switch]$NoPause,
    [switch]$KeepChatBackend
)

$ErrorActionPreference = 'Stop'
$aki = 'D:\ComfyUI-aki-v3.2'
$victimDir = 'C:\Users\wangzimu\Desktop\视频'
$akiPy = Join-Path $aki 'python\python.exe'
$tools = Join-Path $PSScriptRoot '_video_tools.py'

function Write-Head2 { param([string]$t) Write-Host ''; Write-Host ("== " + $t + " ==") -ForegroundColor Cyan }
function Write-Ok2 { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Green }
function Write-In4 { param([string]$t) Write-Host ("  " + $t) -ForegroundColor DarkGray }

function Test-Comfy {
    param([int]$p)
    try { $null = Invoke-RestMethod ("http://127.0.0.1:{0}/system_stats" -f $p) -TimeoutSec 3; return $true } catch { return $false }
}

# ---------- 0. 解析输入 ----------
$path = $Video
if (-not (Test-Path $path)) {
    $cand = Join-Path $victimDir $Video
    if (Test-Path $cand) { $path = $cand } else { throw "找不到视频：$Video" }
}
$path = (Resolve-Path $path).Path
Write-Head2 'FlashVSR+ 超分'
$info0 = & $akiPy $tools info $path 2>&1
Write-In4 ($info0 -join ' ')
Write-In4 ("处理 {0}×{1} ×{2}" -f $Width, $Height, $Scale)

# ---- 显存快照 / 释放（本脚本独占管理，秋叶脚本不再自己快照）----
. (Join-Path $PSScriptRoot '_vram.ps1')
$vramState = $null
trap { try { Restore-VramPrep $vramState } catch { }; exit 1 }
if (-not $KeepChatBackend) {
    $vramState = Start-VramPrep -NeedMiB 16000 -TimeoutSeconds 180
}

# ---------- 1. 启动 ComfyUI ----------
$startedHere = $false
if (-not (Test-Comfy -p $Port)) {
    $starter = Join-Path $aki 'start-aki.ps1'
    if (-not (Test-Path $starter)) { throw "找不到 $starter" }
    Write-In4 '启动秋叶 ComfyUI（含显存快照）…'
    Start-Process 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$starter,'-KeepChatBackend','-NoBrowser','-NoPause') -WindowStyle Hidden
    $startedHere = $true
    $ok = $false
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Seconds 3
        if (Test-Comfy -p $Port) { $ok = $true; Write-Ok2 ("ComfyUI 就绪（" + ($i * 3 + 3) + " 秒）"); break }
    }
    if (-not $ok) { throw 'ComfyUI 启动超时' }
} else {
    Write-In4 'ComfyUI 已在运行'
}

# ---------- 2. 准备输入 ----------
$inDir = Join-Path $aki 'ComfyUI\input'
if (-not (Test-Path $inDir)) { throw "ComfyUI input 目录不存在：$inDir" }
$inName = 'fv-up-' + (Get-Date -Format 'HHmmss') + '.mp4'
Copy-Item $path (Join-Path $inDir $inName) -Force

# ---------- 3. 组图并提交 ----------
$graph = @{
    '1' = @{ class_type = 'LoadVideo'; inputs = @{ file = $inName } }
    '2' = @{ class_type = 'GetVideoComponents'; inputs = @{ video = @('1', 0) } }
    '3' = @{ class_type = 'FlashVSR_SM_Model'; inputs = @{
                dit = 'turbo_dit_plus.safetensors'
                proj_pt = 'lq_proj_in_plus_turbo.safetensors'
                emb_pt = 'posi_prompt_plus.pth'
                version = 'plus_turbo'
                tiny_long = $false
                offload = $true
                plus_temporal = $PlusTemporal
                plus_attn = 'triton_block_sparse' } }
    '4' = @{ class_type = 'FlashVSR_SM_Vae'; inputs = @{
                vae = 'none'; tcd_encoder = 'TCDecoder_plus.ckpt'; lite_vae = 'none' } }
    '5' = @{ class_type = 'FlashVSR_SM_KSampler'; inputs = @{
                model = @('3', 0); image = @('2', 0)
                width = $Width; height = $Height; seed = 42; scale = $Scale
                kv_ratio = 3.5; local_range = 9; steps = 1; cfg = 1.0; sparse_ratio = 2.0 } }
    '6' = @{ class_type = 'FlashVSR_SM_Decoder'; inputs = @{
                vae = @('4', 0); latent = @('5', 0)
                full_tiled = $true; color_fix = $true; fix_method = 'wavelet' } }
    '7' = @{ class_type = 'CreateVideo'; inputs = @{ images = @('6', 0); audio = @('2', 1); fps = @('2', 2) } }
    '8' = @{ class_type = 'SaveVideo'; inputs = @{
                video = @('7', 0); filename_prefix = 'flashvsr-up'
                format = 'mp4'; codec = 'h264' } }
}
$body = @{ prompt = $graph } | ConvertTo-Json -Depth 12 -Compress
$sw = [Diagnostics.Stopwatch]::StartNew()
$resp = Invoke-RestMethod ("http://127.0.0.1:{0}/prompt" -f $Port) -Method POST -ContentType 'application/json' `
    -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60
$id = $resp.prompt_id
Write-In4 ('任务已提交 prompt_id=' + $id)

$peak = 0; $last = 0; $done = $false; $err = ''
while (-not $done) {
    Start-Sleep -Seconds 2
    $u = ((& nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null) -split "`n")[0]
    $used = 0
    if ([int]::TryParse($u.Trim(), [ref]$used)) { if ($used -gt $peak) { $peak = $used } }
    $el = [int]$sw.Elapsed.TotalSeconds
    if ($el - $last -ge 20) { Write-In4 ("  {0} 秒… 显存 {1} MB" -f $el, $used); $last = $el }
    try { $h = Invoke-RestMethod ("http://127.0.0.1:{0}/history/{1}" -f $Port, $id) -TimeoutSec 15 } catch { continue }
    if (-not $h.$id) { continue }
    if ($h.$id.status.status_str -eq 'error') {
        $err = ($h.$id.status.messages | Where-Object { $_[0] -eq 'execution_error' } | ForEach-Object { $_[1].exception_message }) -join ' | '
        $done = $true
    } elseif ($h.$id.outputs) { $done = $true }
    if ($sw.Elapsed.TotalSeconds -gt 3600) { $err = 'timeout'; $done = $true }
}
$sw.Stop()

if ($err) {
    Write-Host ''
    Write-Host ('  ✗ 失败：' + ($err -split "`n")[0]) -ForegroundColor Red
    if (-not $KeepServer -and $startedHere) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $aki 'stop-aki.ps1') -NoRestore 2>&1 | Out-Null
    }
    exit 1
}

Write-Ok2 ("超分完成，用时 {0:N1} 秒（{1:N1} 分钟），显存峰值 {2:N1} GB" -f $sw.Elapsed.TotalSeconds, ($sw.Elapsed.TotalSeconds / 60), ($peak / 1024))

# ---------- 4. 找产物并归位 ----------
$outDirs = @(
    'C:\Users\wangzimu\Desktop\ComfyUI 输出',
    (Join-Path $aki 'ComfyUI\output')
)
$produced = $null
foreach ($d in $outDirs) {
    if (-not (Test-Path $d)) { continue }
    $c = Get-ChildItem $d -Filter 'flashvsr-up*.mp4' -Recurse -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($c) { $produced = $c; break }
}
if (-not $produced) { Write-Host '  ✗ 没找到输出 mp4' -ForegroundColor Red; exit 1 }

# 归位到「视频」目录并编号
$organize = Join-Path $PSScriptRoot '整理视频.ps1'
$final = $null
if (Test-Path $organize) {
    $before = @(Get-ChildItem $victimDir -Filter '*.mp4' -ErrorAction SilentlyContinue).Count
    & powershell -NoProfile -ExecutionPolicy Bypass -File $organize 2>&1 | Out-Null
    $latest = Get-ChildItem $victimDir -Filter '*.mp4' | Sort-Object Name -Descending | Select-Object -First 1
    if ($latest) { $final = $latest.FullName }
}
if (-not $final) { $final = $produced.FullName }

Write-Ok2 ('成品：' + $final)
if (-not $NoInfo) {
    $infScript = Join-Path $PSScriptRoot '_info.ps1'
    if (Test-Path $infScript) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $infScript -Path $final 2>&1 | Out-Null
        . $infScript
        Show-MediaInfo -Path $final -Extra @{ '模型' = 'FlashVSR+ turbo（triton sparse）'; '档位' = ("{0}×{1} ×{2}" -f $Width, $Height, $Scale) }
    }
}

# ---------- 5. 收尾 ----------
if (-not $KeepServer -and $startedHere) {
    Write-In4 '关闭本次启动的 ComfyUI（恢复之前停掉的本地模型）…'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $aki 'stop-aki.ps1') -NoRestore 2>&1 | Select-Object -Last 2 | ForEach-Object { Write-In4 $_ }
}
Restore-VramPrep $vramState
exit 0