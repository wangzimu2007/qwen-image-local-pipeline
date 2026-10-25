# 本地模型显存快照 / 释放 / 恢复 —— 供 Z画图.ps1、MOSS画图.ps1 共用
# 与 画图.ps1 的内部逻辑一致：快照 Strata(8080)、Ollama(11434)、NInfer(8090) → 停/卸载 → 出图 → 自动恢复
# 用法：
#   . (Join-Path $PSScriptRoot '_vram.ps1')
#   $state = Start-VramPrep            # 快照并释放；返回状态对象（无本地模型时返回 $null）
#   ... 出图 ...
#   Restore-VramPrep $state            # 恢复

$script:VramRoot      = 'D:\qwen-image-2.1'
$script:VramStateFile = Join-Path $script:VramRoot '.chat-backend-state.json'
$script:VramActions   = Join-Path $env:LOCALAPPDATA 'Strata\actions'
$script:VramLock      = $null

function Enter-ImageVramLock {
    param([int]$TimeoutSeconds = 300)
    $mutex = New-Object System.Threading.Mutex($false, 'Local\DshImageVramPipeline')
    $ok = $false
    try {
        $ok = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
    } catch [System.Threading.AbandonedMutexException] {
        # 上一个持有者异常退出；互斥量已归当前线程，可以继续。
        $ok = $true
    } catch {
        Write-Warning ("  获取出图锁失败：{0}" -f $_.Exception.Message)
    }
    if (-not $ok) {
        try { $mutex.Dispose() } catch { }
        Write-Warning '  另一个出图任务正在运行，等待超时；本次不启动。'
        return $false
    }
    $script:VramLock = $mutex
    return $true
}

function Exit-ImageVramLock {
    try {
        if ($script:VramLock) {
            $script:VramLock.ReleaseMutex()
            $script:VramLock.Dispose()
        }
    } catch { }
    $script:VramLock = $null
}

function Get-VramStrataVariant {
    param([string]$ModelId)
    if ($ModelId -match 'nvfp4') { return 'nvfp4' }
    if ($ModelId -match 'iq3')   { return 'iq3_s' }
    return ''
}

# 读取 DSH 当前默认模型（provider/model），用于防止"卸载正在服务对话的那个模型"
function Get-DshActiveModel {
    $yml = Join-Path $env:USERPROFILE '.dsh\profiles\desktop\cordis.patch.yml'
    if (-not (Test-Path $yml)) { return $null }
    try {
        $lines = [System.IO.File]::ReadAllText($yml, [System.Text.Encoding]::UTF8) -split "`n"
        $inDefault = $false
        $provider = ''
        $model = ''
        foreach ($ln in $lines) {
            if ($ln -match '-\s+id:\s*agent-default-model') { $inDefault = $true; continue }
            if ($inDefault) {
                if ($ln -match '^\s*-\s+id:\s*' ) { break }
                if ($ln -match '^\s*provider:\s*(\S+)') { $provider = $Matches[1] }
                if ($ln -match '^\s*model:\s*(\S+)') { $model = $Matches[1] }
                if ($provider -and $model) { break }
            }
        }
        if ($provider -and $model) {
            return [pscustomobject]@{ provider = $provider; model = $model }
        }
    } catch { }
    return $null
}

# 这个后端是不是正在服务当前对话？是则不允许擅自卸载（除非守护进程显式放行）
function Test-IsDshActiveBackend {
    param($backend)
    if (-not $backend) { return $false }
    $active = Get-DshActiveModel
    if (-not $active) { return $false }
    if ($backend.kind -eq 'strata') {
        if ($active.provider -notlike 'strata*') { return $false }
        # 变体判断：iq3s / nvfp4
        $variantHint = $active.model.ToLower()
        $backendVariant = ($backend.variant + '').ToLower()
        if ($variantHint -match 'nvfp4' -and $backendVariant -match 'nvfp4') { return $true }
        if ($variantHint -match 'iq3' -and $backendVariant -match 'iq3') { return $true }
        # 变体对不上也按"占用中"处理，宁可不卸载
        return $true
    }
    if ($backend.kind -eq 'ollama') {
        if ($active.provider -notlike 'ollama*') { return $false }
        foreach ($m in @($backend.models)) { if ($m -eq $active.model) { return $true } }
    }
    return $false
}

