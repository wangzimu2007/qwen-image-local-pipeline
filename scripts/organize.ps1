# 输出整理：确认输出目录、补编号、打印最新成品参数
# 用法：scripts\organize.ps1 [-SourceDir D:\ai-output\raw] [-DestDir D:\ai-output\videos]
param(
    [string]$SourceDir = '',
    [string]$DestDir = '',
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\output.ps1"
. "$PSScriptRoot\lib\info.ps1"
$cfg = Get-PipelineConfig
$py  = Get-Python $cfg

if (-not $SourceDir) { $SourceDir = $cfg.OutRawDir }
if (-not $DestDir)   { $DestDir   = $cfg.OutVideoDir }
Ensure-Dir $DestDir | Out-Null
if ($SourceDir) { Ensure-Dir $SourceDir | Out-Null }

function Get-KindFromName {
    param([string]$Name)
    $n = $Name.ToLowerInvariant()
    if ($n -match 'i2v|wan') { return 'wan' }
    if ($n -match 'aiup')    { return 'aiup' }
    if ($n -match 'join')    { return 'join' }
    if ($n -match 'post')    { return 'post' }
    if ($n -match 'minimax') { return 'minimax' }
    return 'other'
}

# 1) 先把目标目录里没编号的视频补上编号（按时间升序）
$legacy = Get-ChildItem $DestDir -File -ErrorAction SilentlyContinue |
          Where-Object { $_.Extension -eq '.mp4' -and $_.Name -notmatch '^video-\d{4,}-' } |
          Sort-Object LastWriteTime
if (@($legacy).Count -gt 0) {
    $next = Get-NextNumber -Dir $DestDir
    foreach ($f in $legacy) {
        $newName = 'video-{0:D4}-{1}-{2}.mp4' -f $next, (Get-KindFromName $f.Name), $f.LastWriteTime.ToString('yyyyMMdd-HHmmss')
        if ($WhatIfOnly) { Write-Host ("[预览] {0} -> {1}" -f $f.Name, $newName) }
        else { Rename-Item -LiteralPath $f.FullName -NewName $newName; Write-Ok ("已编号: {0} -> {1}" -f $f.Name, $newName) }
        $next++
    }
}

# 2) 把来源目录里的视频搬进来
if (Test-Path $SourceDir) {
    $incoming = Get-ChildItem $SourceDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq '.mp4' } | Sort-Object LastWriteTime
    if (@($incoming).Count -eq 0) { Write-Info '没有需要整理的新视频' }
    else {
        $next = Get-NextNumber -Dir $DestDir
        foreach ($f in $incoming) {
            $newName = 'video-{0:D4}-{1}-{2}.mp4' -f $next, (Get-KindFromName $f.Name), $f.LastWriteTime.ToString('yyyyMMdd-HHmmss')
            $target = Join-Path $DestDir $newName
            if ($WhatIfOnly) { Write-Host ("[预览] {0} -> {1}" -f $f.FullName, $newName) }
            else { Move-Item -LiteralPath $f.FullName -Destination $target -Force; Write-Ok ("已归位: {0} -> {1}" -f $f.Name, $newName) }
            $next++
        }
    }
}

# 3) 打印最新成品参数
$latest = Get-ChildItem $DestDir -Filter '*.mp4' -File -ErrorAction SilentlyContinue |
          Sort-Object Name -Descending | Select-Object -First 1
if ($latest) {
    Write-Host ''
    Write-Host ('视频目录：' + $DestDir) -ForegroundColor Cyan
    Get-ChildItem $DestDir -Filter '*.mp4' | Sort-Object Name -Descending | Select-Object -First 10 |
        ForEach-Object { '  {0,-46} {1,7:N1} MB' -f $_.Name, ($_.Length / 1MB) }
    Show-MediaInfo -Path $latest.FullName -Python $py
}
exit 0
