# 视频后期处理（一键）：Lanczos 放大 + FILM 插帧 + 归位编号
#
# 放大说明：
#   -Scale 2      Lanczos 快速放大（纯本地、秒级，无需 AI 模型）
#   AI 超分（SeedVR2）请在 ComfyUI 界面里跑「视频超分-SeedVR2-nvfp4」工作流
#   （实测 API 跑 121 帧 2 倍超过 16 分钟没跑完，不适合一键流程）
#
# 插帧说明：FILM（ComfyUI 后端节点，可 API 调用）：-Interp 2 表示帧率 ×2
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File D:\qwen-image-2.1\后期处理.ps1 -Video "某视频.mp4" -Scale 1.5 -Interp 2 -NoPause
param(
    [Parameter(Mandatory = $true)]
    [string]$Video,
    [double]$Scale = 1.0,
    [int]$Interp = 1,
    [switch]$KeepServer,
    [switch]$NoPause,
    [switch]$KeepChatBackend
)

$ErrorActionPreference = 'Stop'
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
$tmpDir   = Join-Path $env:TEMP 'dsh-video-post'

function Pause-Brief { param([int]$S = 8) if ($NoPause) { return }; Write-Host ''; Write-Host "窗口将在 $S 秒后自动关闭..." -ForegroundColor DarkGray; Start-Sleep -Seconds $S }
function Test-Up { param([string]$Url) try { $null = Invoke-RestMethod $Url -TimeoutSec 3; return $true } catch { return $false } }

if (-not (Test-Path $Video)) { Write-Warning "找不到视频：$Video"; Pause-Brief 10; exit 1 }
$Video = (Resolve-Path $Video).Path
if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }

$current = $Video
Write-Host ("输入：{0}" -f (Split-Path $Video -Leaf)) -ForegroundColor Cyan
& $akiPy $tools info $current 2>&1 | ForEach-Object { '  ' + $_ }

