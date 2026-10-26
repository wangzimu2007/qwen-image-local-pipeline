# Qwen 画图（一次性出图，不依赖 DSH）
#
# 行为：
#   1. 检测出图前是否有本地聊天模型「正在提供服务」（Strata IQ3_S / NVFP4 / Ollama）——
#      只认 8080 / 11434 上的真实响应，不靠进程名猜
#   2. 有就停掉释放显存，没有就直接出图
#   3. 用 sd-cli.exe 出图，出完自动用系统默认看图程序打开
#   4. 自动恢复第 1 步记录的那个模型，不再询问
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File D:\qwen-image-2.1\画图.ps1
#   ... -Prompt "清晨的江南水乡，薄雾，写实电影感"
#   ... -Width 1280 -Height 720   指定分辨率（默认 1024×1024）
#   ... -OutDir "路径"            指定输出目录（默认桌面「Qwen 图片」）
#   ... -KeepChatBackend          显存够时保留；不够自动卸载
#   ... -NoPause -NoOpen          自动化调用用
#   ... -NoAsk                    不弹出分辨率菜单（用默认的 -Width/-Height）
param(
    [string]$Prompt,
    [int]$Width = 1024,
    [int]$Height = 1024,
    [string]$OutDir = '',
    [switch]$KeepChatBackend,
    [switch]$NoPause,
    [switch]$NoOpen,
    [switch]$NoAsk
)

