# 声音克隆：Chatterbox Multilingual（给参考人声，朗读任意文本）
# 用法：
#   powershell -ExecutionPolicy Bypass -File D:\audio-tools\声音克隆.ps1 -Reference "ref.wav" -Text "要说的内容"
#   ... -Language zh -Exaggeration 0.5 -CfgWeight 0.5
param(
    [Parameter(Mandatory=$true)][string]$Reference,
    [Parameter(Mandatory=$true)][string]$Text,
    [string]$Language = 'zh',
    [double]$Exaggeration = 0.5,
    [double]$CfgWeight = 0.5,
    [string]$Output = '',
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Reference)) { throw "参考音频不存在：$Reference" }
$py = 'D:\ComfyUI-aki-v3.2\python\python.exe'
$helper = 'D:\audio-tools\chatterbox_clone.py'
$pylibs = 'D:\audio-tools\chatterbox-pylibs'
$stage = 'D:\audio-tools\chatterbox-stage'
New-Item -ItemType Directory -Path $stage -Force | Out-Null

$out = $Output
if (-not $out) { $out = Join-Path $stage ('clone-' + [guid]::NewGuid().ToString('N') + '.wav') }
$env:PYTHONPATH = $pylibs
$env:HF_ENDPOINT = 'https://hf-mirror.com'
$env:HF_HUB_DISABLE_XET = '1'
$env:PYTHONIOENCODING = 'utf-8'

Write-Host 'Chatterbox 声音克隆（首次会下载模型，约 20-30 秒）…' -ForegroundColor Cyan
& $py $helper --text $Text --reference $Reference --language $Language --output $out `
    --exaggeration $Exaggeration --cfg-weight $CfgWeight
if ($LASTEXITCODE -ne 0) { throw "Chatterbox 克隆失败，退出码 $LASTEXITCODE" }

$finalPath = $out
if (-not $Output) {
    Write-Host '归位到音频目录…' -ForegroundColor DarkGray
    $psExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    & $psExe -NoProfile -ExecutionPolicy Bypass -File 'D:\qwen-image-2.1\整理音频.ps1' -SourceDir $stage -Kind ttsclone
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    $latest = Get-ChildItem (Join-Path ([Environment]::GetFolderPath('Desktop')) '音频') -File -Filter 'audio-*-ttsclone-*.wav' -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending | Select-Object -First 1
    if ($latest) { $finalPath = $latest.FullName }
}
Write-Host ''
Write-Host ("成品：{0}" -f $finalPath) -ForegroundColor Green
if (-not $NoPause) { Start-Sleep -Seconds 2 }
exit 0
