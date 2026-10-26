# 会话开始：把本地聊天模型收进快照并腾出显存，然后按需拉起出图引擎
# 之后连续出图请都加 -KeepChatBackend -KeepServer，每张只需几秒；结束时跑 会话-结束.ps1
param(
    [ValidateSet('desktop', 'selfbuilt', 'aki', 'none')]
    [string]$Engine = 'desktop',
    [switch]$SkipCheck
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_vram.ps1')

Write-Host ''
Write-Host '== 会话开始 ==' -ForegroundColor Cyan

$state = Start-VramPrep -NeedMiB 14000 -TimeoutSeconds 120
if ($state -eq $null) { Write-Host '  当前没有本地聊天模型占用，无需恢复' -ForegroundColor DarkGray }

# 检查显存是否真的空出来了
$free = Get-FreeVramMiB
Write-Host ('  当前可用显存: {0:N1} GB' -f ($free/1024)) -ForegroundColor DarkGray
if ($free -lt 12000) {
    Write-Host ('  ⚠ 显存仍偏少（{0:N1} GB），出图可能偏慢' -f ($free/1024)) -ForegroundColor Yellow
    Get-VramHolders -Top 5 | ForEach-Object { Write-Host ('    {0,-26} PID {1,-7} {2,6:N2} GB' -f $_.Name, $_.PID, $_.GB) -ForegroundColor DarkGray }
    Write-Host '  如严重不足：.\显存体检.ps1 -Kill  或关掉占显存的程序' -ForegroundColor Yellow
}

if ($Engine -ne 'none') {
    $running = $false
    try { $null = Invoke-RestMethod 'http://127.0.0.1:8188/system_stats' -TimeoutSec 3; $running = $true } catch {}
    if ($running) {
        Write-Host '  出图引擎已在运行（8188）' -ForegroundColor DarkGray
    } else {
        $deskPy = 'D:\Comfy-Desktop\ComfyUI-Installs\ComfyUI (1)\ComfyUI\.venv\Scripts\python.exe'
        $deskDir = 'D:\Comfy-Desktop\ComfyUI-Installs\ComfyUI (1)\ComfyUI'
        if ($Engine -eq 'desktop' -and (Test-Path $deskPy)) {
            Write-Host '  启动桌面版引擎（8188，Z-Image）…'
            Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
            Start-Process -FilePath $deskPy -ArgumentList @('main.py','--port','8188','--listen','127.0.0.1') -WorkingDirectory $deskDir -WindowStyle Hidden
            for($i=0; $i -lt 40; $i++){ Start-Sleep -Seconds 2; try { $null = Invoke-RestMethod 'http://127.0.0.1:8188/system_stats' -TimeoutSec 2; Write-Host ('  引擎就绪（' + ($i*2+2) + ' 秒）') -ForegroundColor Green; break } catch {} }
        } elseif ($Engine -eq 'selfbuilt') {
            Write-Host '  启动自建版引擎（8188，MOSS）…'
            Start-Process 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','D:\ComfyUI\start-comfyui.ps1') -WindowStyle Hidden
            for($i=0; $i -lt 40; $i++){ Start-Sleep -Seconds 2; try { $null = Invoke-RestMethod 'http://127.0.0.1:8188/system_stats' -TimeoutSec 2; Write-Host ('  引擎就绪（' + ($i*2+2) + ' 秒）') -ForegroundColor Green; break } catch {} }
        } elseif ($Engine -eq 'aki') {
            Write-Host '  启动秋叶版引擎（8189，H3/Wan）…'
            & powershell -NoProfile -ExecutionPolicy Bypass -File 'D:\ComfyUI-aki-v3.2\start-aki.ps1' -KeepChatBackend -NoPause -NoBrowser 2>&1 | Select-Object -Last 2 | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor DarkGray }
        }
    }
}

Write-Host ''
Write-Host '  会话已就绪。接下来出图请加： -KeepChatBackend -KeepServer' -ForegroundColor Green
Write-Host '  结束时跑： D:\qwen-image-2.1\会话-结束.ps1' -ForegroundColor Green
exit 0