# 作业守护：把"卸载聊天模型 → 出图 → 恢复聊天模型"交给独立进程执行
#
# 为什么需要它：
#   本地聊天模型自己不能卸载自己（会断线）。本进程由用户/开机启动，独立于对话，
#   监听 .jobs\pending\*.json，负责：快照聊天后端 → 卸载 → 跑出图脚本 → 停引擎 → 恢复聊天后端 → 写结果。
#
# 启动：
#   双击桌面「作业守护 - 启动」（开机自启在启动文件夹）
#   或手动：powershell -NoProfile -ExecutionPolicy Bypass -File D:\qwen-image-2.1\作业守护.ps1
#
# 调试：
#   .\作业守护.ps1 -Once        # 只处理一轮就退出
#   .\作业守护.ps1 -IntervalSec 5
param(
    [int]$IntervalSec = 3,
    [switch]$Once,
    [switch]$Verbose2
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_vram.ps1')

# 读取脚本支持的参数名，避免给不支持 -NoPause / -KeepChatBackend 的脚本传错参数
function Get-ScriptParamSet {
    param([string]$path)
    $set = @{}
    try {
        $errs = $null; $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errs)
        if ($ast.ParamBlock) {
            foreach ($p in $ast.ParamBlock.Parameters) { $set[$p.Name.VariablePath.UserPath.ToLower()] = $true }
        }
    } catch { }
    return $set
}

# ---- 补丁点：参数过滤 ----
function Add-SupportedSwitch {
    param([System.Collections.ArrayList]$list, $supported, [string]$name)
    if ($supported.ContainsKey($name.ToLower())) { [void]$list.Add('-' + $name) }
}

