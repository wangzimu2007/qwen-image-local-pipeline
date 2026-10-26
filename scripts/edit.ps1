# Qwen 编辑（Qwen-Image-Edit-2511 指令式编辑，不依赖 DSH）
#
# 与「Qwen 改图」的区别：
#   改图 = sd-cli 图生图，整体重绘，只能控制"改多大"
#   编辑 = 专门的编辑模型，能听懂指令，例如"把灯笼灯罩换成蓝色，其余保持不变"
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File D:\qwen-image-2.1\编辑.ps1
#   ... -Prompt "把天空换成星空，其余保持不变"
#   ... -Image "C:\Users\wangzimu\Desktop\Qwen 图片\qwen-20261023-011122.png"
#   ... -Steps 20            采样步数（默认 20，比 Turbo 的 8 步慢很多）
#   ... -KeepChatBackend     显存够时保留；不够自动卸载
#   ... -NoPause -NoOpen     自动化调用用
#
# 不给 -Image 时，自动取桌面「Qwen 图片」里最新的一张。
param(
    [string]$Image = '',
    [string]$Prompt,
    [int]$Steps = 20,
    [double]$CfgScale = 2.5,
    [double]$FlowShift = 3.0,
    [int]$Seed = -1,
    [int]$Width = 0,
    [int]$Height = 0,
    [string]$OutDir = '',
    [string]$RefImage = '',      # 第二张参考图（例如"把图2人物的衣服给图1"）
    [switch]$OffloadCpu,
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
$title0    = 'Qwen 编辑'

$exe      = Join-Path $root 'bin\sdcpp\sd-cli.exe'
$editRoot = Join-Path $root 'models\qwen-image-edit'
$dit      = Join-Path $editRoot 'diffusion_models\qwen-image-edit-2511-Q4_K_M.gguf'
$te       = Join-Path $editRoot 'text_encoders\Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf'
$mmproj   = Join-Path $editRoot 'text_encoders\mmproj-F16.gguf'
$vaeEdit  = Join-Path $editRoot 'vae\qwen_image_vae.safetensors'
$vaeOld   = Join-Path $root 'models\vae\qwen_image_2.1_vae_bf16.safetensors'

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
    param([int]$Seconds = 12)
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

# ---------- 前置检查 ----------
foreach($f in @($exe, $dit, $te)){
    if (-not (Test-Path $f)) {
        Write-Warning "缺少必要文件：$f"
        Write-Warning '编辑模型可能还没下载完，先确认下载已完成。'
        Pause-Brief 15
        exit 1
    }
}
$vae = if (Test-Path $vaeEdit) { $vaeEdit } else { $vaeOld }
$hasVision = Test-Path $mmproj

# ---------- 选图（可自行选择）----------
if (-not $Image -and -not $NoAsk) {
    Write-Host ''
    Write-Host '请选择要编辑的图片（取消 = 用文件夹里最新的一张）' -ForegroundColor Cyan
    $picked = Select-ImageFile -Title '选择要编辑的图片' -InitialDir $OutDir
    if ($picked) { $Image = $picked.Trim('"') }
}
if (-not $Image) {
    $newest = Get-ChildItem (Join-Path $OutDir '*.png') -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) {
        Write-Warning "输出目录里没有图片：$OutDir"
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
Write-Host "基于这张图编辑：$Image" -ForegroundColor Cyan

if (-not $Prompt) {
    $Prompt = Read-Host '请输入编辑指令（例如：把天空换成星空，其余保持不变）'
    if (-not $Prompt) {
        Write-Warning '没有输入编辑指令，已取消。'
        Pause-Brief 10
        exit 1
    }
}

# ---------- 选择输出分辨率 ----------
# 自动化（-NoPause / -NoAsk）时按底图比例缩到约 1.0 MP，保持宽高比（避免 4K 输入被压成方图）
function Get-FittedSize {
    param([int]$W, [int]$H, [int]$TargetPixels = 1048576)
    if ($W -le 0 -or $H -le 0) { return @(1024, 1024) }
    $scale = [Math]::Sqrt($TargetPixels / [double]($W * $H))
    if ($scale -gt 1.0) { $scale = 1.0 }
    $nw = [int]([Math]::Round($W * $scale / 8.0) * 8)
    $nh = [int]([Math]::Round($H * $scale / 8.0) * 8)
    if ($nw -lt 256) { $nw = 256 }
    if ($nh -lt 256) { $nh = 256 }
    return @($nw, $nh)
}

if ($Width -le 0 -or $Height -le 0) {
    if ($NoAsk -or $NoPause) {
        $srcSize = Get-ImageSize $Image
        $fit = Get-FittedSize -W $srcSize[0] -H $srcSize[1]
        $Width = $fit[0]; $Height = $fit[1]
        Write-Host ("自动化模式：按底图比例缩到 {0} × {1}（约 1.0 MP，保持宽高比）" -f $Width, $Height) -ForegroundColor Green
    } else {
        $size = Select-Resolution -DefaultWidth 1024 -DefaultHeight 1024
        if ($size[0] -eq 0 -or $size[1] -eq 0) {
            $srcSize = Get-ImageSize $Image
            $fit = Get-FittedSize -W $srcSize[0] -H $srcSize[1]
            $Width = $fit[0]; $Height = $fit[1]
            Write-Host ("跟随底图比例：{0} × {1}" -f $Width, $Height) -ForegroundColor Green
        } else {
            $Width = $size[0]; $Height = $size[1]
        }
    }
}
if ($Width -lt 256) { $Width = 1024 }
if ($Height -lt 256) { $Height = 1024 }
Write-Host ("输出分辨率：{0} × {1}" -f $Width, $Height) -ForegroundColor Green

# ---------- 路由提醒（防止把"小修"送进 AI 编辑，190 秒 vs 0.2 秒）----------
if ($Prompt -match '裁|缩放|缩小|放大|调亮|调暗|对比|饱和|锐化|水印|加字|边框|圆角|转格式|抹|去掉.*(点|斑|痣|污|杂物|水印)|拼图') {
    Write-Host ''
    Write-Host '  ⚠ 路由提醒：你这次的描述看起来是「确定性小修」' -ForegroundColor Yellow
    Write-Host '    这类需求用修图更快（0.2~1 秒，不占显存）：' -ForegroundColor Yellow
    Write-Host '      D:\qwen-image-2.1\修图.ps1 -Image ... -Ops "blurfill=x1,y1,x2,y2,22"' -ForegroundColor Yellow
    Write-Host '      （裁剪 cropc / 缩放 resize / 调色 color|boxcolor / 水印 wtext / 转格式 format）' -ForegroundColor Yellow
    Write-Host '    只有「换物体、换背景、改风格」才需要走本脚本（约 190 秒）。' -ForegroundColor DarkGray
    Write-Host ''
}

if (Test-HttpUp 'http://127.0.0.1:1234/v1/models') {
    Write-Warning '检测到 DSH 生图服务（端口 1234）正在运行，它占着显存。'
    Write-Warning '请先双击「Qwen 生图 - 停止」再编辑。'
    Pause-Brief 12
    exit 1
}


$outPath = Get-NextImagePath -OutDir $OutDir -Kind 'edit'

$Failed = $false

$vramState = $null
# ================= 主体 =================
try {
    # ---------- 1. 按需快照 / 释放显存 ----------
    $needMB = 20000
    if ($KeepChatBackend) {
        Write-Host '已指定 -KeepChatBackend；显存不足时仍会自动快照卸载。' -ForegroundColor DarkGray
    }
    $vramState = Ensure-VramForImage -NeedMiB $needMB -TimeoutSeconds 150
    $freeNow = Get-FreeVramMiB
    if ($freeNow -lt 19000) {
        throw ("显存仍不足（{0} MiB），停止出图。" -f $freeNow)
    }
    # ---------- 2. 编辑 ----------
    Write-Host ''
    Write-Host ("编辑模型：Qwen-Image-Edit-2511  步数 {0}  CFG {1}" -f $Steps, $CfgScale) -ForegroundColor DarkGray
    Set-Title "$title0 - 正在编辑"

    $baseArgs = @(
        '--diffusion-model', $dit,
        '--vae', $vae,
        '--llm', $te,
        '--cfg-scale', "$CfgScale",
        '--sampling-method', 'euler',
        '--flow-shift', "$FlowShift",
        '--steps', "$Steps",
        '--diffusion-fa',
        '-W', "$Width",
        '-H', "$Height",
        '-r', $Image,
        '-p', $Prompt,
        '-o', $outPath
    )
    if ($hasVision) { $baseArgs += @('--llm_vision', $mmproj) }
    if ($RefImage) {
        if (-not (Test-Path $RefImage)) { throw ("第二张参考图不存在：{0}" -f $RefImage) }
        $baseArgs += @('-r', $RefImage)
        Write-Host ("第二张参考图：{0}" -f $RefImage) -ForegroundColor DarkGray
    }
    if ($Seed -ge 0) { $baseArgs += @('--seed', "$Seed") }
    if ($OffloadCpu) { $baseArgs += '--offload-to-cpu' }

    # 2511 必须开启 zero_cond_t，否则编辑质量明显退化。
    # 本机引擎通过 --model-args 暴露；若旧构建只认专用开关，则回退尝试。
    $variants = @(
        @{ Name = '--model-args qwen_image_zero_cond_t=1'; Extra = @('--model-args', 'qwen_image_zero_cond_t=1') },
        @{ Name = '--qwen-image-zero-cond-t';              Extra = @('--qwen-image-zero-cond-t') },
        @{ Name = '（不启用 zero_cond_t，画质可能下降）';   Extra = @() }
    )

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $ok = $false
    $genStart = Get-Date
    foreach ($v in $variants) {
        Write-Host ("尝试参数：{0}" -f $v.Name) -ForegroundColor DarkGray
        & $exe @($baseArgs + $v.Extra)
        $code = $LASTEXITCODE
        if ($code -eq 0 -and (Test-Path $outPath) -and ((Get-Item $outPath).LastWriteTime -ge $genStart.AddSeconds(-5))) { $ok = $true; break }
        Write-Host ("  该参数组合失败（退出码 {0}），尝试下一种…" -f $code) -ForegroundColor DarkYellow
    }
    $ErrorActionPreference = $prevEap
    Set-Title $title0
    Start-Sleep -Seconds 1

    # ---------- 3. 打开结果 ----------
    if ($ok -and (Test-Path $outPath)) {
        Write-Host ''
        Write-Host "编辑完成：$outPath" -ForegroundColor Green
Write-MediaMeta -Path $outPath -Extra @{ Model = "Qwen-Image-Edit-2511"; Prompt = $Prompt; Steps = "$Steps"; Cfg = "$CfgScale"; Size = ("{0}x{1}" -f $Width, $Height) }
try { . (Join-Path $PSScriptRoot '_info.ps1'); Show-MediaInfo -Path $outPath -Extra @{ '模型' = 'Qwen-Image-Edit-2511' } } catch {}
        if (-not $NoOpen) {
            try {
                Start-Process -FilePath $outPath
                Write-Host '已用默认看图程序打开。' -ForegroundColor Green
            } catch { Write-Warning "自动打开失败：$($_.Exception.Message)" }
        }
    } else {
        $Failed = $true
        Write-Warning '编辑没有产出图片，请检查上面的日志。'
        Write-Warning '如果是显存不足，试试加 -OffloadCpu 参数。'
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
