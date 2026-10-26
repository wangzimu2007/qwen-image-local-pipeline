# 恢复本地模型.ps1 —— 手动控制"测试结束后自动拉回本地聊天模型"
#
# 背景：云端会话跑测试时会把本地聊天模型清掉腾显存。
#   - 测试期间：不能提前拉回（会和测试抢显存）
#   - 测试结束：必须拉回（否则本地会话一直不可用）
# watchdog 里有「空闲恢复」自动处理；本脚本提供手动兜底。
#
# 用法：
#   .\恢复本地模型.ps1 -Status      # 看当前状态与是否被暂停
#   .\恢复本地模型.ps1 -Pause       # 暂停自动恢复（测试要长时间占用 GPU 时用）
#   .\恢复本地模型.ps1 -Resume      # 恢复自动恢复
#   .\恢复本地模型.ps1 -Force       # 立刻拉回（不管空闲判断，测试没在跑时用）
param(
    [switch]$Status,
    [switch]$Pause,
    [switch]$Resume,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
. (Join-Path $here '_backend.ps1')
$jobsRoot = Join-Path $here '.jobs'
$pauseFile = Join-Path $jobsRoot 'no-auto-restore.flag'
$holdFile = Join-Path $jobsRoot 'gpu-hold.json'
$snapFile = Join-Path $here '.chat-backend-state.json'

function Say { param([string]$t, [string]$c = 'Gray') Write-Host ('  ' + $t) -ForegroundColor $c }

function Get-ChatState {
    $dsh = Get-DshDefaultModel
    $kind = if ($dsh) { Get-BackendKindFromProvider $dsh.provider } else { $null }
    $b = $null
    if ($kind) { $b = @(Get-LocalBackends -Role 'chat' | Where-Object { $_.kind -eq $kind } | Select-Object -First 1) }
    if ($b -and $b.Count -gt 0) { $b = $b[0] }
    $serves = $false
    if ($b) { foreach ($m in @($b.models)) { if ($m -and $dsh.model -and ($m -eq $dsh.model -or $m -like ('*' + $dsh.model + '*'))) { $serves = $true } } }
    return [pscustomobject]@{ dsh = $dsh; kind = $kind; backend = $b; serves = $serves }
}

if ($Pause) {
    @{ at = (Get-Date).ToString('o'); by = 'manual' } | ConvertTo-Json -Compress |
        Set-Content -Path $pauseFile -Encoding UTF8
    Say '已暂停「测试结束后自动恢复本地模型」' 'Yellow'
    Say '测试完成后再执行：恢复本地模型.ps1 -Resume（或 -Force 立刻拉回）' 'DarkGray'
    exit 0
}
if ($Resume) {
    if (Test-Path $pauseFile) { Remove-Item $pauseFile -Force -ErrorAction SilentlyContinue }
    Say '已恢复自动恢复（watchdog 空闲判断生效后会拉回）' 'Green'
    exit 0
}

$st = Get-ChatState
Say ''
Say '=== 本地聊天模型状态 ===' 'Cyan'
Say ('  DSH 默认: {0} / {1}' -f $(if ($st.dsh) { $st.dsh.provider } else { '?' }), $(if ($st.dsh) { $st.dsh.model } else { '?' }))
Say ('  后端: {0}（端口 {1}）' -f $(if ($st.backend) { $st.backend.kind } else { '非本地' }), $(if ($st.backend) { $st.backend.port } else { '-' }))
Say ('  已加载目标模型: {0}' -f $(if ($st.serves) { '是（无需恢复）' } else { '否' })) $(if ($st.serves) { 'Green' } else { 'Yellow' })
$gpu = 0
try { $gpu = [int]((& nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null | Select-Object -First 1).Trim()) } catch { }
Say ('  GPU 已用: {0} MiB' -f $gpu)
Say ('  自动恢复: {0}' -f $(if (Test-Path $pauseFile) { '已暂停（-Resume 解除）' } else { '开启（空闲 5 分钟且无活动才拉回）' }))
Say ('  GPU 占用标记: {0}' -f $(if (Test-Path $holdFile) { '存在（有脚本正在用 GPU）' } else { '无' }))
Say ('  遗留快照: {0}' -f $(if (Test-Path $snapFile) { '存在（崩溃/中断遗留，空闲时会按它恢复）' } else { '无' }))
if ($Status -and -not $Force) { Write-Host ''; exit 0 }

if ($Force) {
    Say ''
    Say '=== 立刻拉回（-Force）===' 'Cyan'
    if (-not $st.kind -or -not $st.backend) { Say '  ✗ DSH 当前不是本地 chat 后端，无需恢复' 'Red'; exit 1 }
    # 有遗留快照优先按快照恢复（能还原原模型）
    if (Test-Path $snapFile) {
        try {
            . (Join-Path $here '_vram.ps1')
            Restore-VramPrep $null
            Say '  ✓ 已按遗留快照恢复' 'Green'
            exit 0
        } catch { Say ('  快照恢复失败：' + $_.Exception.Message) 'Yellow' }
    }
    $b = $st.backend
    if (-not (Get-NetTCPConnection -LocalPort $b.port -State Listen -ErrorAction SilentlyContinue)) {
        $null = Start-LocalBackend -backend $b -Reason 'manual'
        for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Seconds 3; if (Get-NetTCPConnection -LocalPort $b.port -State Listen -ErrorAction SilentlyContinue) { break } }
    }
    try {
        if ($st.kind -eq 'ollama') {
            $body = @{ model = $st.dsh.model; prompt = 'hi'; stream = $false; keep_alive = -1; options = @{ num_predict = 1 } } | ConvertTo-Json -Depth 4
            $null = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method POST -Body $body -ContentType 'application/json' -TimeoutSec 300
        }
        Say ('  ✓ 已加载 ' + $st.dsh.model) 'Green'
    } catch { Say ('  ✗ 加载失败：' + $_.Exception.Message) 'Red'; exit 1 }
    exit 0
}

Say ''
Say '  用法：-Status（默认）/ -Pause / -Resume / -Force' 'DarkGray'
Write-Host ''
exit 0