$jobsRoot = Join-Path $PSScriptRoot '.jobs'
$pendingDir = Join-Path $jobsRoot 'pending'
$doneDir = Join-Path $jobsRoot 'done'
$runningDir = Join-Path $jobsRoot 'running'
$logPath = Join-Path $jobsRoot '守护.log'
$lockFile = Join-Path $jobsRoot 'guardian.lock'
$pidFile = Join-Path $jobsRoot '守护.pid'
foreach ($d in @($jobsRoot, $pendingDir, $doneDir, $runningDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

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

# ---- 单实例（PID 文件）----
$already = $false
if (Test-Path $pidFile) {
    $oldPid = 0
    $txt = (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ([int]::TryParse("$txt".Trim(), [ref]$oldPid) -and $oldPid -gt 0) {
        $proc = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $oldPid) -ErrorAction SilentlyContinue
        if ($proc -and $proc.CommandLine -match '作业守护\.ps1') { $already = $true }
    }
}
# 单实例：文件独占锁（比扫描进程可靠，不会把自己/残留进程算成"已有实例"）
$lockPath = Join-Path $jobsRoot '守护.instance.lock'
try {
    $script:InstanceLock = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
    Write-Log '另一个守护实例正持有锁，本次退出'
    exit 0
}
if ($already) { Write-Log ('已有守护在跑（PID ' + $oldPid + '），本次退出'); exit 0 }
Set-Content -Path $pidFile -Value $PID -Encoding ASCII

Write-Log '守护启动（等待作业）'
$env:PIPE_ALLOW_SELF_UNLOAD = '1'   # 只有本进程允许卸载聊天后端

function Invoke-Job {
    param($job, $jobPath, [switch]$SkipVram)

    $id = $job.id
    $runningPath = Join-Path $runningDir ($id + '.json')
    Move-Item $jobPath $runningPath -Force -ErrorAction SilentlyContinue
    $swJob = [Diagnostics.Stopwatch]::StartNew()
    $state = $null
    $product = ''
    $errorText = ''
    $logFile = Join-Path $runningDir ($id + '.log')

    Write-Log ('开始作业 ' + $id + '（' + $job.task + '，需要 ' + $job.needMiB + ' MiB）')

    try {
        # 1) 快照 + 卸载聊天后端（批量模式下由调用方统一做，这里跳过）
        if (-not $SkipVram) {
            $state = Start-VramPrep -NeedMiB ([int]$job.needMiB) -TimeoutSeconds 180
        }

        # 2) 跑目标脚本
        $scriptPath = Join-Path $PSScriptRoot $job.script
        if (-not (Test-Path $scriptPath)) { throw ('找不到脚本 ' + $job.script) }
        $sup = Get-ScriptParamSet $scriptPath
        # 去重：作业参数里已经带了的开关不要再加（否则 "参数被指定了多次"）
        $argSet = @{}
        foreach ($a in @($job.args)) {
            if ($a -like '-*') { $argSet[$a.ToLower()] = $true }
        }
        $switches = New-Object System.Collections.ArrayList
        foreach ($swName in 'KeepChatBackend', 'NoPause', 'NoOpen', 'NoInfo') {
            if ($argSet.ContainsKey(('-' + $swName).ToLower())) { continue }
            Add-SupportedSwitch $switches $sup $swName
        }
        $runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + @($job.args) + @($switches)
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' @runArgs 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        $text = ($out | ForEach-Object { [string]$_ }) -join "`n"
        [System.IO.File]::WriteAllText($logFile, $text, (New-Object System.Text.UTF8Encoding($false)))

        # 不同脚本打印的标签不一样：成品：/ 编辑完成：/ 超分完成：/ 视频完成：/ 输出：
        $reProd = '(?:成品|编辑完成|超分完成|视频完成|音频完成|输出文件)[：:]\s*(.+?\.(?:png|jpg|jpeg|webp|mp4|mov|srt|wav|mp3))'
        $m = [regex]::Match($text, $reProd, 'IgnoreCase')
        if ($m.Success) { $product = ($m.Groups[1].Value -split '\s{2,}')[0].Trim() }
        if ($code -ne 0 -or -not $product) {
            $tail = ($text -split "`n" | Select-Object -Last 6) -join ' / '
            throw ('脚本失败（退出码 ' + $code + '）：' + $tail)
        }

        # 3) 非批量模式才在这里单独关引擎（批量模式由批末统一关）
        if (-not $SkipVram) {
            $closer = Join-Path $PSScriptRoot '关ComfyUI.ps1'
            if (Test-Path $closer) {
                $ErrorActionPreference = 'Continue'
                & powershell -NoProfile -ExecutionPolicy Bypass -File $closer -Quiet 2>&1 | Out-Null
            }
        }
    } catch {
        $errorText = $_.Exception.Message
    } finally {
        # 4) 恢复聊天后端（批量模式下由调用方统一恢复）
        if ($state -and -not $SkipVram) {
            $ErrorActionPreference = 'Continue'
            try { Restore-VramPrep $state } catch { Write-Log ('恢复失败：' + $_.Exception.Message) }
        }
        $swJob.Stop()
    }

    $result = [pscustomobject]@{
        id      = $id
        task    = $job.task
        status  = $(if ($product) { 'done' } else { 'failed' })
        product = $product
        error   = $errorText
        seconds = [math]::Round($swJob.Elapsed.TotalSeconds, 1)
        log     = $logFile
        seed    = [string]$(if ($job.seed) { $job.seed } else { '' })
        finished = (Get-Date).ToString('o')
    }
    $donePath = Join-Path $doneDir ($id + '.json')
    $result | ConvertTo-Json -Depth 6 | Set-Content -Path $donePath -Encoding UTF8
    Remove-Item $runningPath -Force -ErrorAction SilentlyContinue
    # 日志归档到 done，避免 running 目录堆残留
    if (Test-Path $logFile) { Move-Item $logFile (Join-Path $doneDir ($id + '.log')) -Force -ErrorAction SilentlyContinue }

    if ($result.status -eq 'done') {
        Write-Log ('完成作业 ' + $id + '：' + $product + '（' + $result.seconds + ' 秒）')
    } else {
        Write-Log ('作业失败 ' + $id + '：' + $errorText)
    }
}

function Invoke-Round {
    $files = @(Get-ChildItem $pendingDir -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    if ($files.Count -eq 0) { return }

    # 收集窗口：一次提交多张时，文件之间只差几十毫秒；等 4 秒再扫一遍，
    # 把它们合并成同一批（只卸载/恢复一次）。2026-10-25 实测：不等会拆成两批。
    Start-Sleep -Seconds 4
    $files = @(Get-ChildItem $pendingDir -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    if ($files.Count -eq 0) { return }

    # ---- 批量模式：整批只卸载一次、恢复一次（省掉 N-1 次 60 秒的 Strata 重启）----
    $jobs = @()
    foreach ($f in $files) {
        try {
            $job = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $job.script) { $job.script = 'Z画图.ps1' }
            if (-not $job.id) { $job.id = $f.BaseName }
            $job | Add-Member -NotePropertyName '_srcPath' -NotePropertyValue $f.FullName -Force
            $jobs += $job
        } catch {
            Write-Log ('作业读取失败 ' + $f.Name + '：' + $_.Exception.Message)
            Move-Item $f.FullName (Join-Path $doneDir ($f.BaseName + '.bad.json')) -Force -ErrorAction SilentlyContinue
        }
    }
    if ($jobs.Count -eq 0) { return }

    $maxNeed = 0
    foreach ($j in $jobs) { if ([int]$j.needMiB -gt $maxNeed) { $maxNeed = [int]$j.needMiB } }
    if ($maxNeed -le 0) { $maxNeed = 14000 }

    Write-Log ('本批 ' + $jobs.Count + ' 个作业，一次性卸载（需要 ' + $maxNeed + ' MiB）')
    $m0 = Get-MemStat
    if ($m0) { Write-Log ('  批前 ' + (Format-MemStat $m0) + ' / 显存可用 ' + [math]::Round((Get-FreeVramMiB)/1024,1) + ' GB') }
    # 互斥锁：告诉 watchdog 的 Keeper「守护正在忙，别插手」
    try { Set-Content -Path $lockFile -Value $PID -Encoding ASCII } catch { }
    $swBatch = [Diagnostics.Stopwatch]::StartNew()
    $state = $null
    try {
        $swUnload = [Diagnostics.Stopwatch]::StartNew()
        $state = Start-VramPrep -NeedMiB $maxNeed -TimeoutSeconds 180
        $swUnload.Stop()
        $m1 = Get-MemStat
        Write-Log ('  卸载完成 {0:N1} 秒；{1} / 显存可用 {2:N1} GB' -f $swUnload.Elapsed.TotalSeconds, (Format-MemStat $m1), ((Get-FreeVramMiB)/1024))
        $n = 0
        foreach ($job in $jobs) {
            $n++
            Write-Log ('  [' + $n + '/' + $jobs.Count + '] 执行 ' + $job.id)
            # 单个作业出错不能拖垮整批（否则后面的作业会一直卡在 pending）
            try {
                Invoke-Job -job $job -jobPath $job._srcPath -SkipVram
            } catch {
                $emsg = $_.Exception.Message
                Write-Log ('  作业 ' + $job.id + ' 抛异常：' + $emsg)
                try {
                    $res = [pscustomobject]@{
                        id = $job.id; task = $job.task; status = 'failed'
                        product = ''; error = ('异常：' + $emsg); seconds = 0
                        log = ''; finished = (Get-Date).ToString('o')
                    }
                    $res | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $doneDir ($job.id + '.json')) -Encoding UTF8
                    Remove-Item (Join-Path $runningDir ($job.id + '.json')) -Force -ErrorAction SilentlyContinue
                    Remove-Item $job._srcPath -Force -ErrorAction SilentlyContinue
                } catch { }
            }
        }
    } finally {
        # 批末统一关引擎 + 恢复聊天后端（只做一次）
        $closer = Join-Path $PSScriptRoot '关ComfyUI.ps1'
        if (Test-Path $closer) {
            $ErrorActionPreference = 'Continue'
            & powershell -NoProfile -ExecutionPolicy Bypass -File $closer -Quiet 2>&1 | Out-Null
        }
        # 用户在批次期间手动点了「停止 Strata」→ 尊重意图，不再恢复
        # 按后端过滤：用户手动停掉的后端不恢复，其他后端照常恢复
        if ($state -and $state.backends) {
            $keep = @()
            foreach ($bk in @($state.backends)) {
                if (-not $bk) { continue }
                $stopped = $false
                if (Get-Command Test-UserStopped -ErrorAction SilentlyContinue) {
                    $stopped = Test-UserStopped -Kind $bk.kind -JobsRoot $jobsRoot
                } elseif (Test-Path (Join-Path $jobsRoot ('user-stop-' + $bk.kind + '.flag'))) { $stopped = $true }
                if ($stopped) { Write-Log ('  用户已手动停止 ' + $bk.kind + ' → 跳过其恢复') }
                else { $keep += $bk }
            }
            if ($keep.Count -eq 0) {
                Write-Log '所有后端都被用户手动停过 → 本批不做恢复'
                $state = $null
            } else {
                $state.backends = $keep
            }
        }
        if ($state) {
            $ErrorActionPreference = 'Continue'
            $swRestore = [Diagnostics.Stopwatch]::StartNew()
            try { Restore-VramPrep $state } catch { Write-Log ('批末恢复失败：' + $_.Exception.Message) }
            # 记录"本批卸载过聊天后端" → watchdog 的 Strata 守护会据此在需要时拉回来
            try {
                $want = @{ want = $true; at = (Get-Date).ToString('o') }
                $want | ConvertTo-Json -Compress | Set-Content -Path (Join-Path $jobsRoot 'strata-wanted.json') -Encoding UTF8
                # 通用版：记录被卸载过的后端列表，供 Keeper 自动识别并拉回
                $bl = @()
                if ($state -and $state.backends) { $bl = @($state.backends) }
                $rec = @{ at = (Get-Date).ToString('o'); backends = $bl }
                $rec | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $jobsRoot 'backends-wanted.json') -Encoding UTF8
            } catch { }
            $swRestore.Stop()
            # 二次校验：按"本批恢复的后端"逐个检查端口（不要硬编码 8080！）
            foreach ($bk in @($state.backends)) {
                if (-not $bk) { continue }
                $bport = 0
                switch ($bk.kind) { 'strata' { $bport = 8080 } 'ollama' { $bport = 11434 } 'ninfer' { $bport = 8090 } }
                if ($bport -le 0) { continue }
                if (Get-NetTCPConnection -LocalPort $bport -State Listen -ErrorAction SilentlyContinue) { continue }
                Write-Log ('  ' + $bk.kind + ' 端口 ' + $bport + ' 未就绪，二次拉起…')
                try {
                    if (-not (Get-Command Start-LocalBackend -ErrorAction SilentlyContinue)) { . 'D:\qwen-image-2.1\_backend.ps1' }
                    $real = Get-LocalBackends -Role 'chat' | Where-Object { $_.kind -eq $bk.kind } | Select-Object -First 1
                    if ($real) { Start-LocalBackend -backend $real | Out-Null }
                } catch { }
                for ($w = 0; $w -lt 60; $w++) {
                    Start-Sleep -Seconds 3
                    if (Get-NetTCPConnection -LocalPort $bport -State Listen -ErrorAction SilentlyContinue) { Write-Log ('  ' + $bk.kind + ' 二次拉起成功'); break }
                }
            }
            $m2 = Get-MemStat
            Write-Log ('  恢复完成 {0:N1} 秒；{1} / 显存可用 {2:N1} GB' -f $swRestore.Elapsed.TotalSeconds, (Format-MemStat $m2), ((Get-FreeVramMiB)/1024))
        }
        $swBatch.Stop()
        Write-Log ('本批结束，总耗时 {0:N1} 秒' -f $swBatch.Elapsed.TotalSeconds)
        try { Remove-Item $lockFile -Force -ErrorAction SilentlyContinue } catch { }
    }
}

if ($Once) {
    Invoke-Round
    Write-Log '单轮结束'
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    exit 0
}

while ($true) {
    Invoke-Round
    Start-Sleep -Seconds $IntervalSec
}
