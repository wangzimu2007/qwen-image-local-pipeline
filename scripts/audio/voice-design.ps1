# 语音设计.ps1 —— 文字 + 声音描述 → 语音（Qwen3-TTS VoiceDesign，Apache-2.0）
#
# 与 Kokoro 的区别：本地、可"描述音色/情绪/语速"，中文自然度和准确率明显更高；
#   代价是生成较慢（约 35 秒 / 12 秒音频）。
#
# 用法：
#   .\语音设计.ps1 -Text "旁白内容" -Instruct "低沉磁性的中年男声，语速偏慢，纪录片旁白"
#   .\语音设计.ps1 -Text "..." -Instruct "..." -Out D:\audio-tools\gen-out\a.wav
param(
    [Parameter(Mandatory=$true)][string]$Text,
    [string]$Instruct = '',
    [string]$Language = 'Chinese',
    [string]$Out = '',
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
$mod = Join-Path $PSScriptRoot '音频模块.ps1'
$params = "Text=$Text;Language=$Language"
if ($Instruct) { $params += ";Instruct=$Instruct" }
$args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$mod,'-Action','voicedesign','-Params',$params)
if ($Out) { $args += @('-Out', $Out) }
& powershell @args
if ($LASTEXITCODE -ne 0) { throw "语音设计失败，退出码 $LASTEXITCODE" }
if (-not $NoPause) { Start-Sleep -Seconds 1 }
exit 0