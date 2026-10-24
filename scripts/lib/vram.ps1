# 显存快照 / 释放 / 恢复（共享模块）
# 用法：. "$PSScriptRoot\lib\vram.ps1"   然后
#   $state = Start-VramPrep -Config $Cfg
#   ... 生成 ...
#   Restore-VramPrep -Config $Cfg -State $state
#
# 设计：把正在服务的本地聊天后端（Strata / Ollama）快照下来，停掉腾显存，
# 生成结束后原样恢复。状态文件放在 <repo>\.state\chat-backend.json，
# 与其它工具的状态文件分开，避免互相覆盖。

. "$PSScriptRoot\common.ps1"

function Get-VramStatePath {
    param($Config)
    $dir = $Config.VramStateDir
    if (-not $dir) { $dir = Join-Path $script:RepoRoot '.state' }
    Ensure-Dir $dir | Out-Null
    return (Join-Path $dir 'chat-backend.json')
}

function Get-VramStrataVariant {
    param([string]$ModelId)
    if ($ModelId -match 'nvfp4') { return 'nvfp4' }
    if ($ModelId -match 'iq3')   { return 'iq3s' }
    return ''
}

function Get-ChatBackends {
    param($Config)
    $strataUrl = if ($Config.StrataUrl) { $Config.StrataUrl } else { 'http://127.0.0.1:8080' }
    $ollamaUrl = if ($Config.OllamaUrl) { $Config.OllamaUrl } else { 'http://127.0.0.1:11434' }
    $list = New-Object System.Collections.ArrayList

    $r = $null
    try { $r = Invoke-RestMethod -Uri ($strataUrl + '/v1/models') -TimeoutSec 3 } catch { }
    if ($r -and $r.data) {
        $mid = ($r.data | Select-Object -First 1).id
        [void]$list.Add([pscustomobject]@{ kind = 'strata'; variant = (Get-VramStrataVariant $mid); modelId = $mid })
    }

    $ps = $null
    try { $ps = Invoke-RestMethod -Uri ($ollamaUrl + '/api/ps') -TimeoutSec 3 } catch { }
    if ($ps -and $ps.models) {
        $names = @($ps.models | ForEach-Object { $_.name })
        if ($names.Count -gt 0) { [void]$list.Add([pscustomobject]@{ kind = 'ollama'; models = $names }) }
    }
    return ,$list
}

function Stop-StrataBackend {
    param($Config, [string]$Variant)
    $actions = if ($Config.StrataActionsDir) { $Config.StrataActionsDir } else { Join-Path $env:LOCALAPPDATA 'Strata\actions' }
    $stopCmd = if ($Variant -eq 'nvfp4') { 'stop-nvfp4.cmd' } else { 'stop-iq3s.cmd' }
    $path = Join-Path $actions $stopCmd
    if (-not (Test-Path $path)) { $path = Join-Path $actions 'stop-iq3s.cmd' }
    if (Test-Path $path) { & cmd /c "`"$path`"" | Out-Null; return $true }
    Write-Warn2 ("找不到 Strata 停止脚本：" + $path)
    return $false
}

function Start-StrataBackend {
    param($Config, [string]$Variant, [int]$TimeoutSec = 420)
    $actions = if ($Config.StrataActionsDir) { $Config.StrataActionsDir } else { Join-Path $env:LOCALAPPDATA 'Strata\actions' }
    $startCmd = if ($Variant -eq 'nvfp4') { 'start-nvfp4.cmd' } else { 'start-iq3s.cmd' }
    $path = Join-Path $actions $startCmd
    if (-not (Test-Path $path)) { Write-Warn2 ("找不到 Strata 启动脚本：" + $path); return $false }
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "`"$path`"" -WindowStyle Minimized
    $strataUrl = if ($Config.StrataUrl) { $Config.StrataUrl } else { 'http://127.0.0.1:8080' }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Seconds 3
        try { $null = Invoke-RestMethod -Uri ($strataUrl + '/v1/models') -TimeoutSec 3; return $true } catch { }
    }
    return $false
}

