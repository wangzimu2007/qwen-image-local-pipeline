# 关掉所有 ComfyUI 引擎（桌面版 / 自建版 / 秋叶版），并报告释放的显存
#
# 用途：每次用完 ComfyUI 后调用一次，避免引擎常驻占显存。
# 用法：
#   .\关ComfyUI.ps1            # 关掉全部
#   .\关ComfyUI.ps1 -Quiet     # 不打印过程，只报告结果
param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'

function Write-In { param([string]$t) if (-not $Quiet) { Write-Host ("  " + $t) -ForegroundColor DarkGray } }
function Write-Ok { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Green }

function Get-FreeMiB {
    $raw = ((& nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null) -join '').Trim()
    $v = 0
    if ([int]::TryParse($raw, [ref]$v)) { return $v }
    return -1
}

$before = Get-FreeMiB
Write-Host ''
Write-Host '== 关闭 ComfyUI 引擎 ==' -ForegroundColor Cyan

# 1) 监听 8188 / 8189 的进程
$killed = 0
foreach ($port in 8188, 8189) {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) {
        $procId = $conn.OwningProcess
        $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($p) {
            Write-In ("端口 {0} → {1}（PID {2}），结束进程" -f $port, $p.ProcessName, $procId)
            Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
            $killed++
        }
    }
}

# 2) 兜底：命令行里带 main.py 的 python 进程
Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'main\.py' -and $_.CommandLine -match 'ComfyUI|Comfy-Desktop|aki' } |
    ForEach-Object {
        Write-In ("结束 ComfyUI 进程 PID " + $_.ProcessId)
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        $script:killed++
    }

Start-Sleep -Seconds 3

# 3) 复查
$still = @()
foreach ($port in 8188, 8189) {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) { $still += $port }
}

$after = Get-FreeMiB
if ($still.Count -eq 0) {
    Write-Ok ("ComfyUI 已全部关闭（本次结束 {0} 个进程）" -f $killed)
} else {
    Write-Host ("  ⚠ 端口仍被占用: " + ($still -join ', ')) -ForegroundColor Yellow
}
if ($before -gt 0 -and $after -gt 0) {
    Write-In ('可用显存: {0:N1} GB → {1:N1} GB（回血 {2:N1} GB）' -f ($before/1024), ($after/1024), (($after-$before)/1024))
}
Write-Host ''
exit 0
