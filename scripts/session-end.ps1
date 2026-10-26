# 会话结束：停掉出图引擎，按会话开始时记下的快照恢复本地聊天模型
param(
    [switch]$KeepEngine,
    [switch]$NoRestore
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_vram.ps1')

Write-Host ''
Write-Host '== 会话结束 ==' -ForegroundColor Cyan

if (-not $KeepEngine) {
    $killed = 0
    foreach($p in @(
        'D:\Comfy-Desktop\ComfyUI-Installs\ComfyUI (1)\ComfyUI\.venv\Scripts\python.exe',
        'D:\Comfy-Desktop\ComfyUI-Installs\ComfyUI (1)\standalone-env\python.exe'
    )){
        Get-Process python -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $p } | ForEach-Object {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            Write-Host ('  已停引擎 PID ' + $_.Id) -ForegroundColor DarkGray
            $script:killed++
        }
    }
    # 秋叶版
    $akiPy = 'D:\ComfyUI-aki-v3.2\python\python.exe'
    Get-Process python, python313 -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $akiPy } | ForEach-Object {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        Write-Host ('  已停秋叶引擎 PID ' + $_.Id) -ForegroundColor DarkGray
        $script:killed++
    }
    if($script:killed -eq 0){ Write-Host '  没有发现运行中的出图引擎' -ForegroundColor DarkGray }
    Start-Sleep -Seconds 2
}

if (-not $NoRestore) {
    Restore-VramPrep $null
} else {
    Write-Host '  按 -NoRestore 跳过恢复（快照文件保留，下次仍会恢复）' -ForegroundColor DarkGray
}

$free = Get-FreeVramMiB
Write-Host ('  当前可用显存: {0:N1} GB' -f ($free/1024)) -ForegroundColor DarkGray
Write-Host ''
Write-Host '  会话已结束。' -ForegroundColor Green
exit 0