# FaceFusion换脸.ps1 —— FaceFusion 本地换脸（图片/视频，多模型 + 人脸增强）
#
# 比 换脸.ps1 强的地方：alphaface_256 / hyperswap 模型、CodeFormer/GFPGAN 增强、更好的遮罩融合。
#
# 用法：
#   .\FaceFusion换脸.ps1 -Src 我的脸.png -Dst 目标图.png -Out out.png
#   .\FaceFusion换脸.ps1 -Src 我的脸.png -Dst 视频.mp4 -Out out.mp4 -Model alphaface_256 -Enhancer codeformer
param(
    [Parameter(Mandatory=$true)][string]$Src,
    [Parameter(Mandatory=$true)][string]$Dst,
    [string]$Out = '',
    [ValidateSet('alphaface_256','hyperswap_1a_256','inswapper_128','ghost_2_256')][string]$Model = 'alphaface_256',
    [ValidateSet('codeformer','gfpgan_1.4','none')][string]$Enhancer = 'codeformer',
    [int]$VideoQuality = 90,
    [switch]$Gpu,
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
$srcRoot = 'D:\audio-tools\facefusion-src'
$py = 'D:\audio-tools\facefusion-venv\Scripts\python.exe'
if (-not (Test-Path $py)) { throw '缺少 FaceFusion 环境：' + $py }
if (-not (Test-Path (Join-Path $srcRoot 'facefusion.py'))) { throw '缺少 FaceFusion 源码：' + $srcRoot }
if (-not (Test-Path $Src)) { throw '源脸不存在：' + $Src }
if (-not (Test-Path $Dst)) { throw '目标文件不存在：' + $Dst }

if (-not $Out) {
    $dstExt = [IO.Path]::GetExtension($Dst).ToLower()
    if ($dstExt -in @('.mp4', '.mov', '.avi', '.mkv')) {
        $dir = 'C:\Users\wangzimu\Desktop\视频'
        $name = 'video-ff-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.mp4'
    } else {
        $dir = 'C:\Users\wangzimu\Desktop\Qwen 图片\测试'
        $name = 'faceswap-ff-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.png'
    }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $Out = Join-Path $dir $name
}

$env:PATH = 'D:\tools\ffmpeg\bin;' + $env:PATH
$finalOut = $Out
$isAsciiOut = ($Out -notmatch '[^\x00-\x7F]')
if (-not $isAsciiOut) {
    $ext0 = [IO.Path]::GetExtension($Out)
    $Out = Join-Path $env:TEMP ('ff_out_' + [guid]::NewGuid().ToString('n') + $ext0)
}
# 无声视频：FaceFusion 的“恢复音轨”会失败，先补一条静音轨
$tmpTarget = ''
$prevEap0 = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$dstExt0 = [IO.Path]::GetExtension($Dst).ToLower()
if ($dstExt0 -in @('.mp4', '.mov', '.avi', '.mkv')) {
    $probe = & 'D:\tools\ffmpeg\bin\ffprobe.exe' -v error -select_streams a -show_entries stream=index -of csv=p=0 $Dst 2>&1
    if (-not ($probe -match '\d')) {
        $tmpTarget = Join-Path $env:TEMP ('ff_silent_' + [guid]::NewGuid().ToString('n') + [IO.Path]::GetExtension($Dst))
        & 'D:\tools\ffmpeg\bin\ffmpeg.exe' -y -i $Dst -f lavfi -i anullsrc=r=48000:cl=stereo -shortest -map 0:v:0 -map 1:a:0 -c:v copy -c:a aac $tmpTarget 2>&1 | Out-Null
        if (Test-Path $tmpTarget) { $Dst = $tmpTarget }
    }
}
$ffArgs = @('facefusion.py', 'headless-run', '-s', $Src, '-t', $Dst, '-o', $Out,
          '--processors', 'face_swapper')
if ($Enhancer -ne 'none') {
    $ffArgs = @('facefusion.py', 'headless-run', '-s', $Src, '-t', $Dst, '-o', $Out,
              '--processors', 'face_swapper', 'face_enhancer',
              '--face-swapper-model', $Model, '--face-enhancer-model', $Enhancer,
              '--output-image-quality', '95', '--output-video-quality', "$VideoQuality")
} else {
    $ffArgs += @('--face-swapper-model', $Model, '--output-image-quality', '95', '--output-video-quality', "$VideoQuality")
}
if ($Gpu) {
    $ffArgs += @('--execution-providers', 'cuda')
} else {
    $ffArgs += @('--execution-providers', 'cpu')
}

$prev = Get-Location
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    Set-Location $srcRoot
    & $py @ffArgs 2>&1 | ForEach-Object { Write-Host ([string]$_) }
    $code = $LASTEXITCODE
} finally {
    Set-Location $prev
    $ErrorActionPreference = $prevEap
}
if ($code -ne 0 -and -not (Test-Path $Out)) { throw "FaceFusion 失败，退出码 $code" }
if (-not (Test-Path $Out)) { throw '没有生成产物：' + $Out }
if (-not $isAsciiOut) {
    $finalDir = Split-Path $finalOut -Parent
    New-Item -ItemType Directory -Force -Path $finalDir | Out-Null
    Move-Item -Force $Out $finalOut
    $Out = $finalOut
}
Write-Host ('成品：' + $Out) -ForegroundColor Green
Write-Host ('RESULT=' + $Out) -ForegroundColor Green
if ($tmpTarget -and (Test-Path $tmpTarget)) { Remove-Item $tmpTarget -Force -ErrorAction SilentlyContinue }
if (-not $NoPause) { Start-Sleep -Seconds 1 }
exit 0
