# 崩溃自愈.ps1 —— 开机后自动收拾残局（蓝屏/断电/强制重启后使用）
#
# 做四件事：
#   1) 清掉崩溃遗留的锁与 PID 文件（否则守护/看护会互相卡住）
#   2) 把 running\ 里被中断的作业重新排队（默认重排；失败两次以上就标记失败，避免死循环）
#   3) 确保常驻守护进程都在（思考代理 / watchdog / 作业守护）
#   4) 写一条自愈记录到 .jobs\崩溃自愈.log
#
# 用法：
#   .\崩溃自愈.ps1            # 执行
#   .\崩溃自愈.ps1 -DryRun    # 只看会做什么
#   .\崩溃自愈.ps1 -NoDaemon  # 不拉起守护进程
param(
    [switch]$DryRun,
    [switch]$NoDaemon,
    [int]$MaxAttempts = 2
)

$ErrorActionPreference = 'Continue'
$jobsRoot = 'D:\qwen-image-2.1\.jobs'
$logFile = Join-Path $jobsRoot '崩溃自愈.log'
function Log { param([string]$t) $line = ('[{0}] {1}' -f (Get-Date -Format 'MM-dd HH:mm:ss'), $t); Write-Host ('  ' + $t); if (-not $DryRun) { Add-Content -Path $logFile -Value $line -Encoding UTF8 } }
function Say { param([string]$t, [string]$c = 'Gray') Write-Host ('  ' + $t) -ForegroundColor $c }

