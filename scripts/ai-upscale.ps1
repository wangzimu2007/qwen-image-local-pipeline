# AI 超分（SeedVR2 官方 CLI）：真正带时序信息的 AI 视频超分，一键调用，不需要开界面
#
# 和「后期处理.ps1 -Scale」的区别：
#   -Scale      = Lanczos，秒级，不增加细节
#   -Resolution = SeedVR2，逐帧+跨帧重建细节，慢但明显更清晰、不闪
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File D:\qwen-image-2.1\AI超分.ps1 -Video "某视频.mp4" -NoPause
#   ... -Resolution 720 -BatchSize 9          # 更快/更省显存
#   ... -Resolution 1080 -BatchSize 21        # 画质优先（24GB 可用）
param(
    [Parameter(Mandatory = $true)]
    [string]$Video,
    [int]$Resolution = 1080,
    [int]$BatchSize = 21,
    [string]$Color = 'lab',
    [switch]$NoTile,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$repo     = 'D:\seedvr2-cli\ComfyUI-SeedVR2_VideoUpscaler-main'
$py       = 'D:\Comfy-Desktop\ComfyUI-Installs\ComfyUI (1)\ComfyUI\.venv\Scripts\python.exe'
$models   = Join-Path $repo 'models\SEEDVR2'
$cli      = Join-Path $repo 'inference_cli.py'
$root     = 'D:\qwen-image-2.1'
$tools    = Join-Path $root '_video_tools.py'
$organize = Join-Path $root '整理视频.ps1'
$desk     = [Environment]::GetFolderPath('Desktop')
$videoDir = Join-Path $desk '视频'
$outDir   = Join-Path $desk 'ComfyUI 输出'
$tmp      = Join-Path $env:TEMP 'dsh-aiupscale'

function Pause-Brief { param([int]$S = 10) if ($NoPause) { return }; Write-Host ''; Write-Host "窗口将在 $S 秒后自动关闭..." -ForegroundColor DarkGray; Start-Sleep -Seconds $S }

if (-not (Test-Path $Video)) { Write-Warning "找不到视频：$Video"; Pause-Brief; exit 1 }
if (-not (Test-Path $cli)) { Write-Warning "缺少 SeedVR2 CLI：$cli"; Pause-Brief; exit 1 }
if (-not (Test-Path (Join-Path $models 'seedvr2_ema_3b_fp8_e4m3fn.safetensors'))) { Write-Warning "缺少 SeedVR2 模型：$models"; Pause-Brief; exit 1 }
if (-not (Test-Path $tmp)) { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }
$Video = (Resolve-Path $Video).Path

# batch_size 必须符合 4n+1
if ((($BatchSize - 1) % 4) -ne 0) {
    $BatchSize = 4 * [int][math]::Round(($BatchSize - 1) / 4.0) + 1
    if ($BatchSize -lt 5) { $BatchSize = 5 }
}

Write-Host '=== 输入 ===' -ForegroundColor Cyan
$infoLine = & $py $tools info $Video 2>&1
Write-Host ('  ' + $infoLine)
Write-Host ("参数：短边 {0}p / batch {1} / 色彩校正 {2}" -f $Resolution, $BatchSize, $Color) -ForegroundColor Cyan
Write-Host '  （3B fp8 模型，24GB 显存够用；耗时约为视频时长的 15~30 倍）' -ForegroundColor DarkGray

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out   = Join-Path $tmp ("aiup-$stamp.mp4")
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'

Write-Host '=== 开始超分 ===' -ForegroundColor Yellow
$sw = [Diagnostics.Stopwatch]::StartNew()
# 原生命令会把警告写到 stderr，Stop 模式下会被当终止性错误 —— 临时改成 Continue
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$cliArgs = @($Video, '--output', $out, '--model_dir', $models, '--resolution', $Resolution,
             '--batch_size', $BatchSize, '--color_correction', $Color, '--debug')
# 大分辨率必须开 VAE 分块：实测 1080p 不开分块会在 Phase 3 解码时把显存吃到 25.2GB 直接崩
if (-not $NoTile -and $Resolution -ge 900) {
    $cliArgs += @('--vae_encode_tiled', '--vae_encode_tile_size', '768', '--vae_encode_tile_overlap', '96',
                  '--vae_decode_tiled', '--vae_decode_tile_size', '768', '--vae_decode_tile_overlap', '96')
    Write-Host '  （已启用 VAE 分块编解码，避免 1080p 解码爆显存）' -ForegroundColor DarkGray
}
$log = & $py $cli @cliArgs 2>&1
$ErrorActionPreference = $prevEap
$sw.Stop()
$log |
    Where-Object { $_ -match 'Phase|Peak|Average FPS|completed successfully|ERROR|❌|Resolution:' } |
    Select-Object -Last 12 | ForEach-Object { '  ' + $_ }

if (-not (Test-Path $out)) {
    Write-Warning '超分失败，没有输出文件。'
    $log | Select-Object -Last 8 | ForEach-Object { '  ' + $_ }
    Pause-Brief; exit 1
}
Write-Host ("超分完成，用时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green

# 归位编号（只产生一个新视频）
$final = Join-Path $outDir ("wan-aiup-" + $stamp + ".mp4")
Copy-Item $out $final -Force
if (Test-Path $organize) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $organize 2>&1 | Where-Object { $_ -match '归位' } | ForEach-Object { '  ' + $_ }
}
$latest = Get-ChildItem $videoDir -Filter '*.mp4' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if ($latest) {
    $frameDir = Join-Path $videoDir '_预览帧'
    New-Item -ItemType Directory -Force -Path $frameDir | Out-Null
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
    $pyf = Join-Path $env:TEMP 'aiup_frames.py'
    [System.IO.File]::WriteAllText($pyf, $code, (New-Object System.Text.UTF8Encoding($false)))
    & $py $pyf $latest.FullName $frameDir 2>&1 | Where-Object { $_ -match 'frames done' } | ForEach-Object { '  ' + $_ }
    Write-Host ''
    Write-Host ("成品：{0}" -f $latest.FullName) -ForegroundColor Green
    & $py $tools info $latest.FullName 2>&1 | ForEach-Object { '  ' + $_ }
}

Pause-Brief
exit 0
