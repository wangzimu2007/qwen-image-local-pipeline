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
# ---- 显存/占用探针（2026-10-26 增加：测试期间不许提前拉回）----
function Get-GpuUsedMiB {
    try {
        $v = (& nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
        if ($v) { return [int]$v.Trim() }
    } catch { }
    return 0
}

function Test-MediaBusy {
    # ComfyUI / 视频 / 音频等媒体任务在跑 → 别抢显存
    try {
        $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -in @('python.exe','pythonw.exe','ffmpeg.exe') -and $_.CommandLine
        })
        foreach ($p in $procs) {
            if ($p.CommandLine -match 'main\.py|ComfyUI|comfy|demucs|whisper|kokoro|uvr|separation|tts') { return $true }
        }
        if (@($procs | Where-Object { $_.Name -eq 'ffmpeg.exe' }).Count -gt 0) { return $true }
    } catch { }
    return $false
}

function Test-GpuHold {
    # 其他脚本/测试写下的"正在占用 GPU"标记（存在且进程存活才算）
    $f = Join-Path $jobsRoot 'gpu-hold.json'
    if (-not (Test-Path $f)) { return $false }
    try {
        $h = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($h.pid -and (Get-Process -Id ([int]$h.pid) -ErrorAction SilentlyContinue)) { return $true }
        Remove-Item $f -Force -ErrorAction SilentlyContinue
    } catch { }
    return $false
}
function Test-BusyInterpreter {
    # 最近 15 分钟内启动的 python/ffmpeg 才算"测试在跑"；
    # 长期驻留的服务（比如音频工作台常驻进程）不算，否则会永远不恢复。
    $cut = (Get-Date).AddMinutes(-15)
    foreach ($p in @(Get-Process -Name python, pythonw, ffmpeg -ErrorAction SilentlyContinue)) {
        try {
            if ($p.ProcessName -eq 'ffmpeg') { return $true }
            if ($p.StartTime -and $p.StartTime -gt $cut) { return $true }
        } catch { }
    }
    return $false
}

function Test-RecentActivity {
    param([int]$Minutes = 10)
    $dirs = @(
        'C:\Users\wangzimu\Desktop\视频',
        'C:\Users\wangzimu\Desktop\ComfyUI 输出',
        'C:\Users\wangzimu\Desktop\Qwen 图片',
        'D:\audio-tools'
    )
    $cut = (Get-Date).AddMinutes(-$Minutes)
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) { continue }
        try {
            $hit = Get-ChildItem $d -Recurse -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.LastWriteTime -gt $cut } | Select-Object -First 1
            if ($hit) { return $true }
        } catch { }
    }
    return $false
}
function Invoke-BackendKeeper {
    $jobsRoot = 'D:\qwen-image-2.1\.jobs'
    # 媒体/测试正在用 GPU，或别的脚本占了 GPU → 绝不提前拉回
    if (Test-MediaBusy) { return }
    if (Test-GpuHold) { return }
    if ((Get-GpuUsedMiB) -gt 4500) { return }
    if (-not (Get-Command Test-UserStopped -ErrorAction SilentlyContinue)) {
        try { . 'D:\qwen-image-2.1\_backend.ps1' } catch { }
    }
    $wantFile = Join-Path $jobsRoot 'backends-wanted.json'
    # 只认作业守护写下的恢复请求（by=guardian）
    try {
        $wb = Get-Content $wantFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ("$($wb.by)" -ne 'guardian') { return }
    } catch { return }
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
        # 用户手动停过这个后端（12 小时内）→ 绝不自动拉起
        if (Get-Command Test-UserStopped -ErrorAction SilentlyContinue) {
            if (Test-UserStopped -Kind $b.kind -JobsRoot $jobsRoot) { continue }
        } elseif (Test-Path (Join-Path $jobsRoot ('user-stop-' + $b.kind + '.flag'))) { continue }
        # 用真实后端对象（含 startCmd / models）
        # 启动冷却：Strata 启动要 60~90 秒，而 start-iq3s.cmd 开头会 launch --stop；
        # 如果每 30 秒就重复调用，会把"正在启动"的实例杀掉 → 黄红横跳死循环（2026-10-25 踩坑）
        $coolFile = Join-Path $jobsRoot ('keeper-last-start-' + $b.kind + '.txt')
        if (Test-Path $coolFile) {
            try {
                $last = [datetime]::Parse((Get-Content $coolFile -Raw).Trim())
                if (((Get-Date) - $last).TotalSeconds -lt 180) { continue }
            } catch { }
        }
        # 进程已经在（正在加载模型）也不要重复拉起
        if ($b.kind -eq 'strata') {
            if (@(Get-Process -Name strata, strata-vision -ErrorAction SilentlyContinue).Count -gt 0) { continue }
        }
        Set-Content -Path $coolFile -Value (Get-Date).ToString('o') -Encoding UTF8

        $real = Get-LocalBackends | Where-Object { $_.kind -eq $b.kind } | Select-Object -First 1
        if (-not $real) { continue }
        if ($b.models) { $real | Add-Member -NotePropertyName models -NotePropertyValue @($b.models) -Force }
        try {
            if (Start-LocalBackend -backend $real -Reason 'restore') {
                Write-Log ('拉回本地后端 ' + $b.kind + '（: ' + $port + '）')
                $restored++
            }
        } catch { Write-Log ('拉回 ' + $b.kind + ' 失败：' + $_.Exception.Message) }
    }
    return $restored
}