if (-not (Test-Path $jobsRoot)) { New-Item -ItemType Directory -Force -Path $jobsRoot | Out-Null }
if (-not $DryRun) { Add-Content -Path $logFile -Value ('==== ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' 开机自愈 ====') -Encoding UTF8 }

Say ''
Say ('崩溃自愈' + $(if ($DryRun) { '（演练，不实际改动）' } else { '' })) 'Cyan'
Say ''

# ---- 1) 清理崩溃遗留 ----
Say '[1/4] 清理崩溃遗留的锁与 PID'
$staleFiles = @(
    (Join-Path $jobsRoot 'guardian.lock'),
    (Join-Path $jobsRoot '守护.pid'),
    (Join-Path $jobsRoot '守护.instance.lock'),
    'D:\tools\win-layout\watchdog.pid'
)
foreach ($f in $staleFiles) {
    if (-not (Test-Path $f)) { continue }
    $leaf = Split-Path $f -Leaf
    # PID 文件：如果进程还活着，说明守护在正常运行，不能删
    if ($leaf -match 'pid$') {
        $txt = (Get-Content $f -ErrorAction SilentlyContinue | Select-Object -First 1)
        $live = 0
        if ($txt -and [int]::TryParse(("$txt").Trim(), [ref]$live)) {
            if (Get-Process -Id $live -ErrorAction SilentlyContinue) {
                Say ('  跳过 ' + $leaf + '（PID ' + $live + ' 仍在运行）') 'Yellow'
                continue
            }
        }
    }
    if ($DryRun) { Say ('  将删除 ' + $leaf) 'DarkGray' }
    else {
        Remove-Item $f -Force -ErrorAction SilentlyContinue
        if (Test-Path $f) { Say ('  无法删除 ' + $leaf + '（被占用，可能守护在跑）') 'Yellow' }
        else { Log ('清理 ' + $leaf) }
    }
}
Get-ChildItem $jobsRoot -Filter 'keeper-last-start-*.txt' -ErrorAction SilentlyContinue | ForEach-Object {
    if ($DryRun) { Say ('  将删除 ' + $_.Name) 'DarkGray' }
    else { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue; Log ('清理 ' + $_.Name) }
}
Say '  完成'

# ---- 2) 被中断的作业重新排队 ----
Say ''
Say '[2/4] 处理被中断的作业（running）'
$running = @(Get-ChildItem (Join-Path $jobsRoot 'running') -File -Filter '*.json' -ErrorAction SilentlyContinue)
if ($running.Count -eq 0) { Say '  没有中断的作业' }
foreach ($r in $running) {
    try {
        $j = Get-Content $r.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $attempt = 1
        if ($j.PSObject.Properties.Name -contains 'attempt') { $attempt = [int]$j.attempt + 1 }
        if ($attempt -gt $MaxAttempts) {
            if (-not $DryRun) {
                $j | Add-Member -NotePropertyName status -NotePropertyValue 'failed' -Force
                $j | Add-Member -NotePropertyName error -NotePropertyValue '崩溃中断，重试次数已达上限' -Force
                $j | Add-Member -NotePropertyName attempt -NotePropertyValue $attempt -Force
                $j | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $jobsRoot ('done\' + $r.BaseName + '.json')) -Encoding UTF8
                Remove-Item $r.FullName -Force -ErrorAction SilentlyContinue
                Remove-Item ($r.FullName -replace '\.json$', '.log') -Force -ErrorAction SilentlyContinue
            }
            Log ('作业 ' + $r.BaseName + ' 中断且已重试 ' + ($attempt - 1) + ' 次 → 标记失败')
        } else {
            if (-not $DryRun) {
                $j | Add-Member -NotePropertyName status -NotePropertyValue 'pending' -Force
                $j | Add-Member -NotePropertyName attempt -NotePropertyValue $attempt -Force
                $j | Add-Member -NotePropertyName requeuedAt -NotePropertyValue (Get-Date).ToString('o') -Force
                $j | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $jobsRoot ('pending\' + $r.BaseName + '.json')) -Encoding UTF8
                Remove-Item $r.FullName -Force -ErrorAction SilentlyContinue
                Remove-Item ($r.FullName -replace '\.json$', '.log') -Force -ErrorAction SilentlyContinue
            }
            Log ('作业 ' + $r.BaseName + ' 重新排队（第 ' + $attempt + ' 次尝试）')
        }
    } catch {
        Log ('作业文件 ' + $r.Name + ' 读取失败：' + $_.Exception.Message)
    }
}

# ---- 3) 拉起守护进程 ----
Say ''
Say '[3/4] 确保常驻守护在跑'
if ($NoDaemon) {
    Say '  已跳过（-NoDaemon）'
} else {
    $starter = 'D:\qwen-image-2.1\启动守护.ps1'
    if (Test-Path $starter) {
        if ($DryRun) { Say '  将执行 启动守护.ps1' 'DarkGray' }
        else {
            $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $starter 2>&1
            $out | Where-Object { ([string]$_) -match '启动|已在|跳过' } | Select-Object -First 6 | ForEach-Object { Say ('  ' + ([string]$_).Trim()) }
            Log '已执行 启动守护.ps1'
        }
    } else { Say '  ✗ 找不到 启动守护.ps1' 'Red' }
}

# ---- 4) 汇总 ----
Say ''
Say '[4/4] 现状'
$pending = @(Get-ChildItem (Join-Path $jobsRoot 'pending') -File -Filter '*.json' -ErrorAction SilentlyContinue).Count
$running2 = @(Get-ChildItem (Join-Path $jobsRoot 'running') -File -Filter '*.json' -ErrorAction SilentlyContinue).Count
$flags = @(Get-ChildItem $jobsRoot -File -Filter 'user-stop-*.flag' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
Say ('  队列：排队 {0} / 执行中 {1}' -f $pending, $running2)
Say ('  手动停止标记：' + $(if ($flags.Count) { $flags -join ', ' } else { '无' }))
foreach ($p in 8080, 11434, 8090) {
    $up = $null -ne (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1)
    Say ('  端口 {0}: {1}' -f $p, $(if ($up) { '在' } else { '不在' })) $(if ($up) { 'Green' } else { 'DarkGray' })
}
Say ''
Say ('完成。记录：' + $logFile) 'DarkGray'
Write-Host ''
exit 0
