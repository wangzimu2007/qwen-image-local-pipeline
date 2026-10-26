# _verify_autocontinue.ps1 —— 验证"自动续跑 + 多任务并发"
#
# 用法：
#   .\_verify_autocontinue.ps1 -DryRun                  # 只检查前置，不提交（不占 GPU）
#   .\_verify_autocontinue.ps1                          # 真跑（自动保证本地聊天模型常驻）
#   .\_verify_autocontinue.ps1 -SkipB -SkipC -SkipD     # 只跑部分
#
# 设计要点（2026-10-26 两轮实测后修订）：
#   1. 会先把本地聊天模型加载进显存（模拟真实会话），否则会走"同步执行"路径，测不到队列/卸载/恢复
#   2. 提交结果分两种模式：sync（显存够，不卸载）与 queue（排队，守护卸载/恢复后返回）
#   3. 并发/批中追加用"提交进程 + 文件轮询"验证，不依赖会话是否还在线
param(
    [switch]$DryRun,
    [switch]$SkipA,
    [switch]$SkipB,
    [switch]$SkipC,
    [switch]$SkipD,
    [int]$PollSec = 3,
    [int]$BatchTimeoutSec = 420,
    [switch]$NoWarm
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$submit = Join-Path $here '提交作业.ps1'
$jobs = Join-Path $here '.jobs'
$doneDir = Join-Path $jobs 'done'
$logFile = Join-Path $jobs '守护.log'
$ps = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$tmp = Join-Path $env:TEMP ('qverify-' + (Get-Random))

function Say { param([string]$t, [string]$c = 'Gray') Write-Host ('  ' + $t) -ForegroundColor $c }
function QCount { param([string]$sub) return @(Get-ChildItem (Join-Path $jobs $sub) -File -Filter '*.json' -ErrorAction SilentlyContinue).Count }
function DoneCount { param([string[]]$Ids) return @($Ids | Where-Object { $_.Trim() -and (Test-Path (Join-Path $doneDir ($_ + '.json'))) }).Count }
function Get-IdsFromText { param([string]$text) return @([regex]::Matches($text, '(20\d{6}-\d{6}-\d{3}-[a-z0-9]+-\d{3})') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) }
function Wait-AllDone {
    param([string[]]$Ids, [int]$Timeout = 420)
    $deadline = (Get-Date).AddSeconds($Timeout)
    while ((Get-Date) -lt $deadline) {
        if ((DoneCount $Ids) -ge $Ids.Count) { return $true }
        Start-Sleep -Seconds $PollSec
    }
    return ((DoneCount $Ids) -ge $Ids.Count)
}
function Get-VramUsed { try { return [int]((( & nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null) | Select-Object -First 1).Trim()) } catch { return 0 } }
function Get-BatchSizes { param([string[]]$Lines) return @($Lines | ForEach-Object { if ($_ -match '本批 (\d+) 个作业') { [int]$matches[1] } }) }

Say ''
Say ('=== 自动续跑 / 并发验证' + $(if ($DryRun) { '（演练）' } else { '' }) + ' ===') 'Cyan'

# ---------- 0. 前置 ----------
Say ''
Say '[0] 前置检查'
$problems = @()
if ((QCount 'pending') -ne 0 -or (QCount 'running') -ne 0) { $problems += '队列非空' }
if (Test-Path (Join-Path $jobs 'guardian.lock')) { $problems += 'guardian.lock 存在' }
$gd = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '-File\s+"?[^"]*作业守护\.ps1' -and $_.ProcessId -ne $PID })
if ($gd.Count -ne 1) { $problems += ('守护实例 ' + $gd.Count + '（应 1）') }
foreach ($p in '提交作业.ps1', '_wait.ps1', '看状态.ps1') { if (-not (Test-Path (Join-Path $here $p))) { $problems += ('缺 ' + $p) } }
Say ('  队列 pending={0} running={1}；守护实例 {2}；GPU 已用 {3} MiB' -f (QCount 'pending'), (QCount 'running'), $gd.Count, (Get-VramUsed))
if ($problems.Count) { $problems | ForEach-Object { Say ('  ✗ ' + $_) 'Red' } }
else { Say '  ✓ 前置通过' 'Green' }

