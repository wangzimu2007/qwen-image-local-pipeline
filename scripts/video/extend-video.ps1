# 续接视频：把已有视频的最后一段画面当作首帧，继续往下生成，并把所有片段拼成一个文件
#
# 适合显存不够时做长视频：每次只生成一小段（如 5 秒），拼起来就是长片。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File D:\qwen-image-2.1\续接视频.ps1 -Video "桌面\视频\video-0002-wan-xxx.mp4"
#   ... -Prompt "镜头继续向前推进，海浪持续拍打礁石" -Segments 2 -Seconds 5 -NoPause
#
# 输出：原视频 + 新片段拼接后的成品，归位到桌面「视频」并编号（中间片段也会各自编号保留）
param(
    [Parameter(Mandatory = $true)]
    [string]$Video,
    [string]$Prompt = '镜头继续推进，动作与画面自然延续',
    [int]$Segments = 1,
    [double]$Seconds = 5,
    [int]$Fps = 24,
    [int]$Steps = 20,
    [switch]$KeepServer,
    [switch]$NoPause,
    [switch]$DeleteSegments,
    [switch]$KeepChatBackend
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_vram.ps1')
. (Join-Path $PSScriptRoot '_comfy.ps1')
$vramState = $null
$root     = 'D:\qwen-image-2.1'
$akiRoot  = 'D:\ComfyUI-aki-v3.2'
$akiPy    = Join-Path $akiRoot 'python\python.exe'
$akiPort  = 8189
$desk     = [Environment]::GetFolderPath('Desktop')
$videoDir = Join-Path $desk '视频'
$outDir   = Join-Path $desk 'ComfyUI 输出'
$inDir    = Join-Path $akiRoot 'ComfyUI\input'
$tools    = Join-Path $root '_video_tools.py'
$organize = Join-Path $root '整理视频.ps1'

function Pause-Brief { param([int]$S = 8) if ($NoPause) { return }; Write-Host ''; Write-Host "窗口将在 $S 秒后自动关闭..." -ForegroundColor DarkGray; Start-Sleep -Seconds $S }

# 启动服务（整个流程复用）
$startedHere = Start-ComfyIfNeeded -AkiRoot $akiRoot -Port $akiPort -Filter '就绪'

$parts = @($Video.Trim())
$current = $Video
$swAll = [Diagnostics.Stopwatch]::StartNew()

for ($seg = 1; $seg -le $Segments; $seg++) {
    Write-Host ''
    Write-Host ("=== 第 {0}/{1} 段 ===" -f $seg, $Segments) -ForegroundColor Yellow
    # 1) 取当前片段的最后一帧
    New-Item -ItemType Directory -Force -Path $inDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $framePng = Join-Path $inDir ("cont-$stamp.png")
    & $akiPy $tools lastframe $current $framePng 2>&1 | ForEach-Object { '  ' + $_ }
    if (-not (Test-Path $framePng)) { Write-Warning '取末帧失败，终止。'; break }

    # 2) 提交图生视频
    $body = @{
        '1'  = @{ class_type='UNETLoader'; inputs=@{ unet_name='wan2.2_ti2v_5B_fp16.safetensors'; weight_dtype='default' } }
        '2'  = @{ class_type='ModelSamplingSD3'; inputs=@{ model=@('1',0); shift=8.0 } }
        '3'  = @{ class_type='CLIPLoader'; inputs=@{ clip_name='umt5_xxl_fp8_e4m3fn_scaled.safetensors'; type='wan' } }
        '4'  = @{ class_type='CLIPTextEncode'; inputs=@{ clip=@('3',0); text=$Prompt } }
        '5'  = @{ class_type='CLIPTextEncode'; inputs=@{ clip=@('3',0); text='模糊，低质量，变形，闪烁，画面抖动' } }
        '6'  = @{ class_type='VAELoader'; inputs=@{ vae_name='wan2.2_vae.safetensors' } }
        '12' = @{ class_type='LoadImage'; inputs=@{ image=(Split-Path $framePng -Leaf) } }
        '7'  = @{ class_type='Wan22ImageToVideoLatent'; inputs=@{ vae=@('6',0); width=$w; height=$h; length=$frames; batch_size=1; start_image=@('12',0) } }
        '8'  = @{ class_type='KSampler'; inputs=@{ model=@('2',0); seed=(1000 + $seg); steps=$Steps; cfg=5.0; sampler_name='euler'; scheduler='simple'; positive=@('4',0); negative=@('5',0); latent_image=@('7',0); denoise=1.0 } }
        '9'  = @{ class_type='VAEDecode'; inputs=@{ samples=@('8',0); vae=@('6',0) } }
        '10' = @{ class_type='CreateVideo'; inputs=@{ images=@('9',0); fps=[double]$Fps } }
        '11' = @{ class_type='SaveVideo'; inputs=@{ video=@('10',0); filename_prefix='wan-i2v'; format='mp4'; codec='h264' } }
    }
    $json = @{ prompt = $body } | ConvertTo-Json -Depth 12 -Compress
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod "http://127.0.0.1:$akiPort/prompt" -Method POST -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 60
    $id = $r.prompt_id
    $done = $false
    for ($i = 0; $i -lt 400; $i++) {
        Start-Sleep -Seconds 5
        try { $h = Invoke-RestMethod "http://127.0.0.1:$akiPort/history/$id" -TimeoutSec 15 } catch { continue }
        if (-not $h.$id) { continue }
        if ($h.$id.status.status_str -eq 'error') {
            $h.$id.status.messages | Where-Object { $_[0] -eq 'execution_error' } | ForEach-Object { Write-Warning ("生成出错：{0}" -f $_[1].exception_message) }
            break
        }
        if ($h.$id.outputs.'11') { $done = $true; break }
    }
    $sw.Stop()
    if (-not $done) { Write-Warning '本段生成失败，终止。'; break }

    # 3) 找到新片段
    $newFile = Get-ChildItem $outDir -Filter '*.mp4' -File -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newFile) { Write-Warning '找不到生成的片段。'; break }
    Write-Host ("  本段完成，{0:N1} 秒：{1}" -f $sw.Elapsed.TotalSeconds, $newFile.Name) -ForegroundColor Green

    # 4) 拼接到现有片段
    $parts += $newFile.FullName
    $tmpOut = Join-Path $outDir ("wan-continue-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".mp4")
    & $akiPy $tools concat $tmpOut $parts 2>&1 | ForEach-Object { '  ' + $_ }
    if (Test-Path $tmpOut) {
        $current = $tmpOut
        Write-Host ("  已拼接，当前总长度见 {0}" -f (Split-Path $tmpOut -Leaf)) -ForegroundColor DarkGray
    } else { Write-Warning '拼接失败。'; break }
}

$swAll.Stop()
Write-Host ''
Write-Host ("总耗时 {0:N1} 秒" -f $swAll.Elapsed.TotalSeconds)

# 归位编号（把 ComfyUI 输出里的片段和拼接成品都搬进「视频」并编号）
if (Test-Path $organize) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $organize 2>&1 | Where-Object { $_ -match '归位|video-' } | ForEach-Object { '  ' + $_ }
}
$final = Get-ChildItem $videoDir -Filter '*.mp4' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if ($final) { Write-Host ("成品（最新编号）：{0}" -f $final.FullName) -ForegroundColor Green }
  Stop-ComfyIfStarted -AkiRoot $akiRoot -StartedHere $startedHere -KeepServer:$KeepServer
Pause-Brief
if ($vramState) { Restore-VramPrep $vramState }
exit 0