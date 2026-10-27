# AudioSep分离.ps1 —— 文本查询分离（AudioSep，本地 audiosep-venv）
# 用法：
#   .\AudioSep分离.ps1 -Input mix.wav -Query "speech" -Out out.wav
#   .\AudioSep分离.ps1 -Input mix.wav -Query "music" -Out out.wav
# 说明：Query 用英文效果最好（speech / music / singing voice / dog barking / rain ...）
param(
    [Parameter(Mandatory=$true)][Alias('Input')][string]$Source,
    [Parameter(Mandatory=$true)][string]$Query,
    [string]$Out = '',
    [ValidateSet('cuda','cpu')][string]$Device = 'cuda',
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
$py = 'D:\audio-tools\audiosep-venv\Scripts\python.exe'
$helper = Join-Path $PSScriptRoot '_audiosep_infer.py'
if (-not (Test-Path $py)) { throw '缺少 audiosep-venv' }
if (-not (Test-Path $Source)) { throw '输入音频不存在：' + $Source }
if (-not $Out) {
    $dir = 'C:\Users\wangzimu\Desktop\音频'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $Out = Join-Path $dir ('audio-sep-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.wav')
}
$args = @($helper, '--input', $Source, '--text', $Query, '--out', $Out, '--device', $Device)
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $py @args 2>&1 | ForEach-Object { Write-Host ([string]$_) }
$code = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($code -ne 0) { throw "AudioSep 失败，退出码 $code" }
if (-not (Test-Path $Out)) { throw '没有生成音频：' + $Out }
if (-not $NoPause) { Start-Sleep -Seconds 1 }
exit 0