if ($DryRun) {
    Say ''
    Say '[演练] 真跑时会先把本地聊天模型加载进显存，再执行 A/B/C/D' 'Cyan'
    Say '  演练结束，未提交任何作业。' 'Green'
    if ($problems.Count) { exit 2 } else { exit 0 }
}
if ($problems.Count) { Say '  前置不满足，终止（等空闲再跑）' 'Yellow'; exit 2 }

# ---------- 0.5 保证本地聊天模型常驻（真实会话场景）----------
if (-not $NoWarm) {
    Say ''
    Say '[0.5] 让本地聊天模型常驻（模拟真实会话）'
    $used = Get-VramUsed
    if ($used -lt 15000) {
        $model = 'qwen3.8:27b-abliterated'
        $body = @{ model = $model; prompt = 'hi'; stream = $false; keep_alive = -1; options = @{ num_predict = 1 } } | ConvertTo-Json -Depth 4
        try {
            $null = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method POST -Body $body -ContentType 'application/json' -TimeoutSec 300
            for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Seconds 3; if ((Get-VramUsed) -ge 15000) { break } }
            Say ('  ✓ 已加载 {0}（GPU 已用 {1} MiB）' -f $model, (Get-VramUsed)) 'Green'
        } catch { Say ('  ⚠ 无法预热 Ollama：' + $_.Exception.Message.Substring(0, [Math]::Min(70, $_.Exception.Message.Length))) 'Yellow' }
    } else {
        Say ('  已有模型常驻（GPU 已用 {0} MiB），跳过' -f $used) 'DarkGray'
    }
}

$results = @()
function Add-Result { param([string]$Test, [bool]$Ok, [double]$Sec, [string]$Detail)
    $script:results += [pscustomobject]@{ 测试 = $Test; 结果 = $(if ($Ok) { '通过' } else { '失败' }); 秒 = [math]::Round($Sec, 1); 说明 = $Detail }
    Say ('  → {0}: {1}（{2:N1} 秒）{3}' -f $Test, $(if ($Ok) { '通过' } else { '失败' }), $Sec, $(if ($Detail) { '  ' + $Detail } else { '' })) $(if ($Ok) { 'Green' } else { 'Red' })
}

# ---------- A. 单张 + -Wait ----------
Say ''
Say '[A] 单张 + -Wait' 'Cyan'
$sw = [Diagnostics.Stopwatch]::StartNew()
$outA = & powershell -NoProfile -ExecutionPolicy Bypass -File $submit -Task zimage -Prompt '验证A：晨雾山谷' -Width 640 -Height 384 -Steps 8 -Seeds 101 -Wait 2>&1
$sw.Stop()
$textA = ($outA | ForEach-Object { [string]$_ }) -join "`n"
$modeA = if ($textA -match '同步执行') { 'sync' } elseif ($textA -match '已排队') { 'queue' } else { 'unknown' }
$idsA = Get-IdsFromText $textA
if ($modeA -eq 'sync') {
    Add-Result 'A 单张-Wait' ($textA -match '成品：') $sw.Elapsed.TotalSeconds ('sync（不卸载）成品=' + ($textA -match '成品：'))
} elseif ($modeA -eq 'queue') {
    $okA = ($textA -match '聊天后端已就绪') -and (Test-Path (Join-Path $jobs 'last-batch.json'))
    Add-Result 'A 单张-Wait' $okA $sw.Elapsed.TotalSeconds ('queue（卸载/恢复）后端就绪={0} id={1}' -f ($textA -match '聊天后端已就绪'), ($idsA -join ','))
} else {
    Add-Result 'A 单张-Wait' $false $sw.Elapsed.TotalSeconds '无法判断执行模式'
}