function Get-ChatBackends {
    $list = New-Object System.Collections.ArrayList
    $r = $null
    try { $r = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/models' -TimeoutSec 3 } catch { }
    if ($r -and $r.data) {
        $mid = ($r.data | Select-Object -First 1).id
        [void]$list.Add([pscustomobject]@{ kind = 'strata'; variant = (Get-VramStrataVariant $mid); modelId = $mid })
    } elseif (Get-Process -Name 'strata' -ErrorAction SilentlyContinue) {
        Write-Host '  提示：有 strata 进程但 8080 无响应，视为未提供服务，不处理。' -ForegroundColor DarkGray
    }
    $ps = $null
    try { $ps = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/ps' -TimeoutSec 3 } catch { }
    if ($ps -and $ps.models) {
        $names = @($ps.models | ForEach-Object { $_.name })
        if ($names.Count -gt 0) { [void]$list.Add([pscustomobject]@{ kind = 'ollama'; models = $names }) }
    }
    $ni = $null
    try { $ni = Invoke-RestMethod -Uri 'http://127.0.0.1:8090/v1/models' -TimeoutSec 3 } catch { }
    if ($ni -and $ni.data) {
        $mid = ($ni.data | Select-Object -First 1).id
        [void]$list.Add([pscustomobject]@{ kind = 'ninfer'; modelId = $mid })
    }
    return ,$list
}


function Get-VramHolders {
    param([int]$Top = 6)
    try { $samples = (Get-Counter '\GPU Process Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples } catch { return @() }
    $acc = @{}
    foreach($s in $samples){
        if($s.InstanceName -notmatch '^pid_(\d+)'){ continue }
        if($s.CookedValue -le 0){ continue }
        $p = [int]$Matches[1]
        if(-not $acc.ContainsKey($p)){ $acc[$p] = 0.0 }
        $acc[$p] += $s.CookedValue
    }
    $skip = @('dwm', 'csrss', 'winlogon', 'LogonUI', 'Registry', 'Memory Compression')
    $rows = foreach($k in $acc.Keys){
        $proc = Get-Process -Id $k -ErrorAction SilentlyContinue
        $nm = if($proc){ $proc.ProcessName } else { '?' }
        if($skip -contains $nm){ continue }
        if($acc[$k]/1GB -gt 6.0){ continue }
        [pscustomobject]@{ PID=$k; Name=$nm; GB=[math]::Round($acc[$k]/1GB,2) }
    }
    return ($rows | Sort-Object GB -Descending | Select-Object -First $Top)
}

function Test-ChatUnloaded {
    param([int]$TimeoutSec = 30)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $ollamaDown = $true
        try {
            $ps = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/ps' -TimeoutSec 3
            if ($ps.models -and @($ps.models).Count -gt 0) { $ollamaDown = $false }
        } catch { }
        $ninferDown = $true
        try {
            $ni = Invoke-RestMethod -Uri 'http://127.0.0.1:8090/v1/models' -TimeoutSec 2
            if ($ni -and $ni.data) { $ninferDown = $false }
        } catch { }
        if ($ollamaDown -and $ninferDown) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}
# 物理内存与页面文件快照（用于判断"卸载后内存是否真的释放"）
function Get-MemStat {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $freePhys = $os.FreePhysicalMemory / 1MB          # GB
        $totalPhys = $os.TotalVisibleMemorySize / 1MB
        $pfUsed = ($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1MB
        $pf = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | Select-Object -First 1
        return [pscustomobject]@{
            freePhysGB = [math]::Round($freePhys, 2)
            totalPhysGB = [math]::Round($totalPhys, 2)
            pageFileUsedGB = [math]::Round($pfUsed, 2)
            pageFilePeakMB = if ($pf) { $pf.PeakUsage } else { 0 }
        }
    } catch { return $null }
}

function Format-MemStat {
    param($m)
    if (-not $m) { return '(内存信息不可用)' }
    return ("物理可用 {0:N1}/{1:N1} GB, 页面文件已用 {2:N1} GB" -f $m.freePhysGB, $m.totalPhysGB, $m.pageFileUsedGB)
}

function Get-FreeVramMiB {
    $raw = (& nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null) -join ''
    if ($raw -match '(\d+)') { return [int]$Matches[1] }
    return 0
}

# 出图前按需腾显存：够用就不动本地模型；不够才快照并卸载，出图后由调用方 Restore-VramPrep。
function Get-StaleVramState {
    if (-not (Test-Path $script:VramStateFile)) { return $null }
    try {
        $saved = Get-Content $script:VramStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $backends = @($saved.backends) | Where-Object { $_ -ne $null }
        if (@($backends).Count -eq 0) { return $null }
        return [pscustomobject]@{
            capturedAt    = $saved.capturedAt
            requestedPort = $saved.requestedPort
            backends      = @($backends)
            stale         = $true
        }
    } catch {
        Write-Warning ("  残留快照损坏，忽略：{0}" -f $_.Exception.Message)
        return $null
    }
}

function Ensure-VramForImage {
    param(
        [int]$NeedMiB = 14000,
        [int]$TimeoutSeconds = 150,
        [switch]$EngineAlreadyRunning
    )
    # 作业队列模式：显存卸载/恢复由 作业守护 统一管理，脚本自身不再快照
    if ($env:PIPE_GUARDIAN_MANAGED -eq '1') { return $null }
    $stale = Get-StaleVramState
    if ($EngineAlreadyRunning) {
        Write-Host '  出图引擎已在运行，跳过显存快照。' -ForegroundColor DarkGray
        if ($stale) {
            Write-Host '  发现上次残留快照，将在出图后恢复。' -ForegroundColor DarkGray
            return $stale
        }
        return $null
    }
    $free = Get-FreeVramMiB
    if ($free -ge $NeedMiB) {
        Write-Host ("  显存充足：{0:N1} GB 可用（需要 {1:N1} GB），跳过本地模型快照。" -f ($free / 1024), ($NeedMiB / 1024)) -ForegroundColor DarkGray
        if ($stale) {
            Write-Host '  发现上次残留快照，将在出图后恢复。' -ForegroundColor DarkGray
            return $stale
        }
        return $null
    }
    Write-Host ("  显存不足：{0:N1} GB 可用（需要 {1:N1} GB），自动快照并卸载本地模型…" -f ($free / 1024), ($NeedMiB / 1024)) -ForegroundColor Yellow
    return Start-VramPrep -NeedMiB $NeedMiB -TimeoutSeconds $TimeoutSeconds
}

function Wait-VramFree {
    param([int]$NeedMiB = 17000, [int]$TimeoutSeconds = 150)
    $free = 0
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $free = Get-FreeVramMiB
        if ($free -ge $NeedMiB) { return $free }
        Start-Sleep -Seconds 3
    }
    return $free
}

function Start-VramPrep {
    param([int]$NeedMiB = 17000, [int]$TimeoutSeconds = 150)
    # 先读取上一次异常退出留下的快照；它的后端可能已经被停掉，出图后要一起恢复。
    $staleBackends = @()
    if (Test-Path $script:VramStateFile) {
        try {
            $saved = Get-Content $script:VramStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $staleBackends = @($saved.backends) | Where-Object { $_ -ne $null }
            if (@($staleBackends).Count -gt 0) {
                Write-Host '  发现上次残留快照，将把它合并进本次恢复列表。' -ForegroundColor DarkGray
            }
        } catch {
            Write-Warning ("  上次快照损坏，无法合并：{0}" -f $_.Exception.Message)
        }
        Remove-Item $script:VramStateFile -ErrorAction SilentlyContinue
    }

    $currentBackends = Get-ChatBackends
    $merged = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($b in @($staleBackends) + @($currentBackends)) {
        if ($null -eq $b) { continue }
        $key = if ($b.kind -eq 'ollama') {
            'ollama:' + ((@($b.models) | Sort-Object) -join ',')
        } else {
            ("{0}:{1}" -f $b.kind, $b.modelId)
        }
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            [void]$merged.Add($b)
        }
    }

    $memBefore = Get-MemStat
    if ($memBefore) { Write-Host ('  ' + (Format-MemStat $memBefore)) -ForegroundColor DarkGray }

    if ($merged.Count -eq 0) {
        Write-Host '  没有本地模型在提供服务，直接出图，不涉及恢复。' -ForegroundColor DarkGray
        $free = Wait-VramFree -NeedMiB $NeedMiB -TimeoutSeconds 20
        Write-Host ("  可用显存 {0:N1} GB" -f ($free / 1024)) -ForegroundColor DarkGray
        return $null
    }

    $state = [pscustomobject]@{
        capturedAt    = (Get-Date).ToString('o')
        requestedPort = 0
        backends      = @($merged)
    }
    $state | ConvertTo-Json -Depth 6 | Set-Content -Path $script:VramStateFile -Encoding UTF8

    # 只停止“当前真的在服务”的后端；残留快照里的后端已经停了，直接留给恢复列表。
    foreach ($b in @($currentBackends)) {
        if ((Test-IsDshActiveBackend $b) -and ($env:PIPE_ALLOW_SELF_UNLOAD -ne '1')) {
            throw ("拒绝卸载：Strata {0} 正是 DSH 当前正在使用的聊天模型（{1}）。`n" +
                   "  在本地模型会话里卸载它 = 对话立刻断线（TRANSPORT Connection error）。`n" +
                   "  正确做法：改用 提交作业.ps1（显存够就同步跑、不够就排队给 作业守护.ps1），`n" +
                   "  或者由云端模型 / 你本人手动执行卸载。") -f $b.variant, (Get-DshActiveModel).model
        }
        if ($b.kind -eq 'strata') {
            Write-Host ("  检测到 Strata {0}（{1}），先停掉腾显存，出图后自动恢复。" -f $b.variant, $b.modelId) -ForegroundColor Yellow
            $stopCmd  = if ($b.variant -eq 'nvfp4') { 'stop-nvfp4.cmd' } else { 'stop-iq3s.cmd' }
            $stopPath = Join-Path $script:VramActions $stopCmd
            if (-not (Test-Path $stopPath)) { $stopPath = Join-Path $script:VramActions 'stop-iq3s.cmd' }
            if (Test-Path $stopPath) { & cmd /c "`"$stopPath`"" | Out-Null }
        }
        elseif ($b.kind -eq 'ollama') {
            if ((Test-IsDshActiveBackend $b) -and ($env:PIPE_ALLOW_SELF_UNLOAD -ne '1')) {
                throw ("拒绝卸载：Ollama 模型 {0} 正是 DSH 当前正在使用的聊天模型；卸载会导致对话断线。" -f ((@($b.models)) -join ', '))
            }
            Write-Host ("  检测到 Ollama 已加载模型（{0}），先卸载腾显存。" -f (@($b.models) -join ', ')) -ForegroundColor Yellow
            foreach ($m in @($b.models)) {
                try {
                    $body = @{ model = $m; keep_alive = 0 } | ConvertTo-Json -Compress
                    Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method POST `
                        -ContentType 'application/json' -Body $body -TimeoutSec 30 | Out-Null
                } catch { Write-Warning ("  卸载 {0} 失败：{1}" -f $m, $_.Exception.Message) }
            }
        }
        elseif ($b.kind -eq 'ninfer') {
            Write-Host ("  检测到 NInfer（{0}），先停止 WSL ninfer-serve 腾显存，出图后自动重启。" -f $b.modelId) -ForegroundColor Yellow
            try {
                & wsl.exe -d Ubuntu-24.04 -u root -- bash -lc "pkill -x ninfer-serve || true" 2>$null | Out-Null
            } catch { Write-Warning ("  停止 NInfer 失败：{0}" -f $_.Exception.Message) }
        }
    }
    Start-Sleep -Seconds 3

    # 验证聊天模型是否真的卸载了；卸不掉会导致后续生成慢 5~10 倍（驱动回退系统内存）
    $unloadOk = Test-ChatUnloaded -TimeoutSec 30
    if (-not $unloadOk) {
        Write-Warning '  聊天模型没能卸载（Ollama 仍在提供服务）—— 生成会很慢（可能慢 5~10 倍）'
        Write-Warning '  可能是它正在被别的客户端占用，或 llama-server 卡住。当前占显存的进程：'
        Get-VramHolders -Top 5 | ForEach-Object { Write-Warning ('    {0,-26} PID {1,-7} {2,6:N2} GB' -f $_.Name, $_.PID, $_.GB) }
        Write-Warning '  处理：关掉占用它的客户端；或运行  .\显存体检.ps1 -Kill  强制释放'
        $state | Add-Member -NotePropertyName unloadFailed -NotePropertyValue $true -Force
    }

    # 自适应等待：显存达标就立即继续；连续 9 秒不再增长且已够用也继续，不傻等满超时
    $free = 0; $lastFree = -1; $stable = 0
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $free = Get-FreeVramMiB
        if ($free -ge $NeedMiB) { break }
        if ($free -eq $lastFree) { $stable++ } else { $stable = 0; $lastFree = $free }
        if ($stable -ge 3 -and $free -ge 9000) { break }
        Start-Sleep -Seconds 3
    }
    if ($free -ge $NeedMiB) {
        Write-Host ("  显存已就绪：{0:N1} GB 可用" -f ($free / 1024)) -ForegroundColor DarkGray
    } elseif ($free -ge 9000) {
        Write-Host ("  显存已停止增长，{0:N1} GB 可用（其余被浏览器/系统占用），继续出图" -f ($free / 1024)) -ForegroundColor DarkGray
    } elseif ($free -ge 8000) {
        Write-Host ("  可用显存 {0:N1} GB（浏览器/系统占了一部分），继续出图" -f ($free / 1024)) -ForegroundColor DarkGray
    } else {
        Write-Warning ("显存只有 {0:N1} GB 可用，很可能失败；建议先关浏览器或停其他 GPU 程序。" -f ($free / 1024))
    }
    return $state
}

