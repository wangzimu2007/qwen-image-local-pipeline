# 看状态：自动识别当前用哪个本地后端（Strata / Ollama / NInfer），显示 离线/启动中/恢复中/出图中/就绪
#
# 用法：
#   .\看状态.ps1            # 打印一次
#   .\看状态.ps1 -Watch     # 每 3 秒刷新，直到就绪
#   .\看状态.ps1 -Json      # 机器可读（托盘用它）
param(
    [switch]$Watch,
    [switch]$Json
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_backend.ps1')

if ($Json) {
    Get-OverallState | ConvertTo-Json -Depth 5
    exit 0
}

function Show-State {
    $o = Get-OverallState
    $color = switch ($o.state) {
        '就绪'   { 'Green' }
        '出图中' { 'Cyan' }
        '恢复中' { 'Yellow' }
        '启动中' { 'Yellow' }
        default  { 'Red' }
    }
    $icon = switch ($o.state) {
        '就绪' { '●' } '出图中' { '▶' } '恢复中' { '↻' } '启动中' { '↻' } default { '○' }
    }

    Write-Host ''
    Write-Host ('  {0} ' -f $icon) -NoNewline -ForegroundColor $color
    Write-Host ('{0}' -f $o.state) -ForegroundColor $color -NoNewline
    Write-Host ('   （{0}）' -f $o.at) -ForegroundColor DarkGray
    Write-Host ('  ' + $o.detail) -ForegroundColor Gray
    Write-Host ''
    Write-Host '  ── 本地后端 ──────────────────────────────' -ForegroundColor DarkGray
    foreach ($b in $o.backends) {
        $mark = if ($b.serving) { '● 服务中' } elseif ($b.up) { '◐ 端口在' } elseif ($b.procs -gt 0) { '◐ 进程在' } else { '○ 离线' }
        $c = if ($b.serving) { 'Green' } elseif ($b.up -or $b.procs -gt 0) { 'Yellow' } else { 'DarkGray' }
        $active = if ($b.kind -eq $o.activeKind) { '  ← DSH 当前' } else { '' }
        Write-Host ('  {0,-8} :{1,-6} {2,-8} {3}{4}' -f $b.kind, $b.port, $mark, (($b.models) -join ','), $active) -ForegroundColor $c
    }
    Write-Host ''
    Write-Host ('  DSH 默认: {0} / {1}' -f $o.activeProvider, $o.activeModel) -ForegroundColor DarkGray
    Write-Host ('  队列: 执行中 {0} / 排队 {1}    守护锁: {2}' -f $o.running, $o.pending, $(if ($o.lock) { '持有（正在跑批）' } else { '无' })) -ForegroundColor DarkGray

    $log = 'D:\qwen-image-2.1\.jobs\守护.log'
    if (Test-Path $log) {
        Write-Host '  ── 守护最近动作 ─────────────────────────' -ForegroundColor DarkGray
        Get-Content $log -Tail 3 -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor DarkGray }
    }
    Write-Host ''
    return $o
}

if ($Watch) {
    $last = ''
    while ($true) {
        $o = Get-OverallState
        if ($o.state -ne $last) {
            [Console]::Clear()
            Write-Host '  监视中（每 3 秒刷新，Ctrl+C 退出）'
            $null = Show-State
            $last = $o.state
        }
        if ($o.state -eq '就绪') { break }
        Start-Sleep -Seconds 3
    }
    exit 0
}

$null = Show-State
exit 0
