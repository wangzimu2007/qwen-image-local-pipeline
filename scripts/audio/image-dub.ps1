# 图像配音.ps1 —— 一张图 + 旁白 → 带配音（可选字幕）的视频
param(
    [Parameter(Mandatory=$true)][string]$Image,
    [string]$Prompt = '',
    [double]$Seconds = 8,
    [string]$Voice = '',
    [string]$Language = 'zh',
    [switch]$BurnSubtitles,
    [double]$Speed = 1.0,
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
$py = 'D:\audio-tools\qt-venv\Scripts\python.exe'
$helper = 'D:\audio-tools\image_dub.py'
& $py $helper --image $Image --prompt $Prompt --seconds $Seconds --voice $Voice --language $Language --speed $Speed @(if ($BurnSubtitles) { '--burn-subtitles' })
if ($LASTEXITCODE -ne 0) { throw "图像配音失败，退出码 $LASTEXITCODE" }
if (-not $NoPause) { Start-Sleep -Seconds 1 }
exit 0