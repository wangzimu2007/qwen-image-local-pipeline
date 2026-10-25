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
if ($already) { Write-Log ('已有守护在跑（PID ' + $oldPid + '），本次退出'); exit 0 }
Set-Content -Path $pidFile -Value $PID -Encoding ASCII

Write-Log '守护启动（等待作业）'
$env:PIPE_ALLOW_SELF_UNLOAD = '1'   # 只有本进程允许卸载聊天后端

function Invoke-Job {
    param($job, $jobPath, [switch]$SkipVram)

    $id = $job.id
    $runningPath = Join-Path $runningDir ($id + '.json')
    Move-Item $jobPath $runningPath -Force -ErrorAction SilentlyContinue
    $sw = [Diagnostics.Stopwatch]::StartNew()
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
        $switches = New-Object System.Collections.ArrayList
        Add-SupportedSwitch $switches $sup 'NoPause'
        Add-SupportedSwitch $switches $sup 'NoOpen'
        Add-SupportedSwitch $switches $sup 'NoInfo'
        $runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + @($job.args) + @($switches)
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' @runArgs 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        $text = ($out | ForEach-Object { [string]$_ }) -join "`n"
        [System.IO.File]::WriteAllText($logFile, $text, (New-Object System.Text.UTF8Encoding($false)))

        $m = [regex]::Match($text, '成品[：:]\s*(.+?)(\r?\n|$)')
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
        $sw.Stop()
    }

    $result = [pscustomobject]@{
        id      = $id
        task    = $job.task
        status  = $(if ($product) { 'done' } else { 'failed' })
        product = $product
        error   = $errorText
        seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        log     = $logFile
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
    $state = $null
    try {
        $state = Start-VramPrep -NeedMiB $maxNeed -TimeoutSeconds 180
        $n = 0
        foreach ($job in $jobs) {
            $n++
            Write-Log ('  [' + $n + '/' + $jobs.Count + '] 执行 ' + $job.id)
            Invoke-Job -job $job -jobPath $job._srcPath -SkipVram
        }
    } finally {
        # 批末统一关引擎 + 恢复聊天后端（只做一次）
        $closer = Join-Path $PSScriptRoot '关ComfyUI.ps1'
        if (Test-Path $closer) {
            $ErrorActionPreference = 'Continue'
            & powershell -NoProfile -ExecutionPolicy Bypass -File $closer -Quiet 2>&1 | Out-Null
        }
        if ($state) {
            $ErrorActionPreference = 'Continue'
            try { Restore-VramPrep $state } catch { Write-Log ('批末恢复失败：' + $_.Exception.Message) }
            Write-Log '批末已恢复聊天后端'
        }
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
