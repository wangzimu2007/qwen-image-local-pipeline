# 音频转 MIDI：Basic Pitch（独立 Python 3.11 环境）
# 用法：
#   powershell -ExecutionPolicy Bypass -File D:\audio-tools\音频转MIDI.ps1 -Audio "C:\path\song.mp3"
param(
    [Parameter(Mandatory=$true)][string]$Audio,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Audio)) { throw "音频不存在：$Audio" }
$exe = 'D:\audio-tools\basicpitch-venv\Scripts\basic-pitch.exe'
$outDir = Join-Path ([Environment]::GetFolderPath('Desktop')) '音频\MIDI'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
Write-Host 'Basic Pitch 转 MIDI…' -ForegroundColor Cyan
& $exe $outDir $Audio
if ($LASTEXITCODE -ne 0) { throw "Basic Pitch 失败，退出码 $LASTEXITCODE" }

$midi = Get-ChildItem $outDir -File -Filter '*.mid' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($midi) {
    Write-Host ''
    Write-Host ("MIDI：{0}" -f $midi.FullName) -ForegroundColor Green
} else {
    Write-Warning '没有找到生成的 MIDI 文件。'
}
if (-not $NoPause) { Start-Sleep -Seconds 2 }
exit 0
