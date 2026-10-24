# 会话结束：停掉出图引擎，按会话开始时记下的快照恢复本地聊天模型
# 用法：
#   .\session-end.ps1                # 停引擎 + 恢复
#   .\session-end.ps1 -KeepEngine    # 只恢复，不停引擎
#   .\session-end.ps1 -NoRestore     # 只停引擎，不恢复（快照保留）
param(
    [switch]$KeepEngine,
    [switch]$NoRestore,
    [switch]$KeepOpen
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\vram.ps1"

$C = Get-PipelineConfig

Write-Head '会话结束'

if (-not $KeepEngine) {
    $stopped = $false
    if ($C.ComfyStopCmd -and (Test-Path $C.ComfyStopCmd)) {
        Write-Info '关闭出图引擎'
        & $C.ComfyStopCmd
        $stopped = $true
    }
    if (-not $stopped) {
        # 没配停止脚本时，按端口找监听进程结束
        $port = if ($C.ComfyPort) { $C.ComfyPort } else { 8188 }
        $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        foreach ($cx in $conns) {
            $proc = Get-Process -Id $cx.OwningProcess -ErrorAction SilentlyContinue
            if ($proc) {
                Write-Info ('结束引擎进程 {0}（PID {1}，端口 {2}）' -f $proc.ProcessName, $proc.Id, $port)
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Start-Sleep -Seconds 2
}

if (-not $NoRestore) { Restore-VramPrep -Config $C -State $null }
else { Write-Info '按 -NoRestore 跳过恢复（快照文件保留，下次仍会恢复）' }

$free = Get-FreeVramMB
Write-Info ("当前可用显存: {0:N1} GB" -f ($free / 1024))
Write-Ok '会话已结束'
if ($KeepOpen) { Write-Host ''; Write-Host '  按回车关闭窗口…' -ForegroundColor DarkGray; $null = Read-Host }
exit 0