# ---------- 1. Lanczos 放大 ----------
if ($Scale -gt 1.001 -or $Scale -lt 0.999) {
    $scaled = Join-Path $tmpDir ("scaled-" + (Get-Date -Format 'HHmmss') + ".mp4")
    Write-Host ("放大 x{0}（Lanczos）..." -f $Scale) -ForegroundColor Yellow
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $akiPy $tools scale $current $scaled $Scale 2>&1 | ForEach-Object { '  ' + $_ }
    $sw.Stop()
    if (Test-Path $scaled) {
        $current = $scaled
        Write-Host ("  完成，用时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    } else { Write-Warning '放大失败，跳过。' }
}

# ---------- 2. FILM 插帧（ComfyUI API） ----------
if ($Interp -ge 2) {
    $startedHere = $false
    if (-not (Test-Up "http://127.0.0.1:$akiPort/system_stats")) {
        Write-Host '启动秋叶版 ComfyUI...' -ForegroundColor Yellow
# ---- 显存快照 / 释放（本脚本独占管理，秋叶脚本不再自己快照）----
. (Join-Path $PSScriptRoot '_vram.ps1')
$vramState = $null
trap { try { Restore-VramPrep $vramState } catch { }; exit 1 }
if (-not $KeepChatBackend) {
    $vramState = Start-VramPrep -NeedMiB 16000 -TimeoutSeconds 180
}

        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $akiRoot 'start-aki.ps1') -KeepChatBackend -NoPause -NoBrowser 2>&1 | Where-Object { $_ -match '就绪' } | ForEach-Object { '  ' + $_ }
        $startedHere = $true
        for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Seconds 3; if (Test-Up "http://127.0.0.1:$akiPort/system_stats") { break } }
    }
    $stamp2 = Get-Date -Format 'yyyyMMdd-HHmmss'
    $inName = "post-$stamp2.mp4"
    Copy-Item $current (Join-Path $inDir $inName) -Force
    $infoText = & $akiPy $tools info $current 2>&1
    $srcFps = 24.0
    if ($infoText -match 'fps=([\d\.]+)') { $srcFps = [double]$Matches[1] }
    $dstFps = [math]::Round($srcFps * $Interp, 1)
    $body = @{
        '1' = @{ class_type='LoadVideo'; inputs=@{ file=$inName } }
        '2' = @{ class_type='GetVideoComponents'; inputs=@{ video=@('1',0) } }
        '3' = @{ class_type='FrameInterpolationModelLoader'; inputs=@{ model_name='film_net_fp16.safetensors' } }
        '4' = @{ class_type='FrameInterpolate'; inputs=@{ interp_model=@('3',0); images=@('2',0); multiplier=$Interp } }
        '5' = @{ class_type='CreateVideo'; inputs=@{ images=@('4',0); fps=[double]$dstFps } }
        '6' = @{ class_type='SaveVideo'; inputs=@{ video=@('5',0); filename_prefix='wan-post'; format='mp4'; codec='h264' } }
    }
    $json = @{ prompt = $body } | ConvertTo-Json -Depth 12 -Compress
    Write-Host ("插帧 x{0}（{1} → {2} fps）..." -f $Interp, [int]$srcFps, $dstFps) -ForegroundColor Yellow
    $sw2 = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod "http://127.0.0.1:$akiPort/prompt" -Method POST -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 30
        $id = $r.prompt_id
        $done = $false
        for ($i = 0; $i -lt 240; $i++) {
            Start-Sleep -Seconds 4
            try { $h = Invoke-RestMethod "http://127.0.0.1:$akiPort/history/$id" -TimeoutSec 10 } catch { continue }
            if (-not $h.$id) { continue }
            if ($h.$id.status.status_str -eq 'error') {
                $h.$id.status.messages | Where-Object { $_[0] -eq 'execution_error' } | ForEach-Object { Write-Warning ("插帧出错：{0}" -f $_[1].exception_message) }
                break
            }
            if ($h.$id.outputs.'6') { $done = $true; break }
        }
        $sw2.Stop()
        if ($done) {
            $produced = Get-ChildItem $outDir -Filter 'wan-post_*.mp4' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($produced) {
                $current = $produced.FullName
                Write-Host ("  完成，用时 {0:N1} 秒" -f $sw2.Elapsed.TotalSeconds) -ForegroundColor Green
            }
        } else { Write-Warning '插帧未完成，保留上一步结果。' }
    } catch {
        Write-Warning ('插帧提交失败：' + $_.Exception.Message)
        if ($_.ErrorDetails) { Write-Host $_.ErrorDetails.Message }
    }
    if ($startedHere -and -not $KeepServer) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $akiRoot 'stop-aki.ps1') -NoRestore -NoPause 2>&1 | Where-Object { $_ -match '停止|释放' } | ForEach-Object { '  ' + $_ }
    }
}

# ---------- 3. 归位（只产生一个新编号视频） ----------
$final = Join-Path $outDir ("wan-final-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".mp4")
$n = 1
while (Test-Path $final) {
    $n++
    $final = Join-Path $outDir ("wan-final-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + "-$n.mp4")
    if ($n -gt 50) { break }
}
try { Copy-Item $current $final -Force } catch { Write-Warning '最终文件复制失败' }
Get-ChildItem $outDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^wan-(post|v2v-low)' -and $_.FullName -ne $final } |
    Remove-Item -Force -ErrorAction SilentlyContinue

if (Test-Path $organize) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $organize 2>&1 | Where-Object { $_ -match '归位' } | ForEach-Object { '  ' + $_ }
}
$latest = Get-ChildItem $videoDir -Filter '*.mp4' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if ($latest) {
    $frameDir = Join-Path $videoDir '_预览帧'
    New-Item -ItemType Directory -Force -Path $frameDir | Out-Null
    $py = Join-Path $env:TEMP 'post_frames.py'
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
    & $akiPy $py $latest.FullName $frameDir 2>&1 | Where-Object { $_ -match 'frames done' } | ForEach-Object { '  ' + $_ }
    Write-Host ''
    Write-Host ("成品：{0}" -f $latest.FullName) -ForegroundColor Green
    & $akiPy $tools info $latest.FullName 2>&1 | ForEach-Object { '  ' + $_ }
}

Pause-Brief
Restore-VramPrep $vramState
exit 0