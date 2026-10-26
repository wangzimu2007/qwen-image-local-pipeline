# 换脸.ps1 —— 图片/视频换脸（直连 ONNX，不依赖 insightface 包）
#
# 模型：SCRFD 检测 + ArcFace 身份 + inswapper_128 交换
# 位置：D:\qwen-image-2.1\models\faceswap\
#
# 用法：
#   .\换脸.ps1 -Src face.png -Dst target.png                     # 图片 → 测试夹
#   .\换脸.ps1 -Src face.png -Dst clip.mp4 -Out out.mp4          # 视频
#   .\换脸.ps1 -Src face.png -Dst target.png -MaxFaces 2         # 换多张脸
#
# 注意：仅限本人在获得肖像权人同意的前提下使用；不要用于伪造他人身份/不良内容。
param(
    [Parameter(Mandatory=$true)][string]$Src,
    [Parameter(Mandatory=$true)][string]$Dst,
    [string]$Out = '',
    [int]$MaxFaces = 1,
    [int]$DetSize = 0,        # 0=图片用 640 / 视频用 320（更快）
    [int]$DetEvery = 12,      # 视频每 N 帧重新检测，其余帧光流跟踪
    [switch]$Gpu,             # 尝试 CUDA（需 onnxruntime-gpu + cuDNN9）
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
$py = 'D:\ComfyUI-aki-v3.2\python\python.exe'
$helper = 'D:\qwen-image-2.1\换脸.py'
if (-not (Test-Path $py)) { throw "缺少 Python：$py" }
if (-not (Test-Path $helper)) { throw "缺少脚本：$helper" }
if (-not (Test-Path $Src)) { throw "源脸图片不存在：$Src" }
if (-not (Test-Path $Dst)) { throw "目标文件不存在：$Dst" }

$ext = [System.IO.Path]::GetExtension($Dst).ToLower()
if (-not $Out) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    if ($ext -in @('.mp4','.mov','.avi','.mkv')) {
        $dir = Split-Path $Dst -Parent
        $Out = Join-Path $dir ('video-faceswap-' + $stamp + $ext)
    } else {
        $dir = 'C:\Users\wangzimu\Desktop\Qwen 图片\测试'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $Out = Join-Path $dir ('faceswap-' + $stamp + '.png')
    }
}
$isVideo = $ext -in @('.mp4','.mov','.avi','.mkv')
if ($DetSize -le 0) { $DetSize = if ($isVideo) { 320 } else { 640 } }
$env:FACESWAP_DET_SIZE = "$DetSize"
if ($Gpu) { $env:FACESWAP_GPU = '1' } else { Remove-Item Env:\FACESWAP_GPU -ErrorAction SilentlyContinue }
$detEveryArg = if ($isVideo) { $DetEvery } else { 1 }
$sw = [Diagnostics.Stopwatch]::StartNew()
& $py $helper --src $Src --dst $Dst --out $Out --max-faces $MaxFaces --det-every $detEveryArg
Remove-Item Env:\FACESWAP_DET_SIZE -ErrorAction SilentlyContinue
Remove-Item Env:\FACESWAP_GPU -ErrorAction SilentlyContinue
$code = $LASTEXITCODE
$sw.Stop()
if ($code -ne 0) { throw "换脸失败，退出码 $code" }
if (Test-Path $Out) {
    Write-Host ''
    Write-Host ('  换脸完成（{0:N1} 秒）' -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    Write-Host ('  成品：' + $Out) -ForegroundColor Green
}
if (-not $NoPause) { Start-Sleep -Seconds 1 }
exit 0