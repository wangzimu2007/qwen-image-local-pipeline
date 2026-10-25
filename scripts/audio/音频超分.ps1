# 音频超分/修复：AudioSR basic（GPU，48kHz 输出）
# 用法：
#   powershell -ExecutionPolicy Bypass -File D:\audio-tools\音频超分.ps1 -Audio "C:\path\low.wav"
param(
    [Parameter(Mandatory=$true)][string]$Audio,
    [int]$Steps = 50,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Audio)) { throw "音频不存在：$Audio" }
$py = 'D:\ComfyUI-aki-v3.2\python\python.exe'
$helper = 'D:\audio-tools\audiosr_once.py'
$pylibs = 'D:\audio-tools\audiosr-pylibs'
$stage = 'D:\audio-tools\audiosr-stage'
New-Item -ItemType Directory -Path $stage -Force | Out-Null

$out = Join-Path $stage ('sr-' + [guid]::NewGuid().ToString('N') + '.wav')
$env:PYTHONPATH = $pylibs
$env:HF_ENDPOINT = 'https://hf-mirror.com'
$env:HF_HUB_DISABLE_XET = '1'
$env:PYTHONIOENCODING = 'utf-8'

Write-Host 'AudioSR 超分中（首次加载约 1 分钟）…' -ForegroundColor Cyan
& $py $helper $Audio $out --steps $Steps
if ($LASTEXITCODE -ne 0) { throw "AudioSR 失败，退出码 $LASTEXITCODE" }

Write-Host '归位到音频目录…' -ForegroundColor DarkGray
$psExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
& $psExe -NoProfile -ExecutionPolicy Bypass -File 'D:\qwen-image-2.1\整理音频.ps1' -SourceDir $stage -Kind audiosr
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
$latest = Get-ChildItem (Join-Path ([Environment]::GetFolderPath('Desktop')) '音频') -File -Filter 'audio-*-audiosr-*.wav' -ErrorAction SilentlyContinue |
          Sort-Object Name -Descending | Select-Object -First 1
if ($latest) { Write-Host ''; Write-Host ("成品：{0}" -f $latest.FullName) -ForegroundColor Green }
if (-not $NoPause) { Start-Sleep -Seconds 2 }
exit 0