$ErrorActionPreference = 'Stop'
$root      = 'D:\qwen-image-2.1'
$actions   = Join-Path $env:LOCALAPPDATA 'Strata\actions'
$stateFile = Join-Path $root '.chat-backend-state.json'
$ollamaApp = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'
$title0    = 'Qwen 画图'
if (-not $OutDir) { $OutDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Qwen 图片' }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# 共用交互组件（选图 / 选分辨率）
. (Join-Path $root '_ui.ps1')
. (Join-Path $PSScriptRoot '_vram.ps1')
. (Join-Path $PSScriptRoot '_meta.ps1')
$vramLockOk = Enter-ImageVramLock -TimeoutSeconds 300
if (-not $vramLockOk) { exit 3 }

function Set-Title {
    param([string]$Text)
    try { $Host.UI.RawUI.WindowTitle = $Text } catch { }
}
Set-Title $title0

function Pause-Brief {
    param([int]$Seconds = 10)
    if ($NoPause) { return }
    Write-Host ''
    Write-Host "窗口将在 $Seconds 秒后自动关闭..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $Seconds
}

function Test-HttpUp {
    param([string]$Url)
    try { $null = Invoke-RestMethod -Uri $Url -TimeoutSec 3; return $true } catch { return $false }
}

function Wait-UntilUp {
    param([string]$Url, [int]$Seconds = 200, [string]$Label = '服务')
    for ($i = 0; $i -lt [int]($Seconds / 2); $i++) {
        Start-Sleep -Seconds 2
        if (Test-HttpUp $Url) { return $true }
        if ($i % 5 -eq 4) { Write-Host ("  等待 {0}… 已 {1} 秒" -f $Label, (($i + 1) * 2)) -ForegroundColor DarkGray }
    }
    return $false
}

function Get-StrataVariant {
    param([string]$ModelId)
    if ($ModelId -match 'nvfp4') { return 'nvfp4' }
    if ($ModelId -match 'iq3')   { return 'iq3_s' }
    return ''
}

function Get-ChatBackendsLegacy {
    $list = New-Object System.Collections.ArrayList
    $r = $null
    try { $r = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/models' -TimeoutSec 3 } catch { }
    if ($r -and $r.data) {
        $mid = ($r.data | Select-Object -First 1).id
        [void]$list.Add([pscustomobject]@{ kind = 'strata'; variant = (Get-StrataVariant $mid); modelId = $mid })
    } elseif (Get-Process -Name 'strata' -ErrorAction SilentlyContinue) {
        Write-Host '提示：有 strata 进程，但 8080 没有响应，视为未在提供服务，不处理它。' -ForegroundColor DarkGray
    }
    $ps = $null
    try { $ps = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/ps' -TimeoutSec 3 } catch { }
    if ($ps -and $ps.models) {
        $names = @($ps.models | ForEach-Object { $_.name })
        if ($names.Count -gt 0) { [void]$list.Add([pscustomobject]@{ kind = 'ollama'; models = $names }) }
    }
    return ,$list
}

# ---------- 提示词 ----------
if (-not $Prompt) {
    $Prompt = Read-Host '请输入画面描述（例如：清晨的江南水乡，薄雾，写实电影感）'
    if (-not $Prompt) {
        Write-Warning '没有输入画面描述，已取消。'
        Pause-Brief 10
        exit 1
    }
}

# ---------- 选择输出分辨率（出图前由你来定）----------
if (-not $NoAsk -and -not ($PSBoundParameters.ContainsKey('Width') -or $PSBoundParameters.ContainsKey('Height'))) {
    $size = Select-Resolution -DefaultWidth 1024 -DefaultHeight 1024
    if ($size[0] -gt 0) {
        $Width = $size[0]; $Height = $size[1]
        Write-Host ("输出分辨率：{0} × {1}" -f $Width, $Height) -ForegroundColor Green
    }
}

# ---------- 前置检查 ----------
if (Test-HttpUp 'http://127.0.0.1:1234/v1/models') {
    Write-Warning '检测到 DSH 生图服务（端口 1234）正在运行，它占着显存。'
    Write-Warning '请先双击「Qwen 生图 - 停止」再画图。'
    Pause-Brief 12
    exit 1
}


$outPath = Get-NextImagePath -OutDir $OutDir -Kind 't2i'
$Failed  = $false

$vramState = $null
# ================= 主体：记录 → 出图 → 恢复，无论成败都清理状态文件 =================
try {
    # ---------- 1. 按需快照 / 释放显存 ----------
    $needMB = 17000
    if ($KeepChatBackend) {
        Write-Host '已指定 -KeepChatBackend；显存不足时仍会自动快照卸载。' -ForegroundColor DarkGray
    }
    $vramState = Ensure-VramForImage -NeedMiB $needMB -TimeoutSeconds 150
    $freeNow = Get-FreeVramMiB
    if ($freeNow -lt 16000) {
        throw ("显存仍不足（{0} MiB），停止出图。" -f $freeNow)
    }
    # ---------- 2. 出图（失败自动重试一次）----------
    Write-Host ''
    Set-Title "$title0 - 正在生成"
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $genStart = Get-Date
    $genExit  = 1
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $genStart = Get-Date
        & (Join-Path $root 'generate.ps1') -Prompt $Prompt -Width $Width -Height $Height -Out $outPath
        $genExit = $LASTEXITCODE
        $ok = ($genExit -eq 0) -and (Test-Path $outPath) -and ((Get-Item $outPath).LastWriteTime -ge $genStart.AddSeconds(-5))
        if ($ok) { break }
        if ($attempt -eq 1) {
            Write-Warning ("出图失败（sd-cli 退出码 {0}），清理后重试一次..." -f $genExit)
            Start-Sleep -Seconds 8
        }
    }
    $ErrorActionPreference = $prevEap
    Set-Title $title0
    Start-Sleep -Seconds 1

    # ---------- 3. 校验输出（只认本次新产生的文件，绝不拿旧图冒充）----------
    $fresh = (Test-Path $outPath) -and ((Get-Item $outPath).LastWriteTime -ge $genStart.AddSeconds(-5))
    if (-not $fresh) {
        $latest = Get-ChildItem (Join-Path $OutDir '*.png') -ErrorAction SilentlyContinue |
                  Where-Object { $_.LastWriteTime -ge $genStart.AddSeconds(-5) } |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) { $outPath = $latest.FullName; $fresh = $true }
    }
    if (-not $fresh) {
        $Failed = $true
        Write-Host ''
        Write-Host ("出图失败：sd-cli 退出码 {0}，本次没有产生任何新图片。" -f $genExit) -ForegroundColor Red
        Write-Host '  常见原因：显存不足、CUDA 初始化失败。请看上面的 sd-cli 日志。' -ForegroundColor Red
    }
    if ($fresh -and (Test-Path $outPath)) {
        Write-Host ''
        Write-Host "图片已生成：$outPath" -ForegroundColor Green
Write-MediaMeta -Path $outPath -Extra @{ Model = "Qwen-Image 2.1 Turbo"; Prompt = $Prompt; Size = ("{0}x{1}" -f $Width, $Height) }
try { . (Join-Path $PSScriptRoot '_info.ps1'); Show-MediaInfo -Path $outPath -Extra @{ '模型' = 'Qwen-Image 2.1 Turbo' } } catch {}
        if (-not $NoOpen) {
            try {
                Start-Process -FilePath $outPath
                Write-Host '已用默认看图程序打开。' -ForegroundColor Green
            } catch {
                Write-Warning "自动打开失败，请手动打开上面的路径：$($_.Exception.Message)"
            }
        }
    }
}
finally {
    # ---------- 4. 自动恢复 ----------
    Restore-VramPrep $vramState
    Exit-ImageVramLock
    Set-Title $title0
    Pause-Brief
}
if ($Failed) { exit 1 }
exit 0
