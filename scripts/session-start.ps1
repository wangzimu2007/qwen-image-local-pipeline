# 会话开始：把本地聊天模型收进快照并腾显存，然后按需拉起出图引擎
# 之后连续出图都加 -KeepChatBackend -KeepServer，每张只需几秒；结束跑 session-end.ps1
# 用法：
#   .\session-start.ps1                 # 卸载聊天模型 + 启动 ComfyUI
#   .\session-start.ps1 -NoEngine       # 只卸载，不动引擎
#   .\session-start.ps1 -NeedMB 18000   # 自定义所需显存
param(
    [int]$NeedMB = 14000,
    [int]$TimeoutSec = 150,
    [switch]$NoEngine,
    [switch]$KeepOpen
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\vram.ps1"

$C = Get-PipelineConfig

Write-Head '会话开始'

$state = Start-VramPrep -Config $C -NeedMB $NeedMB -TimeoutSec $TimeoutSec
if (-not $state) { Write-Info '当前没有本地聊天模型占用，无需恢复' }

$free = Get-FreeVramMB
Write-Info ("当前可用显存: {0:N1} GB" -f ($free / 1024))
if ($free -lt 12000) {
    Write-Warn2 ("显存仍偏少（{0:N1} GB），出图可能偏慢" -f ($free / 1024))
    Write-Warn2 '严重不足时：.\vram-check.ps1 -Kill  或关掉占显存的程序'
}

if (-not $NoEngine) {
    $started = Start-ComfyIfNeeded -Config $C
    if ($started) { Write-Ok '出图引擎已就绪' } else { Write-Info '出图引擎已在运行' }
}

Write-Host ''
Write-Ok '会话已就绪。接下来出图请加： -KeepChatBackend -KeepServer'
Write-Ok '结束时跑： scripts\session-end.ps1'
if ($KeepOpen) { Write-Host ''; Write-Host '  按回车关闭窗口…' -ForegroundColor DarkGray; $null = Read-Host }
exit 0