function Invoke-StrataKeeper {
    $jobsRoot = 'D:\qwen-image-2.1\.jobs'
    # 媒体/测试正在用 GPU，或别的脚本占了 GPU → 绝不提前拉回
    if (Test-MediaBusy) { return }
    if (Test-GpuHold) { return }
    if ((Get-GpuUsedMiB) -gt 4500) { return }
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

    # 用户手动停止过 Strata（12 小时内）→ 绝不自动拉起
    if (Get-Command Test-UserStopped -ErrorAction SilentlyContinue) {
        if (Test-UserStopped -Kind 'strata' -JobsRoot $jobsRoot) { return }
    } elseif (Test-Path (Join-Path $jobsRoot 'user-stop-strata.flag')) { return }

    # 已经在加载/运行 → 不要再执行 start-iq3s.cmd（它开头是 launch --stop，会把加载中的实例杀掉）
    if (@(Get-Process -Name strata, strata-vision -ErrorAction SilentlyContinue).Count -gt 0) { return }

    # 180 秒冷却：避免每 30 秒拉一次、每次都打断上一次加载
    $cooldownFile = Join-Path $jobsRoot 'keeper-last-start-strata.txt'
    if (Test-Path $cooldownFile) {
        try {
            if (((Get-Date) - (Get-Item $cooldownFile).LastWriteTime).TotalSeconds -lt 180) { return }
        } catch { }
    }

    # 只在最近 15 分钟内有"卸载过"记录时才管；更早就不打扰（用户可能故意关掉）
    try {
        $w = Get-Content $wantFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ("$($w.by)" -ne 'guardian') { return }   # 只认作业守护写的恢复请求
        $at = [datetime]$w.at
        if (((Get-Date) - $at).TotalMinutes -gt 15) { return }
    } catch { return }

    # 8080 已在听 → 没事做
    if (Test-PortListening -Port 8080) { return }

    # 统一入口 + 自动启动策略（只允许 restore 来源）
    if (-not (Get-Command Start-LocalBackend -ErrorAction SilentlyContinue)) {
        try { . 'D:\qwen-image-2.1\_backend.ps1' } catch { return }
    }
    $real = Get-LocalBackends -Role 'chat' | Where-Object { $_.kind -eq 'strata' } | Select-Object -First 1
    if (-not $real) { return }
    if (Start-LocalBackend -backend $real -Reason 'restore') {
        Set-Content -Path (Join-Path $jobsRoot 'keeper-last-start-strata.txt') -Value (Get-Date).Ticks -Encoding ASCII
        Write-Log '拉回 Strata（作业批末恢复）'
    }
}

