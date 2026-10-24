# 修图：确定性小修小改（裁剪 / 缩放 / 调色 / 文字 / 水印 / 修块 / 拼图）
# 纯 CPU，不占显存，可以和其他本地模型同时跑；单张 0.1~1 秒
#
# 用法：
#   .\img-edit.ps1 -Image x.png -Ops "cropc=1024,1024;color=1.05,1.03"
#   .\img-edit.ps1 -Image x.png -Ops "resize=0.5;wtext:©你的名字:br:28:0.7:white"
#   .\img-edit.ps1 -Image x.png -Ops "blurfill=1368,1976,1452,2080,22"   # 修超分灰块
#   .\img-edit.ps1 -List
param(
    [string]$Image = '',
    [string]$Ops = '',
    [string]$OpsFile = '',
    [string]$Out = '',
    [string]$OutDir = '',
    [int]$Quality = 92,
    [switch]$NoOpen,
    [switch]$NoInfo,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"

$opScript = Join-Path $PSScriptRoot 'lib\imgops.py'
$eraseScript = Join-Path $PSScriptRoot 'lib\imgerase.py'

if ($List) {
    Write-Head '支持的 op（用分号串联，按顺序执行）'
    @(
        'crop=l,t,r,b                按像素裁剪',
        'cropc=W,H                   居中裁剪到 W×H',
        'resize=0.5                  按比例缩放',
        'resize=WxH                  缩放到指定尺寸（0 表示按比例）',
        'thumb=W,H                   等比缩到不超过 W×H（不放大）',
        'rotate=90                   旋转（逆时针）',
        'flip=h|v                    水平 / 垂直翻转',
        'color=brightness,contrast,saturation,sharpness   整图调色（1.0=不变）',
        'boxcolor:亮度,对比,饱和,锐化:x1,y1,x2,y2:羽化     只调某个区域',
        'gray                        转灰度',
        'autocontrast=1              自动对比度',
        'border=px,color             加边框',
        'radius=px                   圆角（png/webp 保留透明）',
        'text:内容:字号:x:y:颜色:背景            叠加文字（背景 none=透明）',
        'wtext:内容:tl|tr|bl|br|center:字号:不透明度:颜色   文字水印',
        'wimg:位置:缩放:不透明度:水印图片路径    图片水印',
        'montage:列数:格子尺寸:间距:背景:清单txt        拼图（清单每行一个路径）',
        'erase=x1,y1,x2,y2           抹掉一块（OpenCV 修补，要有带 cv2 的 Python）',
        'erase=掩码.png               按黑白掩码抹除',
        'blurfill=x1,y1,x2,y2[,sigma] 平滑区修补（皮肤/天空/墙面的灰块首选）',
        'clone=源x,源y,目标x,目标y,宽,高[,羽化]   从旁边借一块',
        'format=png|jpg|webp         输出格式（也可由 -Out 扩展名决定）',
        'quality=90                  输出质量',
        'exif=fix                    按 EXIF 方向转正'
    ) | ForEach-Object { '  ' + $_ }
    Write-Host ''
    Write-Head '颜色写法'
    @('#ff8800 / #f80 / white / black / red / gray / none（透明）', '#rrggbbaa 可带透明度') | ForEach-Object { '  ' + $_ }
    exit 0
}

if (-not $Image) { Fail '需要 -Image（图片路径）。用 -List 看支持的 op' }
if (-not (Test-Path $Image)) { Fail ("找不到图片：" + $Image) }

if (-not $Ops -and $OpsFile) {
    if (-not (Test-Path $OpsFile)) { Fail ("找不到 -OpsFile：" + $OpsFile) }
    $Ops = [System.IO.File]::ReadAllText($OpsFile, [System.Text.Encoding]::UTF8).Trim()
}
if (-not $Ops) { Fail '没有给 -Ops。用 -List 看支持的 op' }

$C = Get-PipelineConfig

# ---- 选 Python：引擎自带 Pillow 即可；erase 需要 cv2 ----
function Test-PythonHas {
    param([string]$Exe, [string]$Module)
    if (-not $Exe -or -not (Test-Path $Exe)) { return $false }
    # 原生命令的 stderr 在 $ErrorActionPreference='Stop' 下会变成终止错误，必须临时放开
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe -c ("import " + $Module) 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false } finally { $ErrorActionPreference = $prevEap }
}

