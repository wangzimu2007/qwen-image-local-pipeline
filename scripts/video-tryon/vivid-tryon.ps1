# ViViD换衣.ps1 —— 视频换衣（ViViD，阿里 Apache-2.0，本地）
#
# 说明：
#   - 官方 demo 自带全套预处理数据（视频/衣服/agnostic/mask/densepose），可直接跑通验证
#   - 换**自己的视频**需要先准备：agnostic 视频、agnostic_mask、densepose 视频、cloth 图、cloth_mask
#     （ViViD 官方推荐用 OOTDiffusion 抽 agnostic、vid2densepose 出姿态、SAM 出衣服 mask）
#   - 自定义数据请写一个 yaml（照抄 configs/prompts/upper1.yaml 结构）后用 -ConfigFile 传入
#
# 用法：
#   .\ViViD换衣.ps1 -Demo upper1
#   .\ViViD换衣.ps1 -ConfigFile D:\path\my.yaml -Width 384 -Height 512 -L 48 -Steps 20
param(
    [ValidateSet('upper1','lower1','none')][string]$Demo = 'upper1',
    [string]$ConfigFile = '',
    [int]$Width = 384,
    [int]$Height = 512,
    [int]$L = 48,
    [int]$Steps = 20,
    [double]$Cfg = 3.5,
    [int]$Seed = 42,
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
$root = 'D:\audio-tools\vivid-src'
$py = 'D:\audio-tools\vivid-venv\Scripts\python.exe'
if (-not (Test-Path $py)) { throw '缺少 vivid-venv：' + $py }
if (-not (Test-Path (Join-Path $root 'vivid.py'))) { throw '缺少 ViViD 源码：' + $root }

$cfgPath = ''
if ($ConfigFile) {
    if (-not (Test-Path $ConfigFile)) { throw '配置文件不存在：' + $ConfigFile }
    $cfgPath = $ConfigFile
} else {
    if ($Demo -eq 'none') { throw '请给 -Demo 或 -ConfigFile' }
    $cfgPath = Join-Path $root ('configs\prompts\' + $Demo + '.yaml')
    if (-not (Test-Path $cfgPath)) { throw '缺少 demo 配置：' + $cfgPath }
}

$runStarted = Get-Date
$env:PYTHONPATH = $root
$env:HF_ENDPOINT = 'https://hf-mirror.com'
$prev = Get-Location
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    Set-Location $root
    & $py 'vivid.py' --config $cfgPath -W $Width -H $Height -L $L --steps $Steps --cfg $Cfg --seed $Seed 2>&1 |
        ForEach-Object { Write-Host ([string]$_) }
    $code = $LASTEXITCODE
} finally {
    Set-Location $prev
    $ErrorActionPreference = $prevEap
}
if ($code -ne 0) { throw "ViViD 失败，退出码 $code" }

$latest = Get-ChildItem (Join-Path $root 'output') -Recurse -File -Include '*.mp4' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -ge $runStarted } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 8
if (-not $latest) { throw '没有找到输出视频' }
foreach ($f in $latest) {
    Write-Host ('成品：' + $f.FullName) -ForegroundColor Green
    Write-Host ('RESULT=' + $f.FullName) -ForegroundColor Green
}
if (-not $NoPause) { Start-Sleep -Seconds 1 }
exit 0
