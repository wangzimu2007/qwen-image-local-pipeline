# 图生视频：拿一张图当第一帧，用 Wan 2.2 5B 生成动态视频
#
# 行为：
#   1. 自动启动秋叶版 ComfyUI（8189）——若未运行
#   2. 把输入图复制到 ComfyUI 的 input 目录
#   3. 按原图宽高比自动算分辨率（对齐 32，限制在约 0.55 MP）
#   4. 提交「首帧 → 视频」工作流，轮询直到完成
#   5. 调用 整理视频.ps1 把成品搬进桌面「视频」并编号
#   6. 用 PyAV 抽 3 帧预览
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File D:\qwen-image-2.1\图生视频.ps1 -Image "某张图.png"
#   ... -Prompt "镜头缓慢推进，海风拂过"  -Seconds 5 -Fps 24 -Steps 20
#   ... -KeepServer      生成完不关闭 ComfyUI
#   ... -NoPause         不等待按键
param(
    [Parameter(Mandatory = $true)]
    [string]$Image,
    [string]$Prompt = '镜头缓慢推进，画面自然地动起来，光影流动，电影感',
    [double]$Seconds = 5,
    [int]$Fps = 24,
    [int]$Steps = 20,
    [int]$Seed = 42,
    [switch]$KeepServer,
    [switch]$NoPause,
    [switch]$KeepChatBackend
)

$ErrorActionPreference = 'Stop'
$root      = 'D:\qwen-image-2.1'
$akiRoot   = 'D:\ComfyUI-aki-v3.2'
$akiPy     = Join-Path $akiRoot 'python\python.exe'
$akiPort   = 8189
$desk      = [Environment]::GetFolderPath('Desktop')
$videoDir  = Join-Path $desk '视频'
$outDir    = Join-Path $desk 'ComfyUI 输出'
$inDir     = Join-Path $akiRoot 'ComfyUI\input'
$organize  = Join-Path $root '整理视频.ps1'

function Pause-Brief {
    param([int]$S = 8)
    if ($NoPause) { return }
    Write-Host ''
    Write-Host "窗口将在 $S 秒后自动关闭..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $S
}


# ---------- 1. 校验输入图 ----------
if (-not (Test-Path $Image)) { Write-Warning "找不到图片：$Image"; Pause-Brief 10; exit 1 }
$Image = (Resolve-Path $Image).Path
Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Image]::FromFile($Image)
$srcW = $img.Width; $srcH = $img.Height
$img.Dispose()

# ---------- 2. 计算分辨率（对齐 32，总量控制在约 0.55 MP） ----------
$maxPixels = 0.55 * 1000000
$scale = [math]::Sqrt($maxPixels / ($srcW * $srcH))
if ($scale -gt 1) { $scale = 1 }
$w = [int]([math]::Round($srcW * $scale / 32.0) * 32)
$h = [int]([math]::Round($srcH * $scale / 32.0) * 32)
if ($w -lt 256) { $w = 256 }
if ($h -lt 256) { $h = 256 }
if ($w -gt 1280) { $w = 1280 }
if ($h -gt 1280) { $h = 1280 }

# 帧数必须是 4n+1
$frames = [int]([math]::Round($Seconds * $Fps))
$n = [int][math]::Round(($frames - 1) / 4.0)
$frames = 4 * $n + 1
if ($frames -lt 5) { $frames = 5 }

Write-Host ("输入：{0}（{1}x{2}）" -f (Split-Path $Image -Leaf), $srcW, $srcH) -ForegroundColor Cyan
Write-Host ("输出：{0}x{1}，{2} 帧 @ {3}fps ≈ {4:N2} 秒，{5} 步" -f $w, $h, $frames, $Fps, ($frames/$Fps), $Steps) -ForegroundColor Cyan

# ---- 显存快照 / 释放（本脚本独占管理，秋叶脚本不再自己快照）----
. (Join-Path $PSScriptRoot '_vram.ps1')
. (Join-Path $PSScriptRoot '_comfy.ps1')
$vramState = $null
trap { try { Restore-VramPrep $vramState } catch { }; exit 1 }
if (-not $KeepChatBackend) {
    $vramState = Start-VramPrep -NeedMiB 16000 -TimeoutSeconds 180
}

# ---------- 3. 确保 ComfyUI 在跑 ----------
$startedHere = Start-ComfyIfNeeded -AkiRoot $akiRoot -Port $akiPort -Filter '就绪|启动'

# ---------- 4. 复制图到 input 目录 ----------
New-Item -ItemType Directory -Force -Path $inDir | Out-Null
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$inName  = "i2v-$stamp.png"
Copy-Item -LiteralPath $Image -Destination (Join-Path $inDir $inName) -Force
Write-Host ("已放入 ComfyUI input：{0}" -f $inName) -ForegroundColor DarkGray

