# Qwen 改图（基于已有图片 + 新提示词重绘，不依赖 DSH）
#
# 原理：sd-cli 的图生图（--init-img + --strength）。原图的构图、光影、
#       大致内容会被保留，只用新提示词重绘，改动力度由 -Strength 控制。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File D:\qwen-image-2.1\改图.ps1
#   ... -Prompt "改成夜晚，星空，灯塔亮着"
#   ... -Image "C:\Users\wangzimu\Desktop\Qwen 图片\qwen-20261023-011122.png"
#   ... -Strength 0.85            改动力度（实测：0.7 以下几乎不变，0.85 整体重绘，0.9 以上脱离原图）
#   ... -KeepChatBackend          显存够时保留；不够自动卸载
#   ... -NoPause -NoOpen          自动化调用用
#
# 不给 -Image 时，自动取桌面「Qwen 图片」里最新的一张。
param(
    [string]$Image = '',
    [string]$Prompt,
    [double]$Strength = 0.85,
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
$title0    = 'Qwen 改图'
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

# ---------- 选图（可自行选择）----------
if (-not $Image -and -not $NoAsk) {
    Write-Host ''
    Write-Host '请选择要修改的图片（取消 = 用文件夹里最新的一张）' -ForegroundColor Cyan
    $picked = Select-ImageFile -Title '选择要修改的图片' -InitialDir $OutDir
    if ($picked) { $Image = $picked.Trim('"') }
}
if (-not $Image) {
    $newest = Get-ChildItem (Join-Path $OutDir '*.png') -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) {
        Write-Warning "输出目录里没有图片：$OutDir"
        Write-Warning '请先用「Qwen 画图 - 一次性」生成一张，或用 -Image 指定路径。'
        Pause-Brief 12
        exit 1
    }
    $Image = $newest.FullName
}
if (-not (Test-Path $Image)) {
    Write-Warning "找不到图片：$Image"
    Pause-Brief 12
    exit 1
}
Write-Host "基于这张图修改：$Image" -ForegroundColor Cyan

# ---------- 提示词 ----------
if (-not $Prompt) {
    $Prompt = Read-Host '请输入修改要求（例如：改成夜晚，星空，灯塔亮着）'
    if (-not $Prompt) {
        Write-Warning '没有输入修改要求，已取消。'
        Pause-Brief 10
        exit 1
    }
}

if ($Strength -lt 0.75 -or $Strength -gt 0.9) {
    Write-Warning "-Strength 建议在 0.75~0.9 之间（现在是 $Strength）。这个模型 0.7 以下几乎不改、0.9 以上会脱离原图。"
}

# ---------- 选择输出分辨率（改图前由你来定）----------
if (-not $NoAsk -and -not ($PSBoundParameters.ContainsKey('Width') -or $PSBoundParameters.ContainsKey('Height'))) {
    $size = Select-Resolution -DefaultWidth 1024 -DefaultHeight 1024
    if ($size[0] -eq 0 -or $size[1] -eq 0) {
        # 跟随底图尺寸
        $src = Get-ImageSize $Image
        if ($src[0] -gt 0) {
            $Width  = Format-Dimension $src[0]
            $Height = Format-Dimension $src[1]
            Write-Host ("跟随底图：{0} × {1}" -f $Width, $Height) -ForegroundColor Green
        } else {
            Write-Warning '读不到底图尺寸，改用 1024×1024'
        }
    } elseif ($size[0] -gt 0) {
        $Width = $size[0]; $Height = $size[1]
    }
    Write-Host ("输出分辨率：{0} × {1}" -f $Width, $Height) -ForegroundColor Green
}

# ---------- 前置检查 ----------
if (Test-HttpUp 'http://127.0.0.1:1234/v1/models') {
    Write-Warning '检测到 DSH 生图服务（端口 1234）正在运行，它占着显存。'
    Write-Warning '请先双击「Qwen 生图 - 停止」再改图。'
    Pause-Brief 12
    exit 1
}


$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$outPath = Get-NextImagePath -OutDir $OutDir -Kind 'redraw'

$Failed = $false

$vramState = $null
# ================= 主体：记录 → 改图 → 恢复，无论成败都清理状态文件 =================
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
    # ---------- 2. 改图 ----------
    Write-Host ''
    Write-Host ("重绘强度 {0}（实测：0.7 以下几乎不变 / 0.85 整体重绘 / 0.9 以上脱离原图）" -f $Strength) -ForegroundColor DarkGray
    Set-Title "$title0 - 正在重绘"
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $genStart = Get-Date
    $genExit  = 1
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $genStart = Get-Date
        & (Join-Path $root 'generate.ps1') -Prompt $Prompt -Width $Width -Height $Height -Out $outPath `
            -InitImage $Image -Strength $Strength
        $genExit = $LASTEXITCODE
        $okRun = ($genExit -eq 0) -and (Test-Path $outPath) -and ((Get-Item $outPath).LastWriteTime -ge $genStart.AddSeconds(-5))
        if ($okRun) { break }
        if ($attempt -eq 1) {
            Write-Warning ("改图失败（sd-cli 退出码 {0}），清理后重试一次..." -f $genExit)
            Start-Sleep -Seconds 8
        }
    }
    Set-Title $title0
    Start-Sleep -Seconds 1

    # ---------- 3. 严格校验（只认本次新文件）----------
    $fresh = (Test-Path $outPath) -and ((Get-Item $outPath).LastWriteTime -ge $genStart.AddSeconds(-5))
    if (-not $fresh) {
        $Failed = $true
        Write-Host ''
        Write-Host ("改图失败：sd-cli 退出码 {0}，本次没有产生新图片。" -f $genExit) -ForegroundColor Red
    }
    if ($fresh -and (Test-Path $outPath)) {
        Write-Host ''
        Write-Host "改好的图：$outPath" -ForegroundColor Green
Write-MediaMeta -Path $outPath -Extra @{ Model = "Qwen-Image 2.1 Turbo (img2img)"; Prompt = $Prompt; Strength = "$Strength" }
try { . (Join-Path $PSScriptRoot '_info.ps1'); Show-MediaInfo -Path $outPath -Extra @{ '模型' = 'Qwen-Image 2.1 Turbo（图生图）'; '强度' = $Strength } } catch {}
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
