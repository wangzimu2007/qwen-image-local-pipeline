# 游戏语音采集.ps1（短路径入口）—— 转发到采集台正式实现
# 正式入口：D:\audio-tools\游戏语音采集\游戏语音采集.ps1
# 常用：
#   .\游戏语音采集.ps1 status
#   .\游戏语音采集.ps1 web -Url "<网页视频地址>" -Character "角色名"
#   .\游戏语音采集.ps1 obs | anime | fmodel | assetripper | scan | extract ...
param(
    [Parameter(Position = 0)][string]$Action = 'status',
    [string]$Url = '',
    [string]$Source = '',
    [string]$Out = '',
    [string]$Game = 'genshin',
    [string]$Pck = '',
    [string]$Filter = '',
    [int]$Limit = 0,
    [string]$Character = '_待分类',
    [Parameter(ValueFromRemainingArguments = $true)]$Rest
)
$ErrorActionPreference = 'Continue'
$real = 'D:\audio-tools\游戏语音采集\游戏语音采集.ps1'
if (-not (Test-Path $real)) { throw ('采集台入口不存在：' + $real) }
$mapped = switch ($Action) {
    'tools'   { 'status' }
    'ytdlp'   { 'web' }
    'list'    { 'status' }
    'archive' { 'prep' }
    default   { $Action }
}
$args2 = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$real,'-Action',$mapped)
if ($Url) { $args2 += @('-Url', $Url) }
if ($Source) { $args2 += @('-Source', $Source) }
if ($Out) { $args2 += @('-Out', $Out) }
if ($Game -and $Game -ne 'genshin') { $args2 += @('-Game', $Game) }
if ($Pck) { $args2 += @('-Pck', $Pck) }
if ($Filter) { $args2 += @('-Filter', $Filter) }
if ($Limit -gt 0) { $args2 += @('-Limit', "$Limit") }
if ($Character -and $Character -ne '_待分类') { $args2 += @('-Character', $Character) }
& powershell @args2
exit $LASTEXITCODE