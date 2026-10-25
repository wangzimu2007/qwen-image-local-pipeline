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

# ---- 用户手动停止标记（按后端区分）----
# 文件：.jobs\user-stop-<kind>.flag；兼容旧的全局 .jobs\user-stop.flag（视为全部停止）
# 有效期 12 小时，防止忘记后永远不恢复
$script:JobsRootDefault = 'D:\qwen-image-2.1\.jobs'

function Get-UserStopFlagPath {
    param([string]$Kind, [string]$JobsRoot = $script:JobsRootDefault)
    return (Join-Path $JobsRoot ('user-stop-' + $Kind + '.flag'))
}

function Test-UserStopped {
    param([string]$Kind, [string]$JobsRoot = $script:JobsRootDefault)
    $cands = @()
    if ($Kind) { $cands += (Join-Path $JobsRoot ('user-stop-' + $Kind + '.flag')) }
    $cands += (Join-Path $JobsRoot 'user-stop.flag')   # 旧全局标记
    foreach ($p in $cands) {
        if (Test-Path $p) {
            try { if (((Get-Date) - (Get-Item $p).LastWriteTime).TotalHours -lt 12) { return $true } } catch { }
        }
    }
    return $false
}

function Set-UserStopFlag {
    param([string]$Kind, [string]$JobsRoot = $script:JobsRootDefault)
    $p = Get-UserStopFlagPath -Kind $Kind -JobsRoot $JobsRoot
    $rec = @{ at = (Get-Date).ToString('o'); kind = $Kind; by = 'manual' }
    $rec | ConvertTo-Json -Compress | Set-Content -Path $p -Encoding UTF8
    return $p
}

function Clear-UserStopFlag {
    param([string]$Kind, [string]$JobsRoot = $script:JobsRootDefault)
    foreach ($p in @((Join-Path $JobsRoot ('user-stop-' + $Kind + '.flag')), (Join-Path $JobsRoot 'user-stop.flag'))) {
        if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }
}

# ---- 自动启动策略（2026-10-26 用户要求）----
# 原则：本地 LLM 后端只允许两种情况被启动
#   1) manual  —— 用户手动点「启动」/ 显式命令
#   2) restore —— 作业批末把"本批卸载掉的"后端恢复回来
# 其他任何来源（Keeper 心跳、看护自愈、脚本兜底）一律拒绝。
$script:AllowedStartReasons = @('manual', 'restore')

function Test-AutoStartAllowed {
    param([string]$Kind, [string]$Reason)
    if (-not $Reason) { $Reason = 'unknown' }
    if ($script:AllowedStartReasons -contains $Reason) { return $true }
    Write-Host ('  [策略] 拒绝自动启动 ' + $Kind + '（来源=' + $Reason + '）：本地模型仅允许手动启动或作业批末恢复') -ForegroundColor Yellow
    return $false
}

