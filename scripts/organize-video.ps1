# 整理视频：把 ComfyUI 输出的视频按自增序号归位到桌面「视频」文件夹
#
# 命名规则（与图片的 qwen-NNNN-* 同一套思路，方便按名称降序看到最新的）：
#   video-<NNNN>-<类型>-<yyyyMMdd-HHmmss>.mp4
#   类型：wan / minimax / ltx / other（按原文件名关键字判断）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File D:\qwen-image-2.1\整理视频.ps1
#   ... -SourceDir "别的目录" -DestDir "别的目标"
#   ... -WhatIfOnly        只预览不移动
param(
    [string]$SourceDir = '',
    [string]$DestDir = '',
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
$desk = [Environment]::GetFolderPath('Desktop')
if (-not $SourceDir) { $SourceDir = Join-Path $desk 'ComfyUI 输出' }
if (-not $DestDir)   { $DestDir   = Join-Path $desk '视频' }
if (-not (Test-Path $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }

function Get-Kind {
    param([string]$Name)
    $n = $Name.ToLowerInvariant()
    if ($n -match 'flashvsr') { return 'aiup' }
    if ($n -match 'wan')     { return 'wan' }
    if ($n -match 'minimax|h3') { return 'minimax' }
    if ($n -match 'ltx')     { return 'ltx' }
    return 'other'
}

function Get-NextNumber {
    param([string]$Dir)
    $max = 0
    Get-ChildItem $Dir -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match '^video-(\d{4,})-') {
            $n = [int]$Matches[1]
            if ($n -gt $max) { $max = $n }
        }
    }
    return ($max + 1)
}

# ---------- 1. 先给「已存在但没编号」的旧视频编号（按时间升序） ----------
$legacy = Get-ChildItem $DestDir -File -ErrorAction SilentlyContinue |
          Where-Object { $_.Extension -in '.mp4','.webm','.gif','.mov' -and $_.Name -notmatch '^video-\d{4,}-' } |
          Sort-Object LastWriteTime
if (@($legacy).Count -gt 0) {
    $next = Get-NextNumber $DestDir
    foreach ($f in $legacy) {
        $stamp = $f.LastWriteTime.ToString('yyyyMMdd-HHmmss')
        $kind  = Get-Kind $f.Name
        $newName = 'video-{0:D4}-{1}-{2}{3}' -f $next, $kind, $stamp, $f.Extension.ToLower()
        if ($WhatIfOnly) {
            Write-Host ("[预览] {0} -> {1}" -f $f.Name, $newName)
        } else {
            Rename-Item -LiteralPath $f.FullName -NewName $newName
            Write-Host ("已编号: {0} -> {1}" -f $f.Name, $newName) -ForegroundColor Green
        }
        $next++
    }
}

# ---------- 2. 从来源目录搬入新视频 ----------
if (-not (Test-Path $SourceDir)) {
    Write-Host ("来源目录不存在，跳过：{0}" -f $SourceDir) -ForegroundColor DarkGray
} else {
    $incoming = Get-ChildItem $SourceDir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.mp4','.webm','.gif','.mov' } |
                Sort-Object LastWriteTime
    if (@($incoming).Count -eq 0) {
        Write-Host '没有需要整理的新视频。' -ForegroundColor DarkGray
    } else {
        $next = Get-NextNumber $DestDir
        foreach ($f in $incoming) {
            $stamp   = $f.LastWriteTime.ToString('yyyyMMdd-HHmmss')
            $kind    = Get-Kind $f.Name
            $newName = 'video-{0:D4}-{1}-{2}{3}' -f $next, $kind, $stamp, $f.Extension.ToLower()
            $target  = Join-Path $DestDir $newName
            if ($WhatIfOnly) {
                Write-Host ("[预览] {0} -> {1}" -f $f.FullName, $newName)
            } else {
                Move-Item -LiteralPath $f.FullName -Destination $target -Force
                Write-Host ("已归位: {0} -> {1}" -f $f.Name, $newName) -ForegroundColor Green
            }
            $next++
        }
    }
}

Write-Host ''
Write-Host ('视频目录：' + $DestDir) -ForegroundColor Cyan
Get-ChildItem $DestDir -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending |
    Select-Object -First 10 | ForEach-Object { '  {0,-46} {1,7:N1} MB' -f $_.Name, ($_.Length/1MB) }
# ---------- 参数摘要 ----------
$infoScript = Join-Path $PSScriptRoot '_info.ps1'
if (Test-Path $infoScript) {
    . $infoScript
    Show-LatestMedia -Kind 'video'
}
