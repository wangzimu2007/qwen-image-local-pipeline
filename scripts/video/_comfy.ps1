# ComfyUI 公共启停函数（秋叶版 8189）
function Test-ComfyUp {
    param([int]$Port = 8189)
    try { $null = Invoke-RestMethod "http://127.0.0.1:$Port/system_stats" -TimeoutSec 3; return $true }
    catch { return $false }
}

function Start-ComfyIfNeeded {
    param(
        [Parameter(Mandatory = $true)][string]$AkiRoot,
        [int]$Port = 8189,
        [string]$Filter = '就绪|启动'
    )
    if (Test-ComfyUp -Port $Port) { return $false }
    Write-Host '启动秋叶版 ComfyUI...' -ForegroundColor Yellow
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $AkiRoot 'start-aki.ps1') -KeepChatBackend -NoPause -NoBrowser 2>&1 |
        Where-Object { $_ -match $Filter } | ForEach-Object { Write-Host ('  ' + [string]$_) }
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Seconds 3
        if (Test-ComfyUp -Port $Port) { return $true }
    }
    throw 'ComfyUI 启动失败或超时'
}

function Stop-ComfyIfStarted {
    param(
        [Parameter(Mandatory = $true)][string]$AkiRoot,
        [bool]$StartedHere,
        [switch]$KeepServer
    )
    if (-not $StartedHere -or $KeepServer) { return }
    Write-Host '关闭本次启动的 ComfyUI...' -ForegroundColor DarkGray
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $AkiRoot 'stop-aki.ps1') -NoRestore -NoPause 2>&1 |
        Where-Object { $_ -match '停止|释放' } | ForEach-Object { Write-Host ([string]$_) }
}
