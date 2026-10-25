# 看状态：一眼判断 Strata 是「离线 / 恢复中 / 就绪」以及有没有出图任务在跑
#
# 用法：
#   .\看状态.ps1              # 打印一次
#   .\看状态.ps1 -Watch       # 每 3 秒刷新，直到就绪（Ctrl+C 退出）
#   .\看状态.ps1 -Json        # 机器可读
param(
    [switch]$Watch,
    [switch]$Json
)

$ErrorActionPreference = 'Continue'
$jobsRoot = 'D:\qwen-image-2.1\.jobs'
$lockFile = Join-Path $jobsRoot 'guardian.lock'

function Get-FreeMiB {
    $raw = ((& nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null) -join '').Trim()
    $v = 0
    if ([int]::TryParse($raw, [ref]$v)) { return $v } else { return -1 }
}
function Get-UsedMiB {
    $raw = ((& nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null) -join '').Trim()
    $v = 0
    if ([int]::TryParse($raw, [ref]$v)) { return $v } else { return -1 }
}
function Test-Port { param($p) [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1) }

function Get-State {
    $pending = @(Get-ChildItem (Join-Path $jobsRoot 'pending') -File -Filter '*.json' -ErrorAction SilentlyContinue).Count
    $running = @(Get-ChildItem (Join-Path $jobsRoot 'running') -File -Filter '*.json' -ErrorAction SilentlyContinue).Count
    $hasLock = Test-Path $lockFile
    $port8080 = Test-Port 8080
    $port8081 = Test-Port 8081
    $strataProc = @(Get-Process -Name strata, strata-vision -ErrorAction SilentlyContinue).Count
    $gpuUsed = Get-UsedMiB
    $gpuFree = Get-FreeMiB

    # 模型真的能答话吗（1 秒超时，不阻塞）
    $serving = $false
    if ($port8080) {
        try {
            $null = Invoke-RestMethod 'http://127.0.0.1:8080/v1/models' -TimeoutSec 2
            $serving = $true
        } catch { $serving = $false }
    }

    $state = '离线'
    $advice = ''
    $color = 'Red'

    if ($running -gt 0 -or $pending -gt 0) {
        $state = '出图中'
        $color = 'Cyan'
        $advice = if ($running -gt 0) { "任务执行中，另有 $pending 个排队" } else { "$pending 个作业排队等守护执行" }
    }
    elseif ($hasLock) {
        $state = '恢复中'
        $color = 'Yellow'
        $age = -1
        try { $age = [math]::Round(((Get-Date) - (Get-Item $lockFile).LastWriteTime).TotalSeconds, 0) } catch { }
        $advice = "守护正在卸载/恢复，已进行 ${age} 秒；约 45~70 秒后完成，稍等再发消息"
    }
    elseif ($serving) {
        $state = '就绪'
        $color = 'Green'
        $advice = '本地模型可用，可以直接对话'
    }
    elseif ($strataProc -gt 0 -or $port8080) {
        $state = '启动中'
        $color = 'Yellow'
        $advice = 'Strata 正在加载模型（约 40~90 秒），再等一会儿'
    }
    else {
        $state = '离线'
        $color = 'Red'
        $advice = 'Strata 没在跑：双击「Strata IQ3_S - 启动」，或双击「守护 - 全部启动」'
    }

    [pscustomobject]@{
        state      = $state
        color      = $color
        advice     = $advice
        pending    = $pending
        running    = $running
        lock       = $hasLock
        port8080   = $port8080
        port8081   = $port8081
        serving    = $serving
        strataProc = $strataProc
        gpuUsedGB  = if ($gpuUsed -ge 0) { [math]::Round($gpuUsed / 1024, 1) } else { -1 }
        gpuFreeGB  = if ($gpuFree -ge 0) { [math]::Round($gpuFree / 1024, 1) } else { -1 }
        at         = (Get-Date).ToString('HH:mm:ss')
    }
}

if ($Json) {
    Get-State | ConvertTo-Json -Depth 4
    exit 0
}

function Show-State {
    $s = Get-State
    $icon = switch ($s.state) {
        '就绪' { '●' }
        '出图中' { '▶' }
        '恢复中' { '↻' }
        '启动中' { '↻' }
        default { '○' }
    }
    Write-Host ''
    Write-Host ('  {0} ' -f $icon) -NoNewline -ForegroundColor $s.color
    Write-Host ('{0}' -f $s.state) -ForegroundColor $s.color -NoNewline
    Write-Host ('   （{0}）' -f $s.at) -ForegroundColor DarkGray
    Write-Host ('  ' + $s.advice) -ForegroundColor Gray
    Write-Host ''
    Write-Host '  ── 明细 ──────────────────────────' -ForegroundColor DarkGray
    Write-Host ('  Strata 8080 : {0}   代理 8081 : {1}' -f
        $(if ($s.port8080) { '在' } else { '不在' }),
        $(if ($s.port8081) { '在' } else { '不在' })) -ForegroundColor DarkGray
    Write-Host ('  队列        : 执行中 {0} / 排队 {1}   守护锁: {2}' -f
        $s.running, $s.pending, $(if ($s.lock) { '持有（正在跑批）' } else { '无' })) -ForegroundColor DarkGray
    Write-Host ('  显存        : 已用 {0} GB / 可用 {1} GB   strata 进程数 {2}' -f
        $s.gpuUsedGB, $s.gpuFreeGB, $s.strataProc) -ForegroundColor DarkGray

    # 最近一次批次结果
    $log = Join-Path $jobsRoot '守护.log'
    if (Test-Path $log) {
        $tail = Get-Content $log -Tail 4 -Encoding UTF8 -ErrorAction SilentlyContinue
        Write-Host '  ── 守护最近动作 ─────────────────' -ForegroundColor DarkGray
        $tail | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor DarkGray }
    }
    Write-Host ''
    return $s
}

if ($Watch) {
    $last = ''
    while ($true) {
        $s = Get-State
        if ($s.state -ne $last) {
            [Console]::Clear()
            Write-Host ('  监视中（每 3 秒刷新，Ctrl+C 退出）')
            $null = Show-State
            $last = $s.state
        }
        if ($s.state -eq '就绪') { break }
        Start-Sleep -Seconds 3
    }
    exit 0
}

$null = Show-State
exit 0