# ---------- B. 批量 2 张 + -Wait ----------
if (-not $SkipB) {
    Say ''
    Say '[B] 一次 2 张 + -Wait' 'Cyan'
    $from = @(Get-Content $logFile -Encoding UTF8 -ErrorAction SilentlyContinue).Count
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $outB = & powershell -NoProfile -ExecutionPolicy Bypass -File $submit -Task zimage -Prompt '验证B：雪山日出' -Width 640 -Height 384 -Steps 8 -Count 2 -Seeds '202,303' -Wait 2>&1
    $sw.Stop()
    $textB = ($outB | ForEach-Object { [string]$_ }) -join "`n"
    $idsB = Get-IdsFromText $textB
    $doneB = DoneCount $idsB
    $sizesB = Get-BatchSizes (@(Get-Content $logFile -Encoding UTF8 -ErrorAction SilentlyContinue) | Select-Object -Skip $from)
    $okB = ($idsB.Count -eq 2) -and ($doneB -eq 2) -and ($sizesB -contains 2)
    Add-Result 'B 批量2张-Wait' $okB $sw.Elapsed.TotalSeconds ('ids={0} 完成={1} 批大小=[{2}] 后端就绪={3}' -f ($idsB -join ','), $doneB, ($sizesB -join ','), ($textB -match '聊天后端已就绪'))
}

# ---------- C. 两条命令同时提交 ----------
if (-not $SkipC) {
    Say ''
    Say '[C] 两条命令同时提交' 'Cyan'
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $o1 = Join-Path $tmp 'c1.txt'; $o2 = Join-Path $tmp 'c2.txt'
    $from = @(Get-Content $logFile -Encoding UTF8 -ErrorAction SilentlyContinue).Count
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $sb = { param($sub, $prompt, $seed) $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $sub -Task zimage -Prompt $prompt -Width 640 -Height 384 -Steps 8 -Seeds $seed 2>&1; ($o | ForEach-Object { [string]$_ }) -join "`r`n" }
    $j1 = Start-Job -ScriptBlock $sb -ArgumentList $submit, 'C1', 404
    $j2 = Start-Job -ScriptBlock $sb -ArgumentList $submit, 'C2', 505
    $null = Wait-Job -Job $j1, $j2 -Timeout 180
    $t1 = (Receive-Job -Job $j1 -ErrorAction SilentlyContinue) -join "`r`n"
    $t2 = (Receive-Job -Job $j2 -ErrorAction SilentlyContinue) -join "`r`n"
    Remove-Job -Job $j1, $j2 -Force -ErrorAction SilentlyContinue
    if ($t1) { [System.IO.File]::WriteAllText($o1, $t1, (New-Object System.Text.UTF8Encoding($false))) }
    if ($t2) { [System.IO.File]::WriteAllText($o2, $t2, (New-Object System.Text.UTF8Encoding($false))) }
    $t1 = if (Test-Path $o1) { Get-Content $o1 -Raw -Encoding UTF8 } else { '' }
    $t2 = if (Test-Path $o2) { Get-Content $o2 -Raw -Encoding UTF8 } else { '' }
    $idsC = @(Get-IdsFromText $t1) + @(Get-IdsFromText $t2)
    if ($idsC.Count -eq 0) {
        $idsC = @(Get-ChildItem $doneDir -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 2 | ForEach-Object { $_.BaseName })
    }
    $okC = Wait-AllDone -Ids $idsC -Timeout $BatchTimeoutSec
    $sw.Stop()
    $sizesC = Get-BatchSizes (@(Get-Content $logFile -Encoding UTF8 -ErrorAction SilentlyContinue) | Select-Object -Skip $from)
    $merged = ($sizesC -contains 2)
    $modeC = if ($t1 -match '同步执行' -and $t2 -match '同步执行') { '两条都 sync' } elseif ($sizesC.Count -gt 0) { 'queue' } else { 'unknown' }
    $okC = $okC -and (($modeC -eq 'queue' -and $merged) -or $modeC -eq '两条都 sync')
    Add-Result 'C 并发2条' $okC $sw.Elapsed.TotalSeconds ('模式={0}；批大小=[{1}]；合并={2}；ids={3}' -f $modeC, ($sizesC -join ','), $merged, ($idsC -join ','))
}

