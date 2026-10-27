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
function Test-F5Server {
    param([int]$p)
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect('127.0.0.1', $p, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(300)) { $c.Close(); return $false }
        $c.EndConnect($iar); $c.Close(); return $true
    } catch { return $false }
}

$port = 8766
$server = Join-Path $PSScriptRoot 'f5_server.py'
$client = Join-Path $PSScriptRoot '_f5_client.py'
$serverReady = Test-F5Server $port
if (-not $serverReady -and (Test-Path $server) -and (Test-Path $client)) {
    $outLog = Join-Path $PSScriptRoot 'f5-server.out.log'
    $errLog = Join-Path $PSScriptRoot 'f5-server.err.log'
    try {
        $logCmd = 'cmd.exe /c ""' + $py + '" "' + $server + '" --port ' + $port + ' --idle 600 > "' + $outLog + '" 2> "' + $errLog + '""'
        $null = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
            CommandLine = $logCmd; CurrentDirectory = $PSScriptRoot }
    } catch { }
    for ($i = 0; $i -lt 120; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-F5Server $port) { $serverReady = $true; break }
    }
}

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
if ($serverReady -and (Test-Path $client)) {
    $cargs = @($client, '--port', "$port", '--ref', $Reference, '--out', $Out,
               '--speed', "$Speed", '--pause-ms', "$PauseMs", '--text', $Text)
    if ($RefText) { $cargs += @('--ref-text', $RefText) }
    & $py @cargs 2>&1 | ForEach-Object { Write-Host ([string]$_) }
    $code = $LASTEXITCODE
    if ($code -eq 0 -and (Test-Path $Out)) {
        $ErrorActionPreference = $prevEap
        if (-not $NoPause) { Start-Sleep -Seconds 1 }
        exit 0
    }
    Write-Host '常驻服务失败，回退冷加载…'
}

$cargs = @($helper, '--ref', $Reference, '--text', $Text, '--out', $Out, '--speed', "$Speed")
if ($PauseMs -gt 0) { $cargs += @('--pause-ms', "$PauseMs") }
if ($RefText) { $cargs += @('--ref-text', $RefText) }
& $py @cargs 2>&1 | ForEach-Object { Write-Host ([string]$_) }
$code = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($code -ne 0) { throw "F5 克隆失败，退出码 $code" }
if (-not (Test-Path $Out)) { throw "没有生成音频：$Out" }
if (-not $NoPause) { Start-Sleep -Seconds 1 }
exit 0