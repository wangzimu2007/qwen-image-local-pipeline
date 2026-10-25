# 音频分离：Demucs v4 htdemucs_ft，输出人声 / 伴奏两个 stem
# 用法：
#   powershell -ExecutionPolicy Bypass -File D:\audio-tools\分离音频.ps1 -Audio "C:\path\a.mp3"
param(
    [Parameter(Mandatory=$true)][string]$Audio,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Audio)) { throw "音频不存在：$Audio" }
$py = 'D:\ComfyUI-aki-v3.2\python\python.exe'
$pylibs = 'D:\audio-tools\demucs-pylibs'
$stage = 'D:\audio-tools\demucs-stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

$env:PYTHONPATH = $pylibs
$env:PYTHONIOENCODING = 'utf-8'
Write-Host 'Demucs 分离中（htdemucs_ft，GPU）…' -ForegroundColor Cyan
& $py -m demucs --two-stems=vocals -n htdemucs_ft -o $stage $Audio
if ($LASTEXITCODE -ne 0) { throw "Demucs 失败，退出码 $LASTEXITCODE" }

$stemDir = Get-ChildItem $stage -Directory -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'htdemucs_ft' } | Select-Object -First 1
if (-not $stemDir) { throw '没有找到 Demucs 输出目录' }
$trackDir = Get-ChildItem $stemDir.FullName -Directory | Select-Object -First 1
if (-not $trackDir) { throw '没有找到分离后的音轨目录' }

Write-Host '归位到音频目录（stems）…' -ForegroundColor DarkGray
$psExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
& $psExe -NoProfile -ExecutionPolicy Bypass -File 'D:\qwen-image-2.1\整理音频.ps1' -SourceDir $trackDir.FullName -Kind stems
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ('分离完成，stem 在：' + (Join-Path ([Environment]::GetFolderPath('Desktop')) '音频')) -ForegroundColor Green
if (-not $NoPause) { Start-Sleep -Seconds 2 }
exit 0
