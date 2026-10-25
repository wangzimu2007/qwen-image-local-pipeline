# 说话人分离：sherpa-onnx pyannote 分段 + 3D-Speaker 声纹
# 适合 2 人对话；输出时间轴文本到 桌面\音频\文字稿
# 用法：
#   powershell -ExecutionPolicy Bypass -File D:\audio-tools\说话人分离.ps1 -Audio "C:\path\meeting.wav"
param(
    [Parameter(Mandatory=$true)][string]$Audio,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Audio)) { throw "音频不存在：$Audio" }
$py = 'D:\speech\venv\Scripts\python.exe'
$dir = 'D:\audio-tools\diarization-models'
$script = Join-Path $dir 'sherpa-onnx-pyannote-segmentation-3-0\speaker-diarization-onnx.py'
$seg = Join-Path $dir 'sherpa-onnx-pyannote-segmentation-3-0\model.onnx'
$emb = Join-Path $dir 'speaker_embedding.onnx'
if (-not (Test-Path $script)) { throw "分离脚本不存在：$script" }

$outDir = Join-Path ([Environment]::GetFolderPath('Desktop')) '音频\文字稿'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$base = [IO.Path]::GetFileNameWithoutExtension($Audio)
$outFile = Join-Path $outDir ($base + '.diarization.txt')

Write-Host '说话人分离中（2 人模型）…' -ForegroundColor Cyan
$raw = & $py $script --seg-model $seg --speaker-embedding-model $emb --wav $Audio 2>&1
$segments = @($raw | Where-Object { $_ -match '^\d+:\d+:\d+\.\d+ --> \d+:\d+:\d+\.\d+ speaker_\d+' })

$lines = @()
$lines += "音频：$Audio"
$lines += "模型：sherpa-onnx pyannote-segmentation-3.0 + 3D-Speaker eres2net"
$lines += "说明：按 2 人聚类，输出 speaker_00 / speaker_01"
$lines += ''
if ($segments.Count -eq 0) {
    $lines += '没有检测到可用说话人段。'
    Write-Host '没有检测到说话人段。' -ForegroundColor Yellow
} else {
    $lines += $segments
    $segments | ForEach-Object { Write-Host $_ -ForegroundColor Green }
}
[IO.File]::WriteAllLines($outFile, $lines, (New-Object Text.UTF8Encoding($false)))
Write-Host ''
Write-Host ("时间轴：{0}" -f $outFile) -ForegroundColor Cyan
if (-not $NoPause) { Start-Sleep -Seconds 2 }
exit 0
