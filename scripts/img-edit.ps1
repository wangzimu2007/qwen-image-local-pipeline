# 修图：Pillow 确定性小修小改（裁剪 / 缩放 / 调色 / 文字 / 水印 / 转格式 / 拼图）
# 纯 CPU，不占显存，可以和其他本地模型同时跑；单张 0.2~1 秒
# 用法示例：
#   .\修图.ps1 -Image x.png -Ops "cropc=800,600;color=1.1,1.05"
#   .\修图.ps1 -Image x.png -Ops "resize=0.5;wtext:©王梓木:br:28:0.7:white"
#   .\修图.ps1 -Image x.png -Ops "thumb=1280,720;format=webp;quality=88"
param(
    [string]$Image = '',
    [string]$Ops = '',
    [string]$OpsFile = '',   # 把 op 列表写进文件再传：路径含空格时用这个
    [string]$Out = '',
    [string]$OutDir = '',
    [int]$Quality = 92,
    [switch]$NoOpen,
    [switch]$NoInfo,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
$pyFile = Join-Path $PSScriptRoot '修图.py'
. (Join-Path $PSScriptRoot '_meta.ps1')

function Write-H { param([string]$t) Write-Host ''; Write-Host ("== " + $t + " ==") -ForegroundColor Cyan }
function Write-Ok { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Green }
function Write-In { param([string]$t) Write-Host ("  " + $t) -ForegroundColor DarkGray }
function Write-Warn { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Yellow }

if ($List) {
    Write-H '支持的 op（用分号串联，按顺序执行）'
    @(
        'crop=l,t,r,b            按像素裁剪',
        'cropc=W,H               居中裁剪到 W×H',
        'resize=0.5              按比例缩放',
        'resize=WxH              缩放到指定尺寸（0 表示按比例）',
        'thumb=W,H               等比缩到不超过 W×H（不放大）',
        'rotate=90               旋转（逆时针）',
        'flip=h|v                水平 / 垂直翻转',
        'color=b,c,s,sharp       亮度/对比度/饱和度/锐化（1.0=不变）',
        'gray                    转灰度',
        'autocontrast=1          自动对比度',
        'erase=x1,y1,x2,y2        抹掉一块（去水印/去杂物，OpenCV 修补，0.2~1 秒）',
        'erase=掩码.png            按黑白掩码抹除（白色部分被抹掉）',
        'boxcolor:亮度,对比,饱和,锐化:x1,y1,x2,y2:羽化    只调某个区域',
        'border=px,color         加边框',
        'radius=px               圆角（png/webp 保留透明）',
        'text:内容:字号:x:y:颜色:背景            叠加文字（背景 none=透明）',
        'wtext:内容:tl|tr|bl|br|center:字号:不透明度:颜色   文字水印',
        'wimg:位置:缩放:不透明度:水印图片路径    图片水印',
        'montage:列数:格子尺寸:间距:背景:清单文件      拼图（清单 txt 每行一个路径）',
        'format=png|jpg|webp     输出格式（也可由 -Out 扩展名决定）',
        'quality=90              输出质量',
        'exif=fix                按 EXIF 方向转正'
    ) | ForEach-Object { '  ' + $_ }
    Write-H '颜色写法'
    @('#ff8800 / #f80 / white / black / red / gray / none（透明）', '#rrggbbaa 可带透明度') | ForEach-Object { '  ' + $_ }
    exit 0
}

if (-not $Image) { Write-Warn '需要 -Image（图片路径）。用 -List 看支持的 op'; exit 1 }
if (-not (Test-Path $Image)) { Write-Warn ("找不到图片：" + $Image); exit 1 }
if (-not $Ops -and $OpsFile) {
    if (-not (Test-Path $OpsFile)) { Write-Warn ('找不到 -OpsFile：' + $OpsFile); exit 1 }
    $Ops = [System.IO.File]::ReadAllText($OpsFile, [System.Text.Encoding]::UTF8).Trim()
}
if (-not $Ops) { Write-Warn '没有给 -Ops，什么都不会做。-List 看支持的 op'; exit 1 }

# ---- 找带 Pillow 的 Python ----
$cands = @(
    'D:\deepseek harness\resources\runtime\primary-runtime\dependencies\python\python.exe',
    'D:\ComfyUI-aki-v3.2\python\python.exe',
    'D:\Comfy-Desktop\ComfyUI-Installs\ComfyUI (1)\ComfyUI\.venv\Scripts\python.exe'
)
$py = $null
foreach ($c in $cands) {
    if (-not (Test-Path $c)) { continue }
    & $c -c "import PIL" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $py = $c; break }
}
if (-not $py) {
    $g = Get-Command python -ErrorAction SilentlyContinue
    if ($g) { & $g.Source -c "import PIL" 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $py = $g.Source } }
}
if (-not $py) { Write-Warn '找不到带 Pillow 的 Python'; exit 1 }

# ---- 决定输出路径（qwen-NNNN-fix-时间）----
if (-not $OutDir) { $OutDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Qwen 图片' }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$fmtHint = ''
if ($Out) { $fmtHint = [System.IO.Path]::GetExtension($Out).TrimStart('.').ToLower() }
elseif ($Ops -match 'format\s*[=:]\s*(\w+)') { $fmtHint = $Matches[1].ToLower() }
else { $fmtHint = 'png' }
$ext = switch ($fmtHint) { 'jpg' { 'jpg' } 'jpeg' { 'jpg' } 'webp' { 'webp' } default { 'png' } }

if (-not $Out) {
    $max = 0
    Get-ChildItem $OutDir -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match '^qwen-(\d{4})-') { $n = [int]$Matches[1]; if ($n -gt $max) { $max = $n } }
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Out = Join-Path $OutDir ('qwen-{0:D4}-fix-{1}.{2}' -f ($max + 1), $stamp, $ext)
}

Write-H '修图'
Write-In ('输入：' + $Image)
Write-In ('操作：' + $Ops)
Write-In ('输出：' + $Out)

# 复制到英文临时路径：规避空格/中文在命令行参数里的解析问题
$tmpDir = Join-Path $env:TEMP ('xiutu-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
$safeExt = [System.IO.Path]::GetExtension($Image)
if (-not $safeExt) { $safeExt = '.png' }
$srcSafe = Join-Path $tmpDir ('src' + $safeExt)
Copy-Item -LiteralPath $Image -Destination $srcSafe -Force

$opsPath = Join-Path $tmpDir 'ops.txt'
[System.IO.File]::WriteAllText($opsPath, $Ops, (New-Object System.Text.UTF8Encoding($false)))

$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'

$raw = $null
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $raw = & $py $pyFile --in $srcSafe --out $Out --opsfile $opsPath --quality $Quality 2>&1
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
    Write-Host ('  ✗ 修图失败：' + $msg) -ForegroundColor Red
    exit 1
}

Write-Ok ('完成，用时 ' + $json.seconds + ' 秒')
Write-Host ('    前：{0}×{1}   后：{2}×{3}   格式 {4}' -f $json.before.w, $json.before.h, $json.after.w, $json.after.h, $json.after.format) -ForegroundColor DarkGray
Write-Ok ('成品：' + $json.dst)

Write-MediaMeta -Path $json.dst -Extra @{ Model = "Pillow ops"; Ops = $Ops; Source = $Image }
if (-not $NoOpen) { Start-Process $json.dst }
if (-not $NoInfo) {
    $infScript = Join-Path $PSScriptRoot '_info.ps1'
    if (Test-Path $infScript) {
        . $infScript
        Show-MediaInfo -Path $json.dst -Extra @{ '操作' = ($json.ops -join ' ; ') }
    }
}
exit 0