function Restore-VramPrep {
    param($State)
    # 作业队列模式：恢复由 作业守护 批末统一做
    if ($env:PIPE_GUARDIAN_MANAGED -eq '1') { return }
    $restorable = @()
    if ($State) { $restorable = @($State.backends) | Where-Object { $_ -ne $null } }
    elseif (Test-Path $script:VramStateFile) {
        try {
            $saved = Get-Content $script:VramStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $restorable = @($saved.backends) | Where-Object { $_ -ne $null }
        } catch { Write-Warning ("状态文件损坏，跳过恢复：" + $_.Exception.Message) }
    }
    if (@($restorable).Count -eq 0) {
        Remove-Item $script:VramStateFile -ErrorAction SilentlyContinue
        return
    }

    Write-Host ''
    Write-Host '  恢复出图前的本地模型…' -ForegroundColor Cyan
    foreach ($b in @($restorable)) {
        if ((Test-IsDshActiveBackend $b) -and ($env:PIPE_ALLOW_SELF_UNLOAD -ne '1')) {
            throw ("拒绝卸载：Strata {0} 正是 DSH 当前正在使用的聊天模型（{1}）。`n" +
                   "  在本地模型会话里卸载它 = 对话立刻断线（TRANSPORT Connection error）。`n" +
                   "  正确做法：改用 提交作业.ps1（显存够就同步跑、不够就排队给 作业守护.ps1），`n" +
                   "  或者由云端模型 / 你本人手动执行卸载。") -f $b.variant, (Get-DshActiveModel).model
        }
        if ($b.kind -eq 'strata') {
            $variant = "$($b.variant)"
            if (-not $variant) { Write-Warning '  无法判断 Strata 变体，按 IQ3_S 恢复。'; $variant = 'iq3_s' }
            $startCmd  = if ($variant -eq 'nvfp4') { 'start-nvfp4.cmd' } else { 'start-iq3s.cmd' }
            $startPath = Join-Path $script:VramActions $startCmd
            $label = if ($variant -eq 'nvfp4') { 'Strata NVFP4' } else { 'Strata IQ3_S' }
            if (-not (Test-Path $startPath)) { Write-Warning ("  找不到 " + $startCmd + "，跳过。"); continue }
            Write-Host ("  恢复 {0}（最长等 420 秒）…" -f $label) -ForegroundColor Yellow
            Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "`"$startPath`"" -WindowStyle Minimized
            $up = $false
            for ($i = 0; $i -lt 210; $i++) {
                Start-Sleep -Seconds 2
                try { $null = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/models' -TimeoutSec 3; $up = $true; break } catch { }
            }
            if ($up) {
                Write-Host ("  {0} 端口已通，做一次推理探针确认真的可用…" -f $label) -ForegroundColor DarkGray
                $warm = $false
                $swWarm = [Diagnostics.Stopwatch]::StartNew()
                for ($try = 1; $try -le 2; $try++) {
                    try {
                        $body = @{ model = $b.modelId; messages = @(@{ role = 'user'; content = 'hi' }); max_tokens = 1; stream = $false } | ConvertTo-Json -Depth 6 -Compress
                        $r = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/chat/completions' -Method POST `
                            -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 120
                        if ($r) { $warm = $true; break }
                    } catch {
                        Write-Host ("  探针第 {0} 次失败：{1}" -f $try, $_.Exception.Message) -ForegroundColor DarkGray
                        Start-Sleep -Seconds 5
                    }
                }
                $swWarm.Stop()
                $memR = Get-MemStat
                if ($warm) {
                    Write-Host ("  {0} 已就绪（探针 {1:N1} 秒；{2}）" -f $label, $swWarm.Elapsed.TotalSeconds, (Format-MemStat $memR)) -ForegroundColor Green
                } else {
                    Write-Warning ("  {0} 端口通了但推理探针失败（{1:N1} 秒），可能还在加载；请稍等或手动点「{0} - 启动」。" -f $label, $swWarm.Elapsed.TotalSeconds)
                }
            }
            else { Write-Warning ("  {0} 420 秒内未就绪，请手动点「{0} - 启动」。" -f $label) }
        }
        elseif ($b.kind -eq 'ollama') {
            if ((Test-IsDshActiveBackend $b) -and ($env:PIPE_ALLOW_SELF_UNLOAD -ne '1')) {
                throw ("拒绝卸载：Ollama 模型 {0} 正是 DSH 当前正在使用的聊天模型；卸载会导致对话断线。" -f ((@($b.models)) -join ', '))
            }
            foreach ($m in @($b.models)) {
                try {
                    $body = @{ model = $m; keep_alive = '30m' } | ConvertTo-Json -Compress
                    Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method POST `
                        -ContentType 'application/json' -Body $body -TimeoutSec 30 | Out-Null
                    Write-Host ("  已重新加载 Ollama 模型：{0}" -f $m) -ForegroundColor Green
                } catch { Write-Warning ("  重新加载 {0} 失败：{1}" -f $m, $_.Exception.Message) }
            }
        }
        elseif ($b.kind -eq 'ninfer') {
            $vbs = 'D:\tools\ninfer\start-ninfer-server.vbs'
            if (-not (Test-Path $vbs)) {
                Write-Warning ("  找不到 NInfer 启动脚本：{0}" -f $vbs)
            } else {
                Write-Host '  重启 NInfer（WSL 服务，约 1 分钟）…' -ForegroundColor Yellow
                Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$vbs`"" -WindowStyle Hidden
                $up = $false
                for ($i = 0; $i -lt 90; $i++) {
                    Start-Sleep -Seconds 2
                    try { $null = Invoke-RestMethod -Uri 'http://127.0.0.1:8090/v1/models' -TimeoutSec 3; $up = $true; break } catch { }
                }
                if ($up) { Write-Host '  NInfer 已就绪。' -ForegroundColor Green }
                else { Write-Warning '  NInfer 180 秒内未就绪，请手动启动「NInfer - 启动」快捷方式。' }
            }
        }
    }
    $memAfter = Get-MemStat
    if ($memAfter) { Write-Host ('  卸载后内存：' + (Format-MemStat $memAfter)) -ForegroundColor DarkGray }
    Remove-Item $script:VramStateFile -ErrorAction SilentlyContinue
}
