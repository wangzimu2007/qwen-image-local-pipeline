# 桌面小工具守护：ScreenshotHotkey / WindowGuard / BlackDisplay
# 作用：每 30 秒检查一次，进程不在了就重新拉起来，并写日志
# 启动：开机自启（启动文件夹快捷方式「工具守护 - 启动」）；也可手动运行
param(
    [int]$IntervalSeconds = 30,
    [switch]$Once,
    [switch]$Verbose2
)

$ErrorActionPreference = 'Continue'
$dir = 'D:\tools\win-layout'
$logPath = Join-Path $dir 'watchdog.log'

$targets = @(
    @{ Name = 'ScreenshotHotkey'; Exe = (Join-Path $dir 'ScreenshotHotkey.exe'); Args = @(); Desc = 'Ctrl+Alt+Insert 截图' },
    @{ Name = 'WindowGuard';      Exe = (Join-Path $dir 'WindowGuard.exe');      Args = @(); Desc = '窗口移回主屏' },
    @{ Name = 'BlackDisplay';     Exe = (Join-Path $dir 'BlackDisplay.exe');     Args = @(); Desc = '音箱屏黑屏' }
    @{ Name = 'StrataTray';        Exe = (Join-Path $dir 'StrataTray.exe');        Args = @(); Desc = '托盘显示 Strata 状态' }
    @{ Name = 'BlackHotkey';     Exe = (Join-Path $dir 'BlackHotkey.exe');     Args = @(); Desc = 'Ctrl+Alt+Shift+B 启动黑色遮罩' }
)

# 端口型守护：这些是服务端程序，用"端口在不在"判断，掉了就重新拉起
$portTargets = @(
    @{ Name = '思考代理'; Port = 8081; Desc = '8081 → 8080 Strata（关思考，本地模型提速 2~3 倍）'
       Exe = 'D:\deepseek harness\resources\runtime\primary-runtime\dependencies\python\pythonw.exe'
       Args = @('-u', 'D:\qwen-image-2.1\think-off-proxy.py', '--port', '8081', '--log', 'D:\qwen-image-2.1\.think-proxy.log') }
)

