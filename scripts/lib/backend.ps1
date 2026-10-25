# _backend.ps1 —— 本地模型后端抽象：自动识别当前用的是哪个后端 / 哪个模型
#
# 支持：Strata(8080, iq3s/nvfp4) / Ollama(11434) / NInfer(8090, WSL)
# 用途：看状态、托盘、Keeper（画图结束后拉回）、作业守护（快照/卸载/恢复）
#
# 用法：
#   . D:\qwen-image-2.1\_backend.ps1
#   Get-LocalBackends           # 所有本地后端及其实时状态
#   Get-ActiveBackend           # DSH 当前默认模型对应的后端
#   Get-OverallState            # 统一状态：就绪/出图中/恢复中/启动中/离线

$script:BackendPorts = @{
    strata = 8080
    ollama = 11434
    ninfer = 8090
}

function Test-PortListening {
    param([int]$Port)
    # 用 TcpClient 探测，比 Get-NetTCPConnection 快一个数量级（后者每次 1~2 秒）
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(250)
        if ($ok) { $client.EndConnect($iar) }
        $client.Close()
        return $ok
    } catch { return $false }
}

function Get-JsonQuick {
    param([string]$Url, [int]$TimeoutSec = 1)
    try { return Invoke-RestMethod $Url -TimeoutSec $TimeoutSec } catch { return $null }
}

function Get-DshDefaultModel {
    $yml = Join-Path $env:USERPROFILE '.dsh\profiles\desktop\cordis.patch.yml'
    if (-not (Test-Path $yml)) { return $null }
    try {
        $lines = [System.IO.File]::ReadAllText($yml, [System.Text.Encoding]::UTF8) -split "`n"
        $inDefault = $false; $provider = ''; $model = ''
        foreach ($ln in $lines) {
            if ($ln -match '-\s+id:\s*agent-default-model') { $inDefault = $true; continue }
            if ($inDefault) {
                if ($ln -match '^\s*-\s+id:\s*') { break }
                if ($ln -match '^\s*provider:\s*(\S+)') { $provider = $Matches[1] }
                if ($ln -match '^\s*model:\s*(\S+)') { $model = $Matches[1]; break }
            }
        }
        if ($provider -and $model) { return [pscustomobject]@{ provider = $provider; model = $model } }
    } catch { }
    return $null
}

# provider 前缀 → 后端类型
function Get-BackendKindFromProvider {
    param([string]$Provider)
    if (-not $Provider) { return $null }
    if ($Provider -like 'strata*') { return 'strata' }
    if ($Provider -like 'ollama*') { return 'ollama' }
    if ($Provider -like 'ninfer*') { return 'ninfer' }
    return $null
}

function Get-StrataVariant {
    # 通过 /v1/models 的模型 id 判断 iq3s / nvfp4
    $m = Get-JsonQuick 'http://127.0.0.1:8080/v1/models'
    if (-not $m) { return '' }
    $ids = @($m.data | ForEach-Object { $_.id })
    foreach ($id in $ids) {
        if ($id -match 'nvfp4') { return 'nvfp4' }
        if ($id -match 'iq3') { return 'iq3s' }
    }
    if (@($ids).Count -gt 0) { return 'unknown' }
    return ''
}

