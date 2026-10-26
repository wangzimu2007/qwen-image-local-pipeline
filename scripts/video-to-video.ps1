# 视频生视频：把一段已有视频按提示词重新绘制/改造
#
# 实现方式（不需要 VACE/H3，纯本地现有模型）：
#   1. 按 -Every 抽关键帧（例如每 4 帧抽 1 张）
#   2. 每一张关键帧用「Qwen 改图（图生图）」按提示词重绘
#   3. 重绘后的关键帧按顺序合成低帧率视频（fps = 原fps / Every）
#   4. 用 FILM 插帧 ×Every 补回原帧率，得到风格化的成片
#
# 代价：每张关键帧约 20~30 秒。5 秒视频（121 帧）用 -Every 8 → 16 帧 ≈ 7~8 分钟。
#       想要更快就加大 -Every（画面连贯性会下降）。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File D:\qwen-image-2.1\视频生视频.ps1 -Video "某视频.mp4" -Prompt "水彩画风格，柔和笔触" -Every 8 -Strength 0.55 -NoPause
param(
    [Parameter(Mandatory = $true)]
    [string]$Video,
    [string]$Prompt = '水彩画风格，柔和笔触，纸质感',
    [int]$Every = 8,
    [double]$Strength = 0.55,
    [int]$Width = 0,
    [int]$Height = 0,
    [switch]$KeepFrames,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$root     = 'D:\qwen-image-2.1'
$akiPy    = 'D:\ComfyUI-aki-v3.2\python\python.exe'
$desk     = [Environment]::GetFolderPath('Desktop')
$videoDir = Join-Path $desk '视频'
$outDir   = Join-Path $desk 'ComfyUI 输出'
$tools    = Join-Path $root '_video_tools.py'
$imgTool  = Join-Path $root '改图.ps1'
$post     = Join-Path $root '后期处理.ps1'
$organize = Join-Path $root '整理视频.ps1'
$work     = Join-Path $env:TEMP 'dsh-v2v'
$rawDir   = Join-Path $work 'frames'
$styledDir= Join-Path $work 'styled'

function Pause-Brief { param([int]$S = 8) if ($NoPause) { return }; Write-Host ''; Write-Host "窗口将在 $S 秒后自动关闭..." -ForegroundColor DarkGray; Start-Sleep -Seconds $S }

if (-not (Test-Path $Video)) { Write-Warning "找不到视频：$Video"; Pause-Brief 10; exit 1 }
if ($Every -lt 1) { $Every = 1 }
$Video = (Resolve-Path $Video).Path
New-Item -ItemType Directory -Force -Path $rawDir, $styledDir | Out-Null

# 清空上次残留
Get-ChildItem $rawDir -Filter '*.png' -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem $styledDir -Filter '*.png' -ErrorAction SilentlyContinue | Remove-Item -Force

Write-Host ("输入：{0}" -f (Split-Path $Video -Leaf)) -ForegroundColor Cyan
$infoText = & $akiPy $tools info $Video 2>&1
Write-Host ('  ' + $infoText)
$srcFps = 24.0
if ($infoText -match 'fps=([\d\.]+)') { $srcFps = [double]$Matches[1] }
if ($Width -le 0 -or $Height -le 0) {
    if ($infoText -match 'size=(\d+)x(\d+)') { $Width = [int]$Matches[1]; $Height = [int]$Matches[2] }
    else { $Width = 832; $Height = 480 }
}
$targetFps = [math]::Max(2, [int][math]::Round($srcFps / $Every))
Write-Host ("抽帧间隔 {0}，重绘后 {1} fps，再用插帧 ×{0} 补回 {2} fps" -f $Every, $targetFps, [int]$srcFps) -ForegroundColor Cyan
Write-Host ("每张关键帧约 20~30 秒，请耐心等待" ) -ForegroundColor DarkGray

# ---------- 1. 抽关键帧 ----------
& $akiPy $tools frames $Video $rawDir $Every 2>&1 | ForEach-Object { '  ' + $_ }
$rawFrames = Get-ChildItem $rawDir -Filter 'f*.png' | Sort-Object Name
if (-not $rawFrames) { Write-Warning '抽帧失败'; Pause-Brief 10; exit 1 }
Write-Host ("共 {0} 张关键帧，开始逐张重绘..." -f @($rawFrames).Count) -ForegroundColor Yellow

# ---------- 2. 逐张重绘 ----------
$i = 0
$swAll = [Diagnostics.Stopwatch]::StartNew()
foreach ($f in $rawFrames) {
    $i++
    $idx = [int]($f.BaseName -replace 'f','')
    Write-Host ("  [{0}/{1}] {2}" -f $i, @($rawFrames).Count, $f.Name) -ForegroundColor DarkGray
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $imgLog = & powershell -NoProfile -ExecutionPolicy Bypass -File $imgTool `
            -Image $f.FullName -Prompt $Prompt -Strength $Strength `
            -Width $Width -Height $Height -OutDir $styledDir -NoPause -NoOpen -NoAsk 2>&1
        $imgLog | Where-Object { $_ -match '完成|失败|错误|已保存|生成' } | Select-Object -First 2 | ForEach-Object { '       ' + $_ }
    } catch {
        Write-Host ('       ! ' + $_.Exception.Message) -ForegroundColor DarkYellow
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $sw.Stop()
    # 改图.ps1 用自增编号命名，取最新一张作为本帧结果
    $out = Get-ChildItem $styledDir -Filter '*.png' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($out -and $out.LastWriteTime -ge (Get-Date).AddMinutes(-10)) {
        $ordered = Join-Path $styledDir ("s{0:D4}.png" -f $idx)
        Copy-Item $out.FullName $ordered -Force
        Write-Host ("       ✓ {0:N0}s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    } else {
        Write-Warning "       ✗ 本帧重绘失败，用原图代替"
        Copy-Item $f.FullName (Join-Path $styledDir ("s{0:D4}.png" -f $idx)) -Force
    }
}
$swAll.Stop()
Write-Host ("重绘完成，共 {0:N1} 分钟" -f $swAll.Elapsed.TotalMinutes) -ForegroundColor Green

# ---------- 3. 合成低帧率视频 ----------
$styled = Get-ChildItem $styledDir -Filter 's*.png' | Sort-Object Name | ForEach-Object { $_.FullName }
if (-not $styled) { Write-Warning '没有重绘结果'; Pause-Brief 10; exit 1 }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$lowFps = Join-Path $outDir ("wan-v2v-low-" + $stamp + ".mp4")
& $akiPy $tools fromframes $lowFps $targetFps @styled 2>&1 | ForEach-Object { '  ' + $_ }

# ---------- 4. 插帧补回原帧率（内部会归位编号） ----------
if (Test-Path $lowFps) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $post -Video $lowFps -Scale 1 -Interp $Every -NoPause 2>&1 |
        ForEach-Object { '  ' + $_ }
}

if (-not $KeepFrames) {
    Remove-Item $rawDir, $styledDir -Recurse -Force -ErrorAction SilentlyContinue
}
$latest = Get-ChildItem $videoDir -Filter '*.mp4' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if ($latest) {
    Write-Host ''
    Write-Host ("成品：{0}" -f $latest.FullName) -ForegroundColor Green
}
Pause-Brief
exit 0
