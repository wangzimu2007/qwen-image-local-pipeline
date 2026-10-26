# _run_capture.ps1 —— 跑一次 提交作业.ps1 并把全部输出（含 Write-Host）写进文件
#
# 为什么需要它：
#   PowerShell 的 Write-Host 走 host 通道，Start-Process -RedirectStandardOutput 抓不到，
#   验证脚本里必须用 -Command/包装脚本 + *>&1 才能拿到完整输出。
param(
    [Parameter(Mandatory = $true)][string]$OutFile,
    [Parameter(ValueFromRemainingArguments = $true)]$Rest
)

$ErrorActionPreference = 'Continue'
$submit = Join-Path $PSScriptRoot '提交作业.ps1'
$out = & $submit @Rest 2>&1
$text = ($out | ForEach-Object { [string]$_ }) -join "`r`n"
[System.IO.File]::WriteAllText($OutFile, $text, (New-Object System.Text.UTF8Encoding($false)))
$out | Out-Host
exit $LASTEXITCODE
