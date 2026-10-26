# 一键停止卡死的本地模型（llama-server 卡在无限生成 / 卸不掉时用）
# 作用：中断生成 → 卸载 Ollama 模型 → 报显存回血情况
# 用法：
#   .\停止卡死.ps1
#   .\停止卡死.ps1 -KeepOpen     # 跑完等回车（双击快捷方式用）
param(
    [switch]$KeepModel,   # 只中断生成，不卸载模型
    [switch]$KeepOffline,   # 重启服务后不自动拉起 Ollama
    [switch]$KeepOpen
)

$ErrorActionPreference = 'Continue'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-H { param([string]$t) Write-Host ''; Write-Host ("== " + $t + " ==") -ForegroundColor Cyan }
function Write-Ok { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Green }
function Write-In { param([string]$t) Write-Host ("  " + $t) -ForegroundColor DarkGray }
function Write-Warn { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Yellow }

function Get-FreeMiB {
    $raw = ((& nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null) -join '').Trim()
    $v = 0
    if ([int]::TryParse($raw, [ref]$v)) { return $v }
    return -1
}

Write-H '停止卡死的本地模型'
$freeBefore = Get-FreeMiB
Write-In ('当前可用显存: {0:N1} GB' -f ($freeBefore / 1024))

# 1. 看是不是真在生成（读 Ollama 日志的 n_gen）
$log = Join-Path $env:LOCALAPPDATA 'Ollama\server.log'
$gen = $null
if (Test-Path $log) {
    $tail = Get-Content $log -Tail 40 -ErrorAction SilentlyContinue | Where-Object { $_ -match 'n_gen\s*=\s*(\d+)' }
    if ($tail) {
        $lastLine = @($tail)[-1]
        if ($lastLine -match 'n_gen\s*=\s*(\d+)') { $gen = [int]$Matches[1] }
    }
}
if ($gen) { Write-Warn ('日志显示最近生成到 {0} 个 token（如果还在涨，就是在空转）' -f $gen) }

# 2. 记录 llama-server 的 CPU（判断是否忙）
$ls = Get-Process llama-server -ErrorAction SilentlyContinue
if ($ls) {
    $c1 = ($ls | Measure-Object CPU -Sum).Sum
    Start-Sleep -Seconds 2
    $c2 = ((Get-Process llama-server -ErrorAction SilentlyContinue) | Measure-Object CPU -Sum).Sum
    Write-In ('llama-server 2 秒内 CPU 增长 {0:N1} 秒（>1.5 基本可判定在疯狂生成）' -f ($c2 - $c1))
} else {
    Write-In '没有 llama-server 进程（可能本来就没在跑）'
}

# 3. 中断：先请 Ollama 卸载模型，再强杀 runner（keep_alive 有时无效）
if (-not $KeepModel) {
    try {
        $ps = Invoke-RestMethod 'http://127.0.0.1:11434/api/ps' -TimeoutSec 5
        foreach ($m in @($ps.models)) {
            if (-not $m) { continue }
            $body = @{ model = $m.name; prompt = ''; stream = $false; keep_alive = 0 } | ConvertTo-Json -Compress
            try { Invoke-RestMethod 'http://127.0.0.1:11434/api/generate' -Method POST -ContentType 'application/json' -Body $body -TimeoutSec 20 | Out-Null } catch { }
            Write-In ('已请求卸载: ' + $m.name)
        }
    } catch { }
    Start-Sleep -Seconds 3
}

$killed = 0
Get-Process llama-server -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    Write-Ok ('已强杀 llama-server PID ' + $_.Id)
    $script:killed++
}
if ($script:killed -eq 0 -and $ls) { Write-In '进程已自行退出' }
if ($script:killed -eq 0 -and -not $ls) { Write-In '无需处理（没有在跑的 runner）' }

# 3.5 如果 runner 被 Ollama 立刻重生（说明有客户端请求还挂着），重启服务才能真停
Start-Sleep -Seconds 4
$respawn = Get-Process llama-server -ErrorAction SilentlyContinue
if ($respawn) {
    Write-Warn 'runner 被立刻重生（有客户端请求还挂着）→ 重启 Ollama 服务以中断请求'
    Get-Process 'ollama app','ollama','llama-server' -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 6
    $still = Get-Process 'ollama app','ollama','llama-server' -ErrorAction SilentlyContinue
    if ($still) { Write-Warn ('仍有进程: ' + (($still | ForEach-Object { $_.ProcessName }) -join ', ')) }
    else { Write-Ok '服务已停，挂起的请求会失败退出' }
    if (-not $KeepOffline) {
        Start-Process -FilePath (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe') -WindowStyle Hidden
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Seconds 2
            try { $null = Invoke-RestMethod 'http://127.0.0.1:11434/api/tags' -TimeoutSec 3; Write-In 'Ollama 已重新启动（空载）'; break } catch { }
        }
    }
}

# 4. 复查
Start-Sleep -Seconds 4
$freeAfter = Get-FreeMiB
Write-H '结果'
Write-In ('可用显存: {0:N1} GB → {1:N1} GB（回血 {2:N1} GB）' -f ($freeBefore / 1024), ($freeAfter / 1024), (($freeAfter - $freeBefore) / 1024))
try {
    $ps2 = Invoke-RestMethod 'http://127.0.0.1:11434/api/ps' -TimeoutSec 5
    if ($ps2.models) { $ps2.models | ForEach-Object { Write-Warn ('仍在驻留: ' + $_.name) } }
    else { Write-Ok 'Ollama 已无模型驻留' }
} catch { Write-In 'Ollama 服务未响应（不影响，下次请求会自动拉起）' }

Write-Host ''
Write-Ok '完成。回到 DSH 重新发一次请求即可（不要在同一轮里继续等它）。'
Write-In '如果想彻底避免：在请求里限制输出长度，或换用 27B/云端模型做多步任务。'
if ($KeepOpen) { Write-Host ''; Write-Host '  按回车关闭窗口…' -ForegroundColor DarkGray; $null = Read-Host }
exit 0
