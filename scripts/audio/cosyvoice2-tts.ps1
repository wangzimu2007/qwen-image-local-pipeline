# CosyVoice2配音.ps1 —— Windows 原生（venv2 + torch cu130，soundfile 读取参考音频）
#
# 用法：
#   .\CosyVoice2配音.ps1 -Text "台词" -Out D:\audio-tools\gen-out\a.wav -Instruct "沉稳的中年男声，语速稍慢"
#   .\CosyVoice2配音.ps1 -Text "..." -Out a.wav -Reference C:\音频素材\原神\派蒙\xxx.wav
#
# 说明：默认参考音色 D:\audio-tools\cosyvoice\voices\default_16k.wav；
#       想克隆某人音色就传 -Reference（16k/任意采样率，脚本会转 16k）。
param(
    [Parameter(Mandatory=$true)][string]$Text,
    [Parameter(Mandatory=$true)][string]$Out,
    [string]$Instruct = '',
    [string]$Reference = '',
    [double]$Speed = 1.0,
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
$py = 'D:\audio-tools\cosyvoice\venv2\Scripts\python.exe'
$helper = Join-Path $PSScriptRoot '_cosy_tts.py'
if (-not (Test-Path $py)) { throw '缺少 venv2：' + $py }
if (-not (Test-Path $helper)) { throw '缺少 _cosy_tts.py' }
$args = @($helper, '--text', $Text, '--out', $Out, '--speed', "$Speed")
if ($Instruct) { $args += @('--instruct', $Instruct) }
if ($Reference) { $args += @('--reference', $Reference) }
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $py @args 2>&1 | ForEach-Object { Write-Host ([string]$_) }
$code = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($code -ne 0) { throw "CosyVoice2 失败，退出码 $code" }
if (-not (Test-Path $Out)) { throw "没有生成音频：$Out" }
if (-not $NoPause) { Start-Sleep -Seconds 1 }
exit 0