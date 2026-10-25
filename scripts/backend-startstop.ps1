# 后端启停.ps1 —— 通用启停（按 backends.json 里的 kind）
#
# 用法：
#   .\后端启停.ps1 -List                 # 列出所有已配置后端
#   .\后端启停.ps1 -Kind ollama -Action stop
#   .\后端启停.ps1 -Kind ollama -Action start -Wait
#
# 行为：
#   stop  → 写 user-stop-<kind>.flag（Keeper 之后不再自动拉起）→ 停服务
#   start → 先清标记 → 已在跑/在加载则不重复启动 → 启动 → 可选 -Wait 等端口
param(
    [string]$Kind = '',
    [ValidateSet('start', 'stop')][string]$Action = 'start',
    [switch]$Wait,
    [int]$TimeoutSeconds = 240,
    [switch]$List,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_backend.ps1')
$jobsRoot = 'D:\qwen-image-2.1\.jobs'
if (-not (Test-Path $jobsRoot)) { New-Item -ItemType Directory -Force -Path $jobsRoot | Out-Null }
function Say { param([string]$t, [string]$c = 'Gray') if (-not $Quiet) { Write-Host ('  ' + $t) -ForegroundColor $c } }

$registry = Get-BackendRegistry

if ($List -or -not $Kind) {
    Write-Host ''
    Write-Host '== 已配置的本地后端 ==' -ForegroundColor Cyan
    foreach ($d in $registry) {
        $up = Test-PortListening -Port $d.port
        $stopped = Test-UserStopped -Kind $d.kind -JobsRoot $jobsRoot
        $mark = if ($up) { '● 在监听' } elseif ($stopped) { '○ 已手动停止' } else { '○ 离线' }
        $c = if ($up) { 'Green' } elseif ($stopped) { 'Yellow' } else { 'DarkGray' }
        Write-Host ('  {0,-9} [{1,-5}] :{2,-6} {3,-14} {4}{5}' -f $d.kind, $d.role, $d.port, $d.display, $mark, $(if ($d.enabled) { '' } else { '  [disabled]' })) -ForegroundColor $c
    }
    Write-Host ''
    Write-Host '  用法：后端启停.ps1 -Kind <kind> -Action start|stop [-Wait]'
    Write-Host ''
    if (-not $Kind) { exit 0 }
}

$def = $registry | Where-Object { $_.kind -eq $Kind } | Select-Object -First 1
if (-not $def) {
    Say ('✗ 没有这个后端：' + $Kind) 'Red'
    Say ('已配置：' + (($registry | ForEach-Object { $_.kind }) -join ', ')) 'DarkGray'
    exit 1
}

$backend = Get-LocalBackends | Where-Object { $_.kind -eq $Kind } | Select-Object -First 1
if (-not $backend) {
    # enabled=false 的情况下也允许启停（构造最小对象）
    $backend = [pscustomobject]@{
        kind = $def.kind; display = $def.display; port = $def.port; api = $def.api
        startCmd = (Expand-BackendPath $def.startCmd); stopCmd = (Expand-BackendPath $def.stopCmd)
        startExe = (Expand-BackendPath $def.startExe); startVbs = (Expand-BackendPath $def.startVbs)
        stopPs = (Expand-BackendPath $def.stopPs); stopProcs = @($def.stopProcs); procs = @($def.procs)
    }
}

$isChat = ($def.role -ne 'media')

if ($Action -eq 'stop') {
    if ($isChat) {
        $p = Set-UserStopFlag -Kind $Kind -JobsRoot $jobsRoot
        Say ('已记录手动停止标记：' + (Split-Path $p -Leaf)) 'DarkGray'
    } else {
        Say '媒体类引擎：按需启停，不写手动停止标记（不参与保活）' 'DarkGray'
    }
    $did = Stop-LocalBackend -backend $backend
    if (-not $did) { Say '⚠ 没有可用的停止方式（配置里 stopCmd/stopPs/stopProcs 都为空）' 'Yellow' }

    $gone = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        if (-not (Test-PortListening -Port $backend.port)) { $gone = $true; break }
    }
    if ($gone) { Say ('✓ ' + $Kind + ' 已停止，并且不会自动拉回来（直到你点「' + $def.display + ' - 启动」）') 'Green' }
    else { Say ('⚠ 端口 ' + $backend.port + ' 仍在监听，可能没停干净') 'Yellow' }

    foreach ($fn in 'strata-wanted.json', 'backends-wanted.json') {
        $q = Join-Path $jobsRoot $fn
        if (Test-Path $q) { Remove-Item $q -Force -ErrorAction SilentlyContinue }
    }
    Write-Host ''
    exit 0
}

# ---- start ----
if ($isChat) {
    Clear-UserStopFlag -Kind $Kind -JobsRoot $jobsRoot
    Say '已清除「手动停止」标记，守护可以自动拉回了。' 'DarkGray'
} else {
    Say '媒体类引擎：直接启动（不涉及保活标记）' 'DarkGray'
}

if (Test-PortListening -Port $backend.port) {
    Say ($Kind + ' 已经在运行（端口 ' + $backend.port + ' 在监听），无需重复启动。') 'Green'
    exit 0
}
$ok = Start-LocalBackend -backend $backend
if (-not $ok) {
    Say ('端口 ' + $backend.port + ' 尚未就绪（可能进程已在加载，或该后端没有配置启动方式）。') 'Yellow'
}

if ($Wait) {
    Say '等待就绪…' 'DarkGray'
    for ($i = 0; $i -lt [Math]::Max(1, [int]($TimeoutSeconds / 3)); $i++) {
        Start-Sleep -Seconds 3
        if (Test-PortListening -Port $backend.port) { Say ('✓ 已就绪（{0} 秒）' -f (($i + 1) * 3)) 'Green'; exit 0 }
    }
    Say '⚠ 超时还没就绪' 'Yellow'
    exit 2
}
Say '已触发启动。' 'DarkGray'
exit 0