function Unload-OllamaModels {
    param($Config, [string[]]$Models)
    $ollamaUrl = if ($Config.OllamaUrl) { $Config.OllamaUrl } else { 'http://127.0.0.1:11434' }
    foreach ($m in $Models) {
        try {
            $body = @{ model = $m; keep_alive = 0 } | ConvertTo-Json -Compress
            Invoke-RestMethod -Uri ($ollamaUrl + '/api/generate') -Method POST `
                -ContentType 'application/json' -Body $body -TimeoutSec 30 | Out-Null
        } catch { Write-Warn2 ("卸载 {0} 失败：{1}" -f $m, $_.Exception.Message) }
    }
}

function Load-OllamaModels {
    param($Config, [string[]]$Models)
    $ollamaUrl = if ($Config.OllamaUrl) { $Config.OllamaUrl } else { 'http://127.0.0.1:11434' }
    foreach ($m in $Models) {
        try {
            $body = @{ model = $m; keep_alive = '30m'; prompt = '' } | ConvertTo-Json -Compress
            Invoke-RestMethod -Uri ($ollamaUrl + '/api/generate') -Method POST `
                -ContentType 'application/json' -Body $body -TimeoutSec 60 | Out-Null
            Write-Ok ("已重新加载 Ollama 模型：" + $m)
        } catch { Write-Warn2 ("重新加载 {0} 失败：{1}" -f $m, $_.Exception.Message) }
    }
}

function Start-VramPrep {
    param($Config, [int]$NeedMB = 16000, [int]$TimeoutSec = 180)
    $statePath = Get-VramStatePath -Config $Config
    if (Test-Path $statePath) {
        Write-Info '清理上次残留的快照文件'
        Remove-Item $statePath -Force -ErrorAction SilentlyContinue
    }
    $backends = Get-ChatBackends -Config $Config
    if (@($backends).Count -eq 0) {
        Write-Info '没有本地模型在提供服务，不涉及恢复'
        $free = Wait-FreeVram -MinMB $NeedMB -TimeoutSec 20
        Write-Info ("可用显存 " + $free + " MB")
        return $null
    }

    $state = [pscustomobject]@{ capturedAt = (Get-Date).ToString('o'); backends = @($backends) }
    $state | ConvertTo-Json -Depth 6 | Set-Content -Path $statePath -Encoding UTF8

    foreach ($b in @($backends)) {
        if ($b.kind -eq 'strata') {
            Write-Warn2 ("检测到 Strata {0}（{1}），停止以腾显存" -f $b.variant, $b.modelId)
            Stop-StrataBackend -Config $Config -Variant $b.variant | Out-Null
        } elseif ($b.kind -eq 'ollama') {
            Write-Warn2 ("检测到 Ollama 模型（{0}），卸载" -f (@($b.models) -join ', '))
            Unload-OllamaModels -Config $Config -Models $b.models
        }
    }
    Start-Sleep -Seconds 3

    # 自适应等待：达到阈值立即继续；连续 9 秒不再增长且 >=9000MB 也继续
    $free = 0; $last = -1; $stable = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $free = Get-FreeVramMB
        if ($free -ge $NeedMB) { break }
        if ($free -eq $last) { $stable++ } else { $stable = 0; $last = $free }
        if ($stable -ge 3 -and $free -ge 9000) { break }
        Start-Sleep -Seconds 3
    }
    if ($free -ge $NeedMB) { Write-Info ("显存已就绪：" + $free + " MB") }
    elseif ($free -ge 9000) { Write-Info ("显存停止增长，" + $free + " MB 可用，继续") }
    else { Write-Warn2 ("显存只有 " + $free + " MB，可能失败") }
    return $state
}

function Restore-VramPrep {
    param($Config, $State)
    $statePath = Get-VramStatePath -Config $Config
    $restorable = @()
    if ($State) { $restorable = @($State.backends) | Where-Object { $_ -ne $null } }
    elseif (Test-Path $statePath) {
        try { $saved = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json; $restorable = @($saved.backends) | Where-Object { $_ -ne $null } }
        catch { Write-Warn2 ('快照文件损坏，跳过恢复：' + $_.Exception.Message) }
    }
    if (@($restorable).Count -eq 0) { Remove-Item $statePath -Force -ErrorAction SilentlyContinue; return }

    Write-Head '恢复显存快照'
    foreach ($b in @($restorable)) {
        if ($b.kind -eq 'strata') {
            $v = "$($b.variant)"; if (-not $v) { $v = 'iq3s' }
            Write-Info ("恢复 Strata（{0}），最长等 420 秒" -f $v)
            if (Start-StrataBackend -Config $Config -Variant $v) { Write-Ok 'Strata 已就绪' }
            else { Write-Warn2 'Strata 未在超时内就绪，请手动启动' }
        } elseif ($b.kind -eq 'ollama') {
            Load-OllamaModels -Config $Config -Models $b.models
        }
    }
    Remove-Item $statePath -Force -ErrorAction SilentlyContinue
}
