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
    param($job, $jobPath)

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
        # 1) 快照 + 卸载聊天后端
        $state = Start-VramPrep -NeedMiB ([int]$job.needMiB) -TimeoutSeconds 180

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

        # 3) 关掉本次可能残留的引擎
        $closer = Join-Path $PSScriptRoot '关ComfyUI.ps1'
        if (Test-Path $closer) {
            $ErrorActionPreference = 'Continue'
            & powershell -NoProfile -ExecutionPolicy Bypass -File $closer -Quiet 2>&1 | Out-Null
        }
    } catch {
        $errorText = $_.Exception.Message
    } finally {
        # 4) 恢复聊天后端（无论成功失败）
        if ($state) {
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

    if ($result.status -eq 'done') {
        Write-Log ('完成作业 ' + $id + '：' + $product + '（' + $result.seconds + ' 秒）')
    } else {
        Write-Log ('作业失败 ' + $id + '：' + $errorText)
    }
}

function Invoke-Round {
    $files = @(Get-ChildItem $pendingDir -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    foreach ($f in $files) {
        try {
            $job = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $job.script) { $job.script = 'Z画图.ps1' }
            if (-not $job.id) { $job.id = $f.BaseName }
            Invoke-Job -job $job -jobPath $f.FullName
        } catch {
            Write-Log ('作业读取失败 ' + $f.Name + '：' + $_.Exception.Message)
            Move-Item $f.FullName (Join-Path $doneDir ($f.BaseName + '.bad.json')) -Force -ErrorAction SilentlyContinue
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
