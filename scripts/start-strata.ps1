# 启Strata.ps1 —— 启动 Strata，并清除"手动停止"标记（告诉守护：从现在起恢复自动拉回）
param(
    [ValidateSet('iq3s', 'nvfp4')]
    [string]$Variant = 'iq3s',
    [switch]$Wait,
    [int]$TimeoutSeconds = 240
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_backend.ps1')
$jobsRoot = 'D:\qwen-image-2.1\.jobs'
$flag = Join-Path $jobsRoot 'user-stop.flag'

# 1) 清标记（用户明确要启动）：按后端 + 兼容旧全局标记
$hadFlag = (Test-Path (Join-Path $jobsRoot 'user-stop-strata.flag')) -or (Test-Path (Join-Path $jobsRoot 'user-stop.flag'))
Clear-UserStopFlag -Kind 'strata' -JobsRoot $jobsRoot
if ($hadFlag) {
    Write-Host '  已清除「手动停止」标记，守护可以自动拉回了。' -ForegroundColor DarkGray
}

# 2) 已经在跑就不重复启动（避免 launch --stop 把正在加载的实例杀掉）
if (Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue) {
    Write-Host '  Strata 已经在运行（8080 在监听），无需重复启动。' -ForegroundColor Green
    exit 0
}
$procs = @(Get-Process -Name strata, strata-vision -ErrorAction SilentlyContinue).Count
if ($procs -gt 0) {
    Write-Host '  Strata 进程已在（正在加载），等它就绪即可，不重复启动。' -ForegroundColor Yellow
} else {
    $startCmd = if ($Variant -eq 'nvfp4') { 'start-nvfp4.cmd' } else { 'start-iq3s.cmd' }
    $startPath = Join-Path $env:LOCALAPPDATA ('Strata\actions\' + $startCmd)
    if (-not (Test-Path $startPath)) { Write-Host ('  ✗ 找不到启动脚本：' + $startPath) -ForegroundColor Red; exit 1 }
    Write-Host ('  启动 Strata（' + $Variant + '）…') -ForegroundColor Yellow
    Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', ('"' + $startPath + '"')) -WindowStyle Hidden
}

if ($Wait) {
    Write-Host '  等待就绪…' -ForegroundColor DarkGray
    for ($i = 0; $i -lt [Math]::Max(1, [int]($TimeoutSeconds / 3)); $i++) {
        Start-Sleep -Seconds 3
        if (Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue) {
            Write-Host ('  ✓ 已就绪（{0} 秒）' -f (($i + 1) * 3)) -ForegroundColor Green
            exit 0
        }
    }
    Write-Host '  ⚠ 超时还没就绪，稍等或用「状态 - 查看」确认。' -ForegroundColor Yellow
    exit 2
}
Write-Host '  已触发启动（约 40~90 秒）。' -ForegroundColor DarkGray
exit 0