# ---------- D. 批运行中再追加 ----------
if (-not $SkipD) {
    Say ''
    Say '[D] 批运行中再追加 1 张' 'Cyan'
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $d0 = Join-Path $tmp 'd0.txt'; $d1 = Join-Path $tmp 'd1.txt'
    $from = @(Get-Content $logFile -Encoding UTF8 -ErrorAction SilentlyContinue).Count
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $sbD = { param($sub, $prompt, $seed) $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $sub -Task zimage -Prompt $prompt -Width 640 -Height 384 -Steps 8 -Seeds $seed 2>&1; ($o | ForEach-Object { [string]$_ }) -join "`r`n" }
    $jd0 = Start-Job -ScriptBlock $sbD -ArgumentList $submit, 'D0', 606
    $null = Wait-Job -Job $jd0 -Timeout 180
    $t0d = (Receive-Job -Job $jd0 -ErrorAction SilentlyContinue) -join "`r`n"
    Remove-Job -Job $jd0 -Force -ErrorAction SilentlyContinue
    if ($t0d) { [System.IO.File]::WriteAllText($d0, $t0d, (New-Object System.Text.UTF8Encoding($false))) }
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        $ln = @(Get-Content $logFile -Encoding UTF8 -ErrorAction SilentlyContinue) | Select-Object -Skip $from
        if (($ln -join "`n") -match '本批 \d+ 个作业') { break }
        Start-Sleep -Seconds 2
    }
    Start-Sleep -Seconds 4
    $jd1 = Start-Job -ScriptBlock $sbD -ArgumentList $submit, 'D1', 707
    $null = Wait-Job -Job $jd1 -Timeout 180
    $t1dRaw = (Receive-Job -Job $jd1 -ErrorAction SilentlyContinue) -join "`r`n"
    Remove-Job -Job $jd1 -Force -ErrorAction SilentlyContinue
    if ($t1dRaw) { [System.IO.File]::WriteAllText($d1, $t1dRaw, (New-Object System.Text.UTF8Encoding($false))) }
    $pendD = QCount 'pending'
    $deadline2 = (Get-Date).AddSeconds($BatchTimeoutSec)
    while ((Get-Date) -lt $deadline2) {
        if ((QCount 'pending') -eq 0 -and (QCount 'running') -eq 0 -and -not (Test-Path (Join-Path $jobs 'guardian.lock'))) { break }
        Start-Sleep -Seconds $PollSec
    }
    $sw.Stop()
    $sizesD = Get-BatchSizes (@(Get-Content $logFile -Encoding UTF8 -ErrorAction SilentlyContinue) | Select-Object -Skip $from)
    $t1d = if (Test-Path $d1) { Get-Content $d1 -Raw -Encoding UTF8 } else { '' }
    $okD = (($t1d -match '已排队') -or ($t1d -match '同步执行')) -and ((QCount 'pending') -eq 0)
    Add-Result 'D 批中追加' $okD $sw.Elapsed.TotalSeconds ('追加模式={0}；批大小=[{1}]；最终 pending={2}' -f $(if ($t1d -match '已排队') { 'queue' } elseif ($t1d -match '同步执行') { 'sync' } else { '?' }), ($sizesD -join ','), (QCount 'pending'))
}

# ---------- 收尾 ----------
Say ''
Say '[E] 收尾'
$closer = Join-Path $here '关ComfyUI.ps1'
if (Test-Path $closer) { & powershell -NoProfile -ExecutionPolicy Bypass -File $closer -Quiet 2>&1 | Out-Null }
Start-Sleep -Seconds 1
$chat = @()
try { . (Join-Path $here '_backend.ps1'); $chat = @(Get-LocalBackends -Role 'chat' | Where-Object { $_.serving } | ForEach-Object { $_.kind + ':' + $_.port }) } catch { }
Say ('  聊天后端: ' + $(if ($chat.Count) { $chat -join ' / ' } else { '无' }))
Say ('  队列: pending {0} / running {1} / lock {2}' -f (QCount 'pending'), (QCount 'running'), (Test-Path (Join-Path $jobs 'guardian.lock')))
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

Say ''
Say '=== 结果汇总 ===' 'Cyan'
$results | Format-Table -AutoSize | Out-String -Width 220 | ForEach-Object { '  ' + $_ }
$fail = @($results | Where-Object { $_.结果 -ne '通过' }).Count
Say ('  通过 {0} / 共 {1}' -f ($results.Count - $fail), $results.Count) $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
exit $(if ($fail -eq 0) { 0 } else { 1 })
