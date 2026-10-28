# 视频接视频：把多段视频按顺序拼成一条（自动统一分辨率和帧率）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File D:\qwen-image-2.1\拼接视频.ps1 -Videos "a.mp4","b.mp4" -NoPause
#   powershell -ExecutionPolicy Bypass -File D:\qwen-image-2.1\拼接视频.ps1 -Videos "a.mp4","b.mp4" -Fps 24
#
# 说明：
#   - 分辨率统一取**第一段**的尺寸，其它段按比例拉伸到同尺寸
#   - 帧率默认跟第一段（-Fps auto），也可以用 -Fps 24 强制统一（自动补帧/丢帧）
#   - 拼接后按顺序播放，段与段之间没有转场
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Videos,
    [string]$Fps = 'auto',
    [double]$Crossfade = 0,
    [switch]$NoPause
)

# 兼容 `powershell -File ... -Videos "a.mp4,b.mp4"` 这种传参（数组会被拍平成一个字符串）
if (@($Videos).Count -eq 1 -and $Videos[0] -match '[,;]') {
    $Videos = $Videos[0] -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

$ErrorActionPreference = 'Stop'
$root     = 'D:\qwen-image-2.1'
$akiPy    = 'D:\ComfyUI-aki-v3.2\python\python.exe'
$desk     = [Environment]::GetFolderPath('Desktop')
$videoDir = Join-Path $desk '视频'
$outDir   = Join-Path $desk 'ComfyUI 输出'
$tools    = Join-Path $root '_video_tools.py'
$organize = Join-Path $root '整理视频.ps1'
$tmpDir   = Join-Path $env:TEMP 'dsh-video-join'

function Pause-Brief { param([int]$S = 8) if ($NoPause) { return }; Write-Host ''; Write-Host "窗口将在 $S 秒后自动关闭..." -ForegroundColor DarkGray; Start-Sleep -Seconds $S }

if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }

# 校验并解析路径
$resolved = @()
foreach ($v in $Videos) {
    if (-not (Test-Path $v)) {
        # 允许只给文件名，自动到「视频」目录里找
        $cand = Join-Path $videoDir $v
        if (Test-Path $cand) { $v = $cand } else { Write-Warning "找不到视频：$v"; Pause-Brief 10; exit 1 }
    }
    $resolved += (Resolve-Path $v).Path
}
if (@($resolved).Count -lt 2) { Write-Warning '至少要给两段视频'; Pause-Brief 10; exit 1 }

Write-Host '=== 待拼接 ===' -ForegroundColor Cyan
$i = 0
foreach ($r in $resolved) {
    $i++
    $infoLine = & $akiPy $tools info $r 2>&1
    Write-Host ("  [{0}] {1}" -f $i, (Split-Path $r -Leaf))
    Write-Host ('      ' + $infoLine) -ForegroundColor DarkGray
}

# 目标帧率
$targetFps = $Fps
if ($Fps -eq 'auto') {
    $info0 = & $akiPy $tools info $resolved[0] 2>&1
    if ($info0 -match 'fps=([\d\.]+)') { $targetFps = [string]([int][math]::Round([double]$Matches[1])) } else { $targetFps = '24' }
}
Write-Host ("目标帧率：{0}" -f $targetFps) -ForegroundColor Yellow

$tmpOut = Join-Path $tmpDir ("join-" + (Get-Date -Format 'HHmmss') + ".mp4")
$sw = [Diagnostics.Stopwatch]::StartNew()
if ($Crossfade -gt 0) {
    Write-Host ("交叉淡化 {0:N1} 秒..." -f $Crossfade) -ForegroundColor Yellow
    & $akiPy $tools crossfade $tmpOut $targetFps $Crossfade @resolved 2>&1 | ForEach-Object { '  ' + $_ }
} else {
& $akiPy $tools concatuniform $tmpOut $targetFps @resolved 2>&1 | ForEach-Object { '  ' + $_ }
}
$sw.Stop()
if (-not (Test-Path $tmpOut)) { Write-Warning '拼接失败'; Pause-Brief 10; exit 1 }
Write-Host ("拼接完成，用时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green

# 放进输出目录 → 归位编号
$final = Join-Path $outDir ("wan-join-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".mp4")
Copy-Item $tmpOut $final -Force
if (Test-Path $organize) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $organize 2>&1 | Where-Object { $_ -match '归位' } | ForEach-Object { '  ' + $_ }
}
$latest = Get-ChildItem $videoDir -Filter '*.mp4' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if ($latest) {
    $frameDir = Join-Path $videoDir '_预览帧'
    New-Item -ItemType Directory -Force -Path $frameDir | Out-Null
    $py = Join-Path $env:TEMP 'join_frames.py'
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
exit 0
