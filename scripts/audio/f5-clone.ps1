# F5克隆.ps1 —— 零样本声音克隆（F5-TTS，本地 f5-venv）
# 用法：.\F5克隆.ps1 -Reference ref.wav -Text "要读的内容" [-RefText "参考音频的文字"] [-Out a.wav]
# 说明：不传 -RefText 会自动转写参考音频（约 1~2 秒）。
param(
    [Parameter(Mandatory=$true)][string]$Reference,
    [Parameter(Mandatory=$true)][string]$Text,
    [string]$RefText = '',
    [string]$Out = '',
    [double]$Speed = 1.0,
    [int]$PauseMs = 0,
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
$py = 'D:\audio-tools\f5-venv\Scripts\python.exe'
$helper = Join-Path $PSScriptRoot '_mod_f5_tts.py'
if (-not (Test-Path $py)) { throw '缺少 f5-venv：' + $py }
if (-not (Test-Path $Reference)) { throw '参考音频不存在：' + $Reference }
if (-not $Out) {
    $dir = 'C:\Users\wangzimu\Desktop\音频'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $Out = Join-Path $dir ('audio-f5clone-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.wav')
}
$args = @($helper, '--ref', $Reference, '--text', $Text, '--out', $Out, '--speed', "$Speed")
if ($PauseMs -gt 0) { $args += @('--pause-ms', "$PauseMs") }
if ($RefText) { $args += @('--ref-text', $RefText) }
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $py @args 2>&1 | ForEach-Object { Write-Host ([string]$_) }
$code = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($code -ne 0) { throw "F5 克隆失败，退出码 $code" }
if (-not (Test-Path $Out)) { throw "没有生成音频：$Out" }
if (-not $NoPause) { Start-Sleep -Seconds 1 }
exit 0