# ---- 空闲恢复：测试结束后把本地聊天模型拉回来（2026-10-26 用户要求）----
# 触发条件（全部满足，且连续 2 次检查稳定）：
#   1) 没有排队/执行中的作业，没有 guardian.lock
#   2) 没有媒体任务在跑（ComfyUI / ffmpeg / 音频），没有 gpu-hold 标记
#   3) 显存占用 < 4.5 GB（说明测试真的结束了）
#   4) DSH 当前默认模型是本地 chat 后端，且该后端没有在服务"目标模型"
#   5) 用户没有手动停过该后端
# 恢复方式：有快照就用快照恢复，否则直接拉起后端并加载 DSH 默认模型（Ollama 走 /api/generate keep_alive=-1）
$script:IdleRestoreTicks = 0
function Invoke-IdleRestoreKeeper {
    $jobsRoot = 'D:\qwen-image-2.1\.jobs'
    if (-not (Get-Command Get-LocalBackends -ErrorAction SilentlyContinue)) {
        try { . 'D:\qwen-image-2.1\_backend.ps1' } catch { return }
    }
    # 用户手动暂停自动恢复（测试要长时间占用 GPU）
    if (Test-Path (Join-Path $jobsRoot 'no-auto-restore.flag')) { $script:IdleRestoreTicks = 0; return }
    if (Test-Path (Join-Path $jobsRoot 'guardian.lock')) { $script:IdleRestoreTicks = 0; return }
    foreach ($sub in 'pending', 'running') {
        $dir = Join-Path $jobsRoot $sub
        if (@(Get-ChildItem $dir -File -Filter '*.json' -ErrorAction SilentlyContinue).Count -gt 0) { $script:IdleRestoreTicks = 0; return }
    }
    if (Test-MediaBusy) { $script:IdleRestoreTicks = 0; return }
    if (Test-BusyInterpreter) { $script:IdleRestoreTicks = 0; return }
    if (Test-RecentActivity -Minutes 10) { $script:IdleRestoreTicks = 0; return }
    if (Test-GpuHold) { $script:IdleRestoreTicks = 0; return }
    if ((Get-GpuUsedMiB) -gt 1200) { $script:IdleRestoreTicks = 0; return }

    $dsh = $null
    try { $dsh = Get-DshDefaultModel } catch { return }
    if (-not $dsh -or -not $dsh.provider) { return }
    $kind = $null
    try { $kind = Get-BackendKindFromProvider $dsh.provider } catch { return }
    if (-not $kind) { return }   # 云端会话，不需要本地模型
    try { if (Test-UserStopped -Kind $kind -JobsRoot $jobsRoot) { return } } catch { }

    $b = @(Get-LocalBackends -Role 'chat' | Where-Object { $_.kind -eq $kind } | Select-Object -First 1)
    if ($b.Count -eq 0) { return }
    $b = $b[0]

    # 目标模型是否已经在服务？
    $servesTarget = $false
    foreach ($m in @($b.models)) {
        if ($m -and ($m -eq $dsh.model -or $m -like ('*' + $dsh.model + '*'))) { $servesTarget = $true; break }
    }
    if ($servesTarget) { $script:IdleRestoreTicks = 0; return }

    $script:IdleRestoreTicks++
    if ($script:IdleRestoreTicks -lt 2) { return }

    $cool = Join-Path $jobsRoot 'keeper-last-idle-restore.txt'
    if (Test-Path $cool) {
        try {
            $last = [datetime]::Parse((Get-Content $cool -Raw).Trim())
            if (((Get-Date) - $last).TotalSeconds -lt 900) { return }
        } catch { }
    }
    Set-Content -Path $cool -Value (Get-Date).ToString('o') -Encoding UTF8
    $script:IdleRestoreTicks = 0

    Write-Log ('空闲恢复：' + $kind + ' 未在服务目标模型 ' + $dsh.model + '，开始拉回')

    # 1) 有崩溃/中断留下的快照 → 优先按快照恢复
    $snap = 'D:\qwen-image-2.1\.chat-backend-state.json'
    if (Test-Path $snap) {
        try {
            . 'D:\qwen-image-2.1\_vram.ps1'
            Restore-VramPrep $null
            Write-Log '空闲恢复：已按遗留快照恢复'
            return
        } catch { Write-Log ('空闲恢复：快照恢复失败 ' + $_.Exception.Message) }
    }

    # 2) 直接拉起并加载模型
    try {
        if (-not (Test-PortListening -Port $b.port)) {
            $null = Start-LocalBackend -backend $b -Reason 'restore'
            for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Seconds 3; if (Test-PortListening -Port $b.port) { break } }
        }
        if ($kind -eq 'ollama') {
            $body = @{ model = $dsh.model; prompt = 'hi'; stream = $false; keep_alive = -1; options = @{ num_predict = 1 } } | ConvertTo-Json -Depth 4
            $null = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method POST -Body $body -ContentType 'application/json' -TimeoutSec 300
        }
        Write-Log ('空闲恢复：已加载 ' + $dsh.model)
    } catch {
        Write-Log ('空闲恢复失败：' + $_.Exception.Message)
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
    Invoke-IdleRestoreKeeper
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