# ---------- 5. 提交工作流 ----------
$body = @{
    '1'  = @{ class_type='UNETLoader'; inputs=@{ unet_name='wan2.2_ti2v_5B_fp16.safetensors'; weight_dtype='default' } }
    '2'  = @{ class_type='ModelSamplingSD3'; inputs=@{ model=@('1',0); shift=8.0 } }
    '3'  = @{ class_type='CLIPLoader'; inputs=@{ clip_name='umt5_xxl_fp8_e4m3fn_scaled.safetensors'; type='wan' } }
    '4'  = @{ class_type='CLIPTextEncode'; inputs=@{ clip=@('3',0); text=$Prompt } }
    '5'  = @{ class_type='CLIPTextEncode'; inputs=@{ clip=@('3',0); text='模糊，低质量，变形，闪烁，画面抖动，静止' } }
    '6'  = @{ class_type='VAELoader'; inputs=@{ vae_name='wan2.2_vae.safetensors' } }
    '12' = @{ class_type='LoadImage'; inputs=@{ image=$inName } }
    '7'  = @{ class_type='Wan22ImageToVideoLatent'; inputs=@{ vae=@('6',0); width=$w; height=$h; length=$frames; batch_size=1; start_image=@('12',0) } }
    '8'  = @{ class_type='KSampler'; inputs=@{ model=@('2',0); seed=$Seed; steps=$Steps; cfg=5.0; sampler_name='euler'; scheduler='simple'; positive=@('4',0); negative=@('5',0); latent_image=@('7',0); denoise=1.0 } }
    '9'  = @{ class_type='VAEDecode'; inputs=@{ samples=@('8',0); vae=@('6',0) } }
    '10' = @{ class_type='CreateVideo'; inputs=@{ images=@('9',0); fps=[double]$Fps } }
    '11' = @{ class_type='SaveVideo'; inputs=@{ video=@('10',0); filename_prefix='wan-i2v'; format='mp4'; codec='h264' } }
}
$json = @{ prompt = $body } | ConvertTo-Json -Depth 12 -Compress
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    $r = Invoke-RestMethod "http://127.0.0.1:$akiPort/prompt" -Method POST -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 60
} catch {
    Write-Warning ("提交失败：" + $_.Exception.Message)
    if ($_.ErrorDetails) { Write-Host $_.ErrorDetails.Message }
    Pause-Brief 12; exit 1
}
$id = $r.prompt_id
Write-Host '已提交，生成中...' -ForegroundColor Yellow

$status = 'timeout'
for ($i = 0; $i -lt 400; $i++) {
    Start-Sleep -Seconds 5
    try { $h = Invoke-RestMethod "http://127.0.0.1:$akiPort/history/$id" -TimeoutSec 15 } catch { continue }
    if (-not $h.$id) { continue }
    if ($h.$id.status.status_str -eq 'error') {
        $h.$id.status.messages | Where-Object { $_[0] -eq 'execution_error' } |
            ForEach-Object { Write-Warning ("生成出错 [{0}]：{1}" -f $_[1].node_type, $_[1].exception_message) }
        $status = 'error'; break
    }
    if ($h.$id.outputs.'11') { $status = 'ok'; break }
}
$sw.Stop()

# ---------- 6. 整理 + 抽帧 ----------
$videoFile = $null
if ($status -eq 'ok') {
    Write-Host ("生成完成，用时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    & powershell -NoProfile -ExecutionPolicy Bypass -File $organize 2>&1 |
        Where-Object { $_ -match '归位|video-' } | ForEach-Object { '  ' + $_ }
    $videoFile = Get-ChildItem $videoDir -Filter '*.mp4' -ErrorAction SilentlyContinue |
                 Sort-Object Name -Descending | Select-Object -First 1

    if ($videoFile -and (Test-Path $akiPy)) {
        $frameDir = Join-Path $videoDir '_预览帧'
        New-Item -ItemType Directory -Force -Path $frameDir | Out-Null
        $py = Join-Path $env:TEMP 'i2v_frames.py'
        $code = @'
import sys, os, av
path, outdir = sys.argv[1], sys.argv[2]
c = av.open(path); s = c.streams.video[0]
frames = [f.to_image() for f in c.decode(s)]
n = len(frames)
base = os.path.splitext(os.path.basename(path))[0]
for tag, idx in (("start", int(n*0.05)), ("middle", int(n*0.5)), ("end", int(n*0.92))):
    frames[min(idx, n-1)].save(os.path.join(outdir, f"{base}-{tag}.png"))
print("frames done", n)
'@
        [System.IO.File]::WriteAllText($py, $code, (New-Object System.Text.UTF8Encoding($false)))
        & $akiPy $py $videoFile.FullName $frameDir 2>&1 | Where-Object { $_ -match 'frames done' } | ForEach-Object { '  ' + $_ }
        Get-ChildItem $frameDir -Filter ($videoFile.BaseName + '-*.png') | ForEach-Object { '  预览帧: ' + $_.FullName }
    }

    Write-Host ''
    Write-Host ("视频：{0}" -f $videoFile.FullName) -ForegroundColor Green
} else {
    Write-Warning '视频生成未完成。'
}

# ---------- 7. 收尾 ----------
  Stop-ComfyIfStarted -AkiRoot $akiRoot -StartedHere $startedHere -KeepServer:$KeepServer
Restore-VramPrep $vramState
Pause-Brief
if ($status -eq 'ok') { exit 0 }
exit 1
