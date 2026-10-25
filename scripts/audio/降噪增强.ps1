# 语音降噪/增强：Resemble Enhance（GPU，模型式）
# 用法：
#   powershell -ExecutionPolicy Bypass -File D:\audio-tools\降噪增强.ps1 -Audio "C:\path\a.wav"
#   ... -Enhance    降噪 + 生成式增强（更慢，可能改变音色）
param(
    [Parameter(Mandatory=$true)][string]$Audio,
    [switch]$Enhance,
    [string]$Output = '',
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Audio)) { throw "音频不存在：$Audio" }
$py = 'D:\ComfyUI-aki-v3.2\python\python.exe'
$helper = 'D:\audio-tools\resemble_once.py'
$pylibs = 'D:\audio-tools\resemble-pylibs'
$modelDir = 'D:\audio-tools\resemble-model\enhancer_stage2'
$stage = 'D:\audio-tools\resemble-stage'
New-Item -ItemType Directory -Path $stage -Force | Out-Null

$out = $Output
if (-not $out) { $out = Join-Path $stage ('enhanced-' + [guid]::NewGuid().ToString('N') + '.wav') }
$mode = if ($Enhance) { 'enhance' } else { 'denoise' }

$env:PYTHONPATH = $pylibs
$env:PYTHONIOENCODING = 'utf-8'
Write-Host ("Resemble Enhance：{0}（{1}）…" -f (Split-Path $Audio -Leaf), $mode) -ForegroundColor Cyan
$pyArgs = @($helper, $Audio, $out, '--mode', $mode, '--run-dir', $modelDir)
if ($Enhance) { $pyArgs += @('--nfe', '32', '--solver', 'midpoint', '--lambd', '0.5') }
& $py @pyArgs
if ($LASTEXITCODE -ne 0) { throw "Resemble Enhance 失败，退出码 $LASTEXITCODE" }

$finalPath = $out
if (-not $Output) {
    Write-Host '归位到音频目录…' -ForegroundColor DarkGray
    $psExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    & $psExe -NoProfile -ExecutionPolicy Bypass -File 'D:\qwen-image-2.1\整理音频.ps1' -SourceDir $stage -Kind enhanced
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    $latest = Get-ChildItem (Join-Path ([Environment]::GetFolderPath('Desktop')) '音频') -File -Filter 'audio-*-enhanced-*.wav' -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending | Select-Object -First 1
    if ($latest) { $finalPath = $latest.FullName }
}
Write-Host ''
Write-Host ("成品：{0}" -f $finalPath) -ForegroundColor Green
if (-not $NoPause) { Start-Sleep -Seconds 2 }
exit 0