function Assert-AutoStartAllowed {
    param([string]$Kind, [string]$Reason)
    return (Test-AutoStartAllowed -Kind $Kind -Reason $Reason)
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
    # 先按注册表里的 kind 前缀匹配（支持以后新增模型），再退回内置三种
    try {
        foreach ($def in Get-BackendRegistry) {
            if ($Provider -like ($def.kind + '*')) { return $def.kind }
        }
    } catch { }
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

# ---- 后端注册表（配置驱动：D:\qwen-image-2.1\backends.json）----
function Get-BackendRegistry {
    param([string]$Path = (Join-Path $PSScriptRoot 'backends.json'))
    $defaults = @(
        [pscustomobject]@{ kind='strata'; display='Strata'; role='chat'; port=8080; api='openai'; enabled=$true
            startCmd='%LOCALAPPDATA%\Strata\actions\start-iq3s.cmd'; stopCmd='%LOCALAPPDATA%\Strata\actions\stop-iq3s.cmd'
            startExe=''; startVbs=''; stopPs=''; stopProcs=@(); procs=@('strata','strata-vision'); note='' }
        [pscustomobject]@{ kind='ollama'; display='Ollama'; role='chat'; port=11434; api='ollama'; enabled=$true
            startCmd=''; stopCmd=''; startExe='%LOCALAPPDATA%\Programs\Ollama\ollama app.exe'; startVbs=''; stopPs=''
            stopProcs=@('ollama app','ollama'); procs=@('ollama'); note='' }
        [pscustomobject]@{ kind='ninfer'; display='NInfer (WSL)'; role='chat'; port=8090; api='openai'; enabled=$true
            startCmd=''; stopCmd=''; startExe=''; startVbs='D:\tools\ninfer\start-ninfer-server.vbs'
            stopPs='D:\tools\ninfer\stop-ninfer-server.ps1'; stopProcs=@(); procs=@(); note='' }
    )
    if (-not (Test-Path $Path)) { return $defaults }
    try {
        $raw = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $list = @()
        foreach ($b in @($raw.backends)) {
            if (-not $b -or -not $b.kind) { continue }
            $list += [pscustomobject]@{
                kind       = [string]$b.kind
                display    = $(if ($b.display) { [string]$b.display } else { [string]$b.kind })
                port       = [int]$b.port
                api        = $(if ($b.api) { [string]$b.api } else { 'openai' })
                enabled    = $(if ($null -ne $b.enabled) { [bool]$b.enabled } else { $true })
                role       = $(if ($b.role) { [string]$b.role } else { 'chat' })
                startCmd   = $(if ($b.startCmd) { [string]$b.startCmd } else { '' })
                stopCmd    = $(if ($b.stopCmd) { [string]$b.stopCmd } else { '' })
                startExe   = $(if ($b.startExe) { [string]$b.startExe } else { '' })
                startVbs   = $(if ($b.startVbs) { [string]$b.startVbs } else { '' })
                stopPs     = $(if ($b.stopPs) { [string]$b.stopPs } else { '' })
                stopProcs  = @(if ($b.stopProcs) { $b.stopProcs } else { @() })
                procs      = @(if ($b.procs) { $b.procs } else { @() })
                note       = $(if ($b.note) { [string]$b.note } else { '' })
            }
        }
        if ($list.Count -gt 0) { return $list }
        return $defaults
    } catch {
        return $defaults
    }
}

function Expand-BackendPath {
    param([string]$p)
    if (-not $p) { return '' }
    return [Environment]::ExpandEnvironmentVariables($p)
}

function Get-BackendModels {
    param($def)
    if (-not (Test-PortListening -Port $def.port)) { return @() }
    if ($def.api -eq 'ollama') {
        $ps = Get-JsonQuick ('http://127.0.0.1:' + $def.port + '/api/ps')
        if ($ps -and $ps.models) { return @($ps.models | ForEach-Object { $_.name }) }
        return @()
    }
    $m = Get-JsonQuick ('http://127.0.0.1:' + $def.port + '/v1/models')
    if ($m) { return @($m.data | ForEach-Object { $_.id }) }
    return @()
}

function Get-LocalBackends {
    param([string]$Role = 'chat')   # chat=DSH 直连的 LLM；media=图片/视频/音频引擎
    $out = @()
    foreach ($def in Get-BackendRegistry) {
        if (-not $def.enabled) { continue }
        if ($Role -and ($def.role -ne $Role)) { continue }
        $up = Test-PortListening -Port $def.port
        $models = @(Get-BackendModels -def $def)
        $procCount = 0
        foreach ($pn in @($def.procs)) {
            if ($pn) { $procCount += @(Get-Process -Name $pn -ErrorAction SilentlyContinue).Count }
        }
        $variant = ''
        if ($def.kind -eq 'strata') { $variant = Get-StrataVariant }
        $out += [pscustomobject]@{
            kind = $def.kind; display = $def.display; role = $def.role; port = $def.port
            up = $up; serving = ($models.Count -gt 0); models = $models
            variant = $variant; procs = $procCount
            startCmd = (Expand-BackendPath $def.startCmd)
            stopCmd = (Expand-BackendPath $def.stopCmd)
            startExe = (Expand-BackendPath $def.startExe)
            startVbs = (Expand-BackendPath $def.startVbs)
            stopPs = (Expand-BackendPath $def.stopPs)
            stopProcs = @($def.stopProcs)
            api = $def.api
        }
    }
    return $out
}

function Start-LocalBackend {
    param($backend, [string]$Reason = 'manual')
    if (-not $backend) { return $false }
    if (-not (Test-AutoStartAllowed -Kind $backend.kind -Reason $Reason)) { return $false }
    # 用户手动停止过的后端，除手动启动外一律不碰
    if ($Reason -ne 'manual' -and (Test-UserStopped -Kind $backend.kind)) {
        Write-Host ('  [策略] ' + $backend.kind + ' 处于"手动停止"状态，来源=' + $Reason + ' 不启动') -ForegroundColor Yellow
        return $false
    }
    # 已经在加载/运行就不要重复启动（start 脚本常带"先停再启"，重复会杀掉加载中的实例）
    if (Test-PortListening -Port $backend.port) { return $false }
    if (@($backend.procs).Count -gt 0) {
        $running = 0
        foreach ($pn in @($backend.procs)) { $running += @(Get-Process -Name $pn -ErrorAction SilentlyContinue).Count }
        if ($running -gt 0) { return $false }
    }

    if ($backend.startCmd -and (Test-Path $backend.startCmd)) {
        Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', ('"' + $backend.startCmd + '"')) -WindowStyle Hidden
        return $true
    }
    if ($backend.startExe -and (Test-Path $backend.startExe)) {
        Start-Process -FilePath $backend.startExe -WindowStyle Hidden
        return $true
    }
    if ($backend.startVbs -and (Test-Path $backend.startVbs)) {
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $backend.startVbs + '"') -WindowStyle Hidden
        return $true
    }
    return $false
}

function Stop-LocalBackend {
    param($backend)
    if (-not $backend) { return $false }
    $did = $false
    if ($backend.stopCmd -and (Test-Path $backend.stopCmd)) {
        Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', ('"' + $backend.stopCmd + '"')) -WindowStyle Hidden -Wait
        $did = $true
    }
    if ($backend.stopPs -and (Test-Path $backend.stopPs)) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $backend.stopPs 2>&1 | Out-Null
        $did = $true
    }
    if (@($backend.stopProcs).Count -gt 0) {
        foreach ($pn in @($backend.stopProcs)) {
            Get-Process -Name $pn -ErrorAction SilentlyContinue |
                ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue; $did = $true }
        }
    }
    return $did
}
function Get-MediaBackends {
    # 媒体类引擎（ComfyUI / sd-server / 音频工具等）：按需启动，不参与保活
    return (Get-LocalBackends -Role 'media')
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
    $active = Get-ActiveBackend
    $userStop = $false
    if ($active.kind) { $userStop = Test-UserStopped -Kind $active.kind -JobsRoot $JobsRoot }

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
