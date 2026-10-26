# 提示词扩写.ps1 —— 本地模型（qwen3.5:9b）把一句话扩成可用提示词
#
# 用途：给图片/视频/音频/音效/音色工作流加"本地模型前端"。
# 用法：
#   .\提示词扩写.ps1 -Text "雨夜街道，赛博朋克" -Kind image
#   .\提示词扩写.ps1 -Text "让船缓缓划向岸边" -Kind video -Style "电影感，慢镜头"
#   .\提示词扩写.ps1 -Text "古风战斗背景音乐" -Kind audio -Out D:\audio-tools\gen-out\bgm.txt
param(
    [Parameter(Mandatory = $true)][string]$Text,
    [ValidateSet('image','video','audio','sfx','voice')][string]$Kind = 'image',
    [string]$Style = '',
    [string]$Out = '',
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
$py = 'D:\audio-tools\qt-venv\Scripts\python.exe'
$helper = Join-Path $PSScriptRoot '_prompt_llm.py'
if (-not (Test-Path $py)) { throw "缺少 Python：$py" }
$args = @($helper, '--text', $Text, '--kind', $Kind)
if ($Style) { $args += @('--style', $Style) }
if ($Out) { $args += @('--out', $Out) }
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$o = & $py @args 2>&1
$code = $LASTEXITCODE
$ErrorActionPreference = $prevEap
$o | ForEach-Object { Write-Host ([string]$_) }
if ($code -ne 0) { throw "提示词扩写失败，退出码 $code" }
if (-not $NoPause) { Start-Sleep -Seconds 1 }
exit 0