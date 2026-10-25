# 启停通用包装：Ollama / NInfer
# 用法：
#   .\后端启停.ps1 -Kind ollama -Action stop
#   .\后端启停.ps1 -Kind ollama -Action start -Wait
#   .\后端启停.ps1 -Kind ninfer -Action stop
param(
    [Parameter(Mandatory = $true)][ValidateSet('ollama', 'ninfer')][string]$Kind,
    [Parameter(Mandatory = $true)][ValidateSet('start', 'stop')][string]$Action,
    [switch]$Wait,
    [int]$TimeoutSeconds = 180,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_backend.ps1')
$jobsRoot = 'D:\qwen-image-2.1\.jobs'
if (-not (Test-Path $jobsRoot)) { New-Item -ItemType Directory -Force -Path $jobsRoot | Out-Null }

function Say { param([string]$t, [string]$c = 'Gray') if (-not $Quiet) { Write-Host ('  ' + $t) -ForegroundColor $c } }

if ($Action -eq 'stop') {
    # 1) 先写标记：Keeper 之后不会再自动拉起
    $p = Set-UserStopFlag -Kind $Kind -JobsRoot $jobsRoot
    Say ('已记录手动停止标记：' + (Split-Path $p -Leaf)) 'DarkGray'

    switch ($Kind) {
        'ollama' {
            # 停托盘 + 服务进程
            Get-Process -Name 'ollama app', 'ollama' -ErrorAction SilentlyContinue |
                ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue; Say ('停止 ' + $_.ProcessName + ' PID ' + $_.Id) }
        }
        'ninfer' {
            $stopPs = 'D:\tools\ninfer\stop-ninfer-server.ps1'
            if (Test-Path $stopPs) {
                & powershell -NoProfile -ExecutionPolicy Bypass -File $stopPs 2>&1 | ForEach-Object { Say ([string]$_) }
            } else {
                # 兜底：关掉 WSL
                Say '找不到 stop-ninfer-server.ps1，尝试 wsl --terminate Ubuntu-24.04' 'Yellow'
                & wsl --terminate Ubuntu-24.04 2>&1 | Out-Null
            }
        }
    }

    $port = if ($Kind -eq 'ollama') { 11434 } else { 8090 }
    $gone = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        if (-not (Test-PortListening -Port $port)) { $gone = $true; break }
    }
    if ($gone) { Say ('✓ ' + $Kind + ' 已停止，并且不会自动拉回来（直到你点它的「启动」）') 'Green' }
    else { Say ('⚠ 端口 ' + $port + ' 仍在监听，可能没停干净') 'Yellow' }

    # 清掉"想恢复"记录，避免守护批末又拉起
    foreach ($f in 'strata-wanted.json', 'backends-wanted.json') {
        $q = Join-Path $jobsRoot $f
        if (Test-Path $q) { Remove-Item $q -Force -ErrorAction SilentlyContinue }
    }
    Write-Host ''
    exit 0
}

# ---- start ----
Clear-UserStopFlag -Kind $Kind -JobsRoot $jobsRoot
Say '已清除「手动停止」标记，守护可以自动拉回了。' 'DarkGray'

$port = if ($Kind -eq 'ollama') { 11434 } else { 8090 }
if (Test-PortListening -Port $port) {
    Say ($Kind + ' 已经在运行（端口 ' + $port + ' 在监听），无需重复启动。') 'Green'
    exit 0
}

switch ($Kind) {
    'ollama' {
        $exe = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'
        if (-not (Test-Path $exe)) { Say '✗ 找不到 ollama app.exe' 'Red'; exit 1 }
        Say '启动 Ollama…' 'Yellow'
        Start-Process -FilePath $exe -WindowStyle Hidden
    }
    'ninfer' {
        $vbs = 'D:\tools\ninfer\start-ninfer-server.vbs'
        if (-not (Test-Path $vbs)) { Say '✗ 找不到 start-ninfer-server.vbs' 'Red'; exit 1 }
        Say '启动 NInfer（WSL）…' 'Yellow'
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbs + '"') -WindowStyle Hidden
    }
}

if ($Wait) {
    Say '等待就绪…' 'DarkGray'
    for ($i = 0; $i -lt [Math]::Max(1, [int]($TimeoutSeconds / 3)); $i++) {
        Start-Sleep -Seconds 3
        if (Test-PortListening -Port $port) { Say ('✓ 已就绪（{0} 秒）' -f (($i + 1) * 3)) 'Green'; exit 0 }
    }
    Say '⚠ 超时还没就绪' 'Yellow'
    exit 2
}
Say '已触发启动。' 'DarkGray'
exit 0