$pys = @()
if ($C.PythonExe) { $pys += $C.PythonExe }
$pys += (Get-Python -Config $C)
$g = Get-Command python -ErrorAction SilentlyContinue
if ($g) { $pys += $g.Source }

$pyPillow = $null
$pyCv2 = $null
foreach ($p in $pys) {
    if (-not $pyPillow -and (Test-PythonHas -Exe $p -Module 'PIL')) { $pyPillow = $p }
    if (-not $pyCv2 -and (Test-PythonHas -Exe $p -Module 'cv2')) { $pyCv2 = $p }
}
if (-not $pyPillow) { Fail '找不到带 Pillow 的 Python（pip install pillow，或在 config.ps1 里配 PythonExe）' }
if (-not $pyCv2 -and ($Ops -match 'erase')) {
    Write-Warn2 '  erase 需要 OpenCV：当前 Python 没装 cv2，抹除会失败（blurfill/clone 不受影响）'
}
if (-not $pyCv2) { $pyCv2 = $pyPillow }

# ---- 输出路径 ----
if (-not $OutDir) {
    if ($C.OutImageDir) { $OutDir = $C.OutImageDir } else { $OutDir = Ensure-Dir (Join-Path $script:RepoRoot 'output\images') }
}
Ensure-Dir $OutDir | Out-Null

$fmtHint = 'png'
if ($Out) { $fmtHint = [System.IO.Path]::GetExtension($Out).TrimStart('.').ToLower() }
elseif ($Ops -match 'format\s*[=:]\s*(\w+)') { $fmtHint = $Matches[1].ToLower() }
$ext = switch ($fmtHint) { 'jpg' { 'jpg' } 'jpeg' { 'jpg' } 'webp' { 'webp' } default { 'png' } }

if (-not $Out) {
    $max = 0
    Get-ChildItem $OutDir -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match 'pipe-(\d{4})-') { $n = [int]$Matches[1]; if ($n -gt $max) { $max = $n } }
    }
    $Out = Join-Path $OutDir ('pipe-{0:D4}-fix-{1}.{2}' -f ($max + 1), (Get-Date -Format 'yyyyMMdd-HHmmss'), $ext)
}

Write-Head '修图'
Write-Info ('输入：' + $Image)
Write-Info ('操作：' + $Ops)
Write-Info ('输出：' + $Out)

# 复制到英文临时路径，避免空格/中文路径在参数里出问题
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('pipe-edit-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
Ensure-Dir $tmpDir | Out-Null
$safeExt = [System.IO.Path]::GetExtension($Image)
if (-not $safeExt) { $safeExt = '.png' }
$srcSafe = Join-Path $tmpDir ('src' + $safeExt)
Copy-Item -LiteralPath $Image -Destination $srcSafe -Force
$opsPath = Join-Path $tmpDir 'ops.txt'
[System.IO.File]::WriteAllText($opsPath, $Ops, (New-Object System.Text.UTF8Encoding($false)))

$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
$env:PIPE_ERASE_PYTHON = $pyCv2

$raw = $null
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $raw = & $pyPillow $opScript --in $srcSafe --out $Out --opsfile $opsPath --quality $Quality 2>&1
} finally {
    $ErrorActionPreference = $prev
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

$json = $null
foreach ($line in $raw) {
    $s = ([string]$line).Trim()
    if ($s.StartsWith('{')) { try { $json = $s | ConvertFrom-Json } catch { } }
}
if (-not $json -or -not $json.ok) {
    Write-Host ''
    $msg = if ($json) { $json.error } else { (($raw | ForEach-Object { [string]$_ }) -join ' ') }
    Fail ('修图失败：' + $msg)
}

Write-Ok ('完成，用时 ' + $json.seconds + ' 秒')
Write-Info ("前：{0}×{1}   后：{2}×{3}   格式 {4}" -f $json.before.w, $json.before.h, $json.after.w, $json.after.h, $json.after.format)
Write-Ok ('成品：' + $json.dst)

if (-not $NoOpen) { Start-Process $json.dst }
if (-not $NoInfo) {
    . "$PSScriptRoot\lib\info.ps1"
    Show-MediaInfo -Path $json.dst -Extra @{ '操作' = ($json.ops -join ' ; ') }
}
exit 0
