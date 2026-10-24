# 公共库：配置加载、路径校验、显存等待、ComfyUI API 调用
# 用法（在 scripts\ 下的脚本里）：. "$PSScriptRoot\lib\common.ps1"

$script:RepoRoot   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:ConfigPath = Join-Path $script:RepoRoot 'config.ps1'
$script:SamplePath = Join-Path $script:RepoRoot 'config.sample.ps1'

function Write-Head  { param([string]$Text) Write-Host ''; Write-Host ("== " + $Text + " ==") -ForegroundColor Cyan }
function Write-Ok    { param([string]$Text) Write-Host ("  " + $Text) -ForegroundColor Green }
function Write-Info  { param([string]$Text) Write-Host ("  " + $Text) -ForegroundColor DarkGray }
function Write-Warn2 { param([string]$Text) Write-Host ("  " + $Text) -ForegroundColor Yellow }

function Get-PipelineConfig {
    if (Test-Path $script:ConfigPath) {
        . $script:ConfigPath
    } elseif (Test-Path $script:SamplePath) {
        Write-Warn2 '未找到 config.ps1，暂用 config.sample.ps1 的默认值'
        Write-Warn2 '建议：Copy-Item config.sample.ps1 config.ps1  然后改成你的路径'
        . $script:SamplePath
    } else {
        throw '找不到 config.ps1 或 config.sample.ps1'
    }
    if (-not $Cfg) { throw 'config 里没有 $Cfg 变量' }
    return $Cfg
}

function Fail {
    param([string]$Message)
    Write-Host ''
    Write-Host ("  ✗ " + $Message) -ForegroundColor Red
    exit 1
}

function Assert-FilePath {
    param([string]$Path, [string]$Label, [string]$Hint = '')
    if (-not $Path) { Fail ("未配置：{0}（请检查 config.ps1）" -f $Label) }
    if (-not (Test-Path $Path)) {
        $msg = "缺少 {0}：{1}" -f $Label, $Path
        if ($Hint) { $msg += "`n    提示：" + $Hint }
        Fail $msg
    }
    return (Resolve-Path $Path).Path
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    return $Path
}

function Get-Python {
    param($Config)
    if ($Config.ComfyPython -and (Test-Path $Config.ComfyPython)) { return $Config.ComfyPython }
    $p = Get-Command python -ErrorAction SilentlyContinue
    if ($p) { return $p.Source }
    throw '找不到 Python：请在 config.ps1 里配置 ComfyPython，并 pip install av pillow'
}

function Get-FreeVramMB {
    $out = & nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null
    if (-not $out) { return -1 }
    $first = ($out -split "`n")[0].Trim()
    $v = 0
    if ([int]::TryParse($first, [ref]$v)) { return $v }
    return -1
}

function Wait-FreeVram {
    param([int]$MinMB = 12000, [int]$TimeoutSec = 120)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $free = Get-FreeVramMB
        if ($free -lt 0) { return $true }          # 读不到就跳过等待
        if ($free -ge $MinMB) { return $true }
        Start-Sleep -Seconds 5
    }
    return ((Get-FreeVramMB) -ge $MinMB)
}

function Invoke-Exe {
    param([string]$Exe, [string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # 原生命令的 stderr 不该被当异常
    try {
        $out = & $Exe @Arguments 2>&1
        return @{ ExitCode = $LASTEXITCODE; Output = $out }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Test-ComfyUp {
    param([int]$Port)
    try { $null = Invoke-RestMethod ("http://127.0.0.1:{0}/system_stats" -f $Port) -TimeoutSec 3; return $true }
    catch { return $false }
}

function Start-ComfyIfNeeded {
    param($Config)
    if (Test-ComfyUp -Port $Config.ComfyPort) { return $false }
    if ($Config.ComfyStartCmd -and (Test-Path $Config.ComfyStartCmd)) {
        Write-Info ("启动 ComfyUI：" + $Config.ComfyStartCmd)
        & $Config.ComfyStartCmd
    } else {
        Write-Warn2 'ComfyUI 未运行，且未配置 ComfyStartCmd —— 请先手动启动'
    }
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Seconds 3
        if (Test-ComfyUp -Port $Config.ComfyPort) { return $true }
    }
    throw '等待 ComfyUI 启动超时（检查 ComfyStartCmd 或手动启动后重试）'
}

function Stop-ComfyIfOwned {
    param($Config, [bool]$StartedHere)
    if (-not $StartedHere) { return }
    if ($Config.ComfyStopCmd -and (Test-Path $Config.ComfyStopCmd)) {
        Write-Info '关闭本次启动的 ComfyUI'
        & $Config.ComfyStopCmd
    }
}

function Invoke-ComfyPrompt {
    param($Config, [hashtable]$Graph, [int]$TimeoutSec = 1800, [string]$DoneNode = '')
    $json = @{ prompt = $Graph } | ConvertTo-Json -Depth 12 -Compress
    $r = Invoke-RestMethod ("http://127.0.0.1:{0}/prompt" -f $Config.ComfyPort) -Method POST `
        -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 60
    $id = $r.prompt_id
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Seconds 3
        try { $h = Invoke-RestMethod ("http://127.0.0.1:{0}/history/{1}" -f $Config.ComfyPort, $id) -TimeoutSec 10 } catch { continue }
        if (-not $h.$id) { continue }
        if ($h.$id.status.status_str -eq 'error') {
            $msg = ($h.$id.status.messages | Where-Object { $_[0] -eq 'execution_error' } |
                    ForEach-Object { $_[1].exception_message }) -join ' | '
            return @{ Ok = $false; Error = $msg; Seconds = $sw.Elapsed.TotalSeconds }
        }
        if ($DoneNode) {
            if ($h.$id.outputs.$DoneNode) { return @{ Ok = $true; Outputs = $h.$id.outputs.$DoneNode; Seconds = $sw.Elapsed.TotalSeconds } }
        } elseif ($h.$id.outputs) {
            return @{ Ok = $true; Outputs = $h.$id.outputs; Seconds = $sw.Elapsed.TotalSeconds }
        }
    }
    return @{ Ok = $false; Error = '等待超时'; Seconds = $sw.Elapsed.TotalSeconds }
}

function Copy-ToComfyInput {
    param($Config, [string]$FilePath)
    $inDir = Join-Path $Config.ComfyRoot 'input'
    if (-not (Test-Path $inDir)) { throw ("ComfyUI input 目录不存在：" + $inDir) }
    $name = "pipe-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + [System.IO.Path]::GetExtension($FilePath)
    Copy-Item -LiteralPath $FilePath -Destination (Join-Path $inDir $name) -Force
    return $name
}

function Get-NewestFile {
    param([string]$Dir, [string]$Filter = '*.*')
    return (Get-ChildItem $Dir -Filter $Filter -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}