function Get-LocalBackends {
    $out = @()

    # ---- Strata ----
    $upS = Test-PortListening 8080
    $modelsS = @()
    if ($upS) {
        $m = Get-JsonQuick 'http://127.0.0.1:8080/v1/models'
        if ($m) { $modelsS = @($m.data | ForEach-Object { $_.id }) }
    }
    $procS = @(Get-Process -Name strata, strata-vision -ErrorAction SilentlyContinue).Count
    $out += [pscustomobject]@{
        kind = 'strata'; display = 'Strata'; port = 8080
        up = $upS; serving = ($modelsS.Count -gt 0); models = $modelsS
        variant = (Get-StrataVariant); procs = $procS
        startCmd = (Join-Path $env:LOCALAPPDATA 'Strata\actions\start-iq3s.cmd')
        stopCmd = (Join-Path $env:LOCALAPPDATA 'Strata\actions\stop-iq3s.cmd')
    }

    # ---- Ollama ----
    $upO = Test-PortListening 11434
    $modelsO = @()
    if ($upO) {
        $ps = Get-JsonQuick 'http://127.0.0.1:11434/api/ps'
        if ($ps -and $ps.models) { $modelsO = @($ps.models | ForEach-Object { $_.name }) }
    }
    $out += [pscustomobject]@{
        kind = 'ollama'; display = 'Ollama'; port = 11434
        up = $upO; serving = ($modelsO.Count -gt 0); models = $modelsO
        variant = ''; procs = @(Get-Process -Name ollama -ErrorAction SilentlyContinue).Count
        startCmd = (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe')
        stopCmd = ''
    }

    # ---- NInfer (WSL) ----
    $upN = Test-PortListening 8090
    $modelsN = @()
    if ($upN) {
        $m = Get-JsonQuick 'http://127.0.0.1:8090/v1/models'
        if ($m) { $modelsN = @($m.data | ForEach-Object { $_.id }) }
    }
    $out += [pscustomobject]@{
        kind = 'ninfer'; display = 'NInfer (WSL)'; port = 8090
        up = $upN; serving = ($modelsN.Count -gt 0); models = $modelsN
        variant = ''; procs = 0
        startCmd = 'D:\tools\ninfer\start-ninfer-server.vbs'
        stopCmd = ''
    }

    return $out
}

function Get-ActiveBackend {
    $dsh = Get-DshDefaultModel
    $kind = if ($dsh) { Get-BackendKindFromProvider $dsh.provider } else { $null }
    $all = Get-LocalBackends
    $pick = $null
    if ($kind) { $pick = $all | Where-Object { $_.kind -eq $kind } | Select-Object -First 1 }
    if (-not $pick) {
        # DSH 走云端或识别失败时，退回"哪个在服务就用哪个"
        $pick = $all | Where-Object { $_.serving } | Select-Object -First 1
    }
    return [pscustomobject]@{
        backend = $pick
        dsh     = $dsh
        kind    = if ($pick) { $pick.kind } else { $kind }
    }
}

function Start-LocalBackend {
    param($backend)
    if (-not $backend) { return $false }
    switch ($backend.kind) {
        'strata' {
            if (-not (Test-Path $backend.startCmd)) { return $false }
            # 清理残留进程，避免半死进程挡住启动
            if (-not (Test-PortListening 8080)) {
                Get-Process -Name strata, strata-vision -ErrorAction SilentlyContinue |
                    ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
                Start-Sleep -Seconds 2
            }
            Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', ('"' + $backend.startCmd + '"')) -WindowStyle Hidden
            return $true
        }
        'ollama' {
            # 托盘程序没起就拉起；模型按列表重载
            if (-not (Test-PortListening 11434)) {
                $exe = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'
                if (Test-Path $exe) { Start-Process -FilePath $exe -WindowStyle Hidden }
                for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Seconds 2; if (Test-PortListening 11434) { break } }
            }
            foreach ($m in @($backend.models)) {
                try {
                    $body = @{ model = $m; keep_alive = '30m' } | ConvertTo-Json -Compress
                    Invoke-RestMethod 'http://127.0.0.1:11434/api/generate' -Method POST -ContentType 'application/json' -Body $body -TimeoutSec 30 | Out-Null
                } catch { }
            }
            return $true
        }
        'ninfer' {
            if (-not (Test-Path $backend.startCmd)) { return $false }
            Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $backend.startCmd + '"') -WindowStyle Hidden
            return $true
        }
    }
    return $false
}

function Wait-LocalBackendReady {
    param($backend, [int]$TimeoutSeconds = 180)
    if (-not $backend) { return $false }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-PortListening $backend.port) {
            $m = switch ($backend.kind) {
                'ollama' { Get-JsonQuick 'http://127.0.0.1:11434/api/ps' }
                default { Get-JsonQuick ('http://127.0.0.1:' + $backend.port + '/v1/models') }
            }
            if ($m) { return $true }
        }
        Start-Sleep -Seconds 3
    }
    return $false
}

# 统一状态：出图中 / 恢复中 / 就绪 / 启动中 / 离线
function Get-OverallState {
    param([string]$JobsRoot = 'D:\qwen-image-2.1\.jobs')
    $pending = 0; $running = 0
    foreach ($sub in 'pending', 'running') {
        $d = Join-Path $JobsRoot $sub
        if (Test-Path $d) {
            $n = @(Get-ChildItem $d -File -Filter '*.json' -ErrorAction SilentlyContinue).Count
            if ($sub -eq 'pending') { $pending = $n } else { $running = $n }
        }
    }
    $hasLock = Test-Path (Join-Path $JobsRoot 'guardian.lock')
    # 用户手动停止标记（12 小时有效）：此时不判"启动中"，而是"已手动停止"
    $userStop = $false
    $flag = Join-Path $JobsRoot 'user-stop.flag'
    if (Test-Path $flag) {
        try { if (((Get-Date) - (Get-Item $flag).LastWriteTime).TotalHours -lt 12) { $userStop = $true } } catch { }
    }
    $active = Get-ActiveBackend

    $state = '离线'; $detail = ''
    if ($running -gt 0 -or $pending -gt 0) {
        $state = '出图中'
        $detail = if ($running -gt 0) { "任务执行中，排队 $pending" } else { "$pending 个作业排队" }
    }
    elseif ($hasLock) {
        $state = '恢复中'
        $detail = '守护在恢复后端（45~70 秒）'
    }
    elseif ($active.backend -and $active.backend.serving) {
        $state = '就绪'
        $detail = ('{0} · {1}' -f $active.backend.kind, (($active.backend.models) -join ','))
    }
    elseif ($userStop -and -not ($active.backend -and $active.backend.serving)) {
        $state = '离线'
        $detail = '已手动停止（不会自动拉回，点「Strata IQ3_S - 启动」恢复）'
    }
    elseif ($active.backend -and ($active.backend.up -or $active.backend.procs -gt 0)) {
        $state = '启动中'
        $detail = ($active.backend.kind + ' 正在加载模型')
    }
    else {
        $state = '离线'
        $detail = if ($active.kind) { ($active.kind + ' 没在跑') } else { '没有本地后端在跑' }
    }

    return [pscustomobject]@{
        state = $state; detail = $detail
        pending = $pending; running = $running; lock = $hasLock
        activeKind = $active.kind
        activeModel = if ($active.dsh) { $active.dsh.model } else { '' }
        activeProvider = if ($active.dsh) { $active.dsh.provider } else { '' }
        backends = (Get-LocalBackends)
        at = (Get-Date).ToString('HH:mm:ss')
    }
}