function Write-Log {
    param([string]$Text)
    try {
        if ((Test-Path $logPath) -and ((Get-Item $logPath).Length -gt 512KB)) {
            Move-Item $logPath "$logPath.old" -Force -ErrorAction SilentlyContinue
        }
        Add-Content -Path $logPath -Value ("[{0}] {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $Text) -Encoding UTF8
    } catch { }
    if ($Verbose2) { Write-Host ("[" + (Get-Date -Format 'HH:mm:ss') + "] " + $Text) }
}

function Test-PortListening {
    param([int]$Port)
    try {
        $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        return [bool]$c
    } catch { return $false }
}

# ---- Strata 守护：画图任务结束后把它拉回来（只在没有作业在跑时，且 15 分钟窗口内）----
# ---- 通用 Keeper：按 backends-wanted.json 把被卸载的本地后端拉回来 ----
# 支持 Strata / Ollama / NInfer；只在"没有作业在跑 + 15 分钟窗口内"才动手
function Invoke-BackendKeeper {
    $jobsRoot = 'D:\qwen-image-2.1\.jobs'
    $wantFile = Join-Path $jobsRoot 'backends-wanted.json'
    if (-not (Test-Path $wantFile)) { return }

    # 守护正在跑批（含恢复）→ 让路
    $lockFile = Join-Path $jobsRoot 'guardian.lock'
    if (Test-Path $lockFile) {
        try { if (((Get-Date) - (Get-Item $lockFile).LastWriteTime).TotalMinutes -lt 30) { return } } catch { return }
    }
    # 有作业 → 不动
    foreach ($sub in 'pending', 'running') {
        $dir = Join-Path $jobsRoot $sub
        if (Test-Path $dir) {
            if (@(Get-ChildItem $dir -File -Filter '*.json' -ErrorAction SilentlyContinue).Count -gt 0) { return }
        }
    }
    # 15 分钟窗口
    try {
        $w = Get-Content $wantFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (((Get-Date) - [datetime]$w.at).TotalMinutes -gt 15) { return }
    } catch { return }

    if (-not (Get-Command Start-LocalBackend -ErrorAction SilentlyContinue)) {
        . 'D:\qwen-image-2.1\_backend.ps1'
    }

    $restored = 0
    foreach ($b in @($w.backends)) {
        if (-not $b -or -not $b.kind) { continue }
        $port = 0
        switch ($b.kind) { 'strata' { $port = 8080 } 'ollama' { $port = 11434 } 'ninfer' { $port = 8090 } }
        if ($port -le 0) { continue }
        if (Test-PortListening -Port $port) { continue }
        # 用真实后端对象（含 startCmd / models）
        $real = Get-LocalBackends | Where-Object { $_.kind -eq $b.kind } | Select-Object -First 1
        if (-not $real) { continue }
        if ($b.models) { $real | Add-Member -NotePropertyName models -NotePropertyValue @($b.models) -Force }
        try {
            if (Start-LocalBackend -backend $real) {
                Write-Log ('拉回本地后端 ' + $b.kind + '（: ' + $port + '）')
                $restored++
            }
        } catch { Write-Log ('拉回 ' + $b.kind + ' 失败：' + $_.Exception.Message) }
    }
    return $restored
}

function Invoke-StrataKeeper {
    $jobsRoot = 'D:\qwen-image-2.1\.jobs'
    $wantFile = Join-Path $jobsRoot 'strata-wanted.json'
    if (-not (Test-Path $wantFile)) { return }

    # 守护进程正在跑批（含恢复）→ 绝对不动，否则两边会互相打断 Strata 启动
    $lockFile = Join-Path $jobsRoot 'guardian.lock'
    if (Test-Path $lockFile) {
        try {
            $age = ((Get-Date) - (Get-Item $lockFile).LastWriteTime).TotalMinutes
            if ($age -lt 30) { return }
        } catch { return }
    }

    # 有作业在排队/执行 → 绝对不动（会和出图抢显存）
    foreach ($sub in 'pending', 'running') {
        $dir = Join-Path $jobsRoot $sub
        if (Test-Path $dir) {
            $n = @(Get-ChildItem $dir -File -Filter '*.json' -ErrorAction SilentlyContinue).Count
            if ($n -gt 0) { return }
        }
    }

    # 只在最近 15 分钟内有"卸载过"记录时才管；更早就不打扰（用户可能故意关掉）
    try {
        $w = Get-Content $wantFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $at = [datetime]$w.at
        if (((Get-Date) - $at).TotalMinutes -gt 15) { return }
    } catch { return }

    # 8080 已在听 → 没事做
    if (Test-PortListening -Port 8080) { return }

    $startCmd = Join-Path $env:LOCALAPPDATA 'Strata\actions\start-iq3s.cmd'
    if (-not (Test-Path $startCmd)) { return }
    try {
        Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', ('"' + $startCmd + '"')) -WindowStyle Hidden -ErrorAction Stop
        Write-Log '拉回 Strata（画图任务结束后自动恢复）'
    } catch {
        Write-Log ('拉回 Strata 失败：' + $_.Exception.Message)
    }
}

function Invoke-Check {
    foreach ($t in $targets) {
        if (-not (Test-Path $t.Exe)) { continue }
        $proc = Get-Process -Name $t.Name -ErrorAction SilentlyContinue
        if ($proc) { continue }
        try {
            Start-Process -FilePath $t.Exe -WorkingDirectory $dir -WindowStyle Hidden -ErrorAction Stop
            Write-Log ('重启 ' + $t.Name + '（' + $t.Desc + '）')
        } catch {
            Write-Log ('重启失败 ' + $t.Name + '：' + $_.Exception.Message)
        }
    }

    # 端口型：连续 3 次确认端口真的没监听才重启，避免瞬时抖动掐断 DSH 连接
    foreach ($p in $portTargets) {
        if (Test-PortListening -Port $p.Port) { $script:proxyFailures = 0; continue }
        Start-Sleep -Milliseconds 1500
        if (Test-PortListening -Port $p.Port) { $script:proxyFailures = 0; continue }
        $script:proxyFailures++
        if ($script:proxyFailures -lt 3) {
            Write-Log ('端口 {0} 连续 {1}/3 次未监听，暂不重启' -f $p.Port, $script:proxyFailures)
            continue
        }
        if (-not (Test-Path $p.Exe)) { continue }
        try {
            $proc = Start-Process -FilePath $p.Exe -ArgumentList $p.Args -WindowStyle Hidden -PassThru -ErrorAction Stop
            if ($p.Name -eq '思考代理' -and $proc) {
                Set-Content -Path 'D:\qwen-image-2.1\.think-proxy.pid' -Value $proc.Id -Encoding ASCII -ErrorAction SilentlyContinue
            }
            Write-Log ('重启 ' + $p.Name + '（' + $p.Desc + '），PID ' + $proc.Id)
            $script:proxyFailures = 0
        } catch {
            Write-Log ('重启失败 ' + $p.Name + '：' + $_.Exception.Message)
        }
    }

    # 画图任务结束后把 Strata 拉回来（只在没有作业在跑时、且 15 分钟窗口内）
    Invoke-BackendKeeper
    Invoke-StrataKeeper
}

# 单实例：用 PID 文件判断（互斥锁在这个环境不可靠，实测总是报"已存在"）
$pidFile = Join-Path $dir 'watchdog.pid'
$already = $false
if (Test-Path $pidFile) {
    $oldPid = 0
    $txt = (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ([int]::TryParse("$txt".Trim(), [ref]$oldPid) -and $oldPid -gt 0) {
        $proc = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $oldPid) -ErrorAction SilentlyContinue
        if ($proc -and $proc.CommandLine -match 'win-layout\\watchdog\.ps1') { $already = $true }
    }
}
if ($already) {
    Write-Log ('已有一个守护在跑（PID ' + $oldPid + '），本次退出')
    exit 0
}
Set-Content -Path $pidFile -Value $PID -Encoding ASCII

Write-Log '守护启动'
if ($Once) {
    Invoke-Check
    Write-Log '单次检查完成'
    exit 0
}

while ($true) {
    Invoke-Check
    Start-Sleep -Seconds $IntervalSeconds
}
