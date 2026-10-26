# 整理音频：把 ComfyUI / TTS 等生成的音频按自增序号归位到桌面「音频」文件夹
#
# 命名规则（与图片 qwen-NNNN-*、视频 video-NNNN-* 同一套思路）：
#   audio-<NNNN>-<类型>-<yyyyMMdd-HHmmss>.<扩展名>
#   类型：music / tts / sfx / audio（按原文件名关键字判断，也可用 -Kind 覆盖）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File D:\qwen-image-2.1\整理音频.ps1
#   ... -SourceDir "别的目录" -DestDir "别的目标" -Kind tts
#   ... -WhatIfOnly        只预览不移动
param(
    [string]$SourceDir = '',
    [string]$DestDir = '',
    [string]$Kind = '',
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
$desk = [Environment]::GetFolderPath('Desktop')
if (-not $SourceDir) { $SourceDir = Join-Path $desk 'ComfyUI 输出' }
if (-not $DestDir)   { $DestDir   = Join-Path $desk '音频' }
if (-not (Test-Path $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }

$audioExts = @('.mp3', '.wav', '.flac', '.m4a', '.ogg', '.opus', '.aac', '.wma')

function Get-AudioKind {
    param([string]$Name)
    if ($Kind) { return $Kind.ToLowerInvariant() }
    $n = $Name.ToLowerInvariant()
    if ($n -match 'ace|music|song|音乐|歌曲') { return 'music' }
    if ($n -match 'tts|speech|voice|index|cosy|fish|语音|朗读') { return 'tts' }
    if ($n -match 'sfx|foley|sound|音效|拟音') { return 'sfx' }
    return 'audio'
}

function Get-NextNumber {
    param([string]$Dir)
    $max = 0
    Get-ChildItem $Dir -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match '^audio-(\d{4,})-') {
            $n = [int]$Matches[1]
            if ($n -gt $max) { $max = $n }
        }
    }
    return ($max + 1)
}

# ---------- 1. 先给目标目录里「已存在但没编号」的旧音频编号（按时间升序） ----------
$legacy = Get-ChildItem $DestDir -File -ErrorAction SilentlyContinue |
          Where-Object { $_.Extension.ToLowerInvariant() -in $audioExts -and $_.Name -notmatch '^audio-\d{4,}-' } |
          Sort-Object LastWriteTime
if (@($legacy).Count -gt 0) {
    $next = Get-NextNumber $DestDir
    foreach ($f in $legacy) {
        $stamp   = $f.LastWriteTime.ToString('yyyyMMdd-HHmmss')
        $kind    = Get-AudioKind $f.Name
        $newName = 'audio-{0:D4}-{1}-{2}{3}' -f $next, $kind, $stamp, $f.Extension.ToLowerInvariant()
        if ($WhatIfOnly) {
            Write-Host ("[预览] {0} -> {1}" -f $f.Name, $newName)
        } else {
            Rename-Item -LiteralPath $f.FullName -NewName $newName
            Write-Host ("已编号: {0} -> {1}" -f $f.Name, $newName) -ForegroundColor Green
        }
        $next++
    }
}

# ---------- 2. 从来源目录搬入新音频 ----------
if (-not (Test-Path $SourceDir)) {
    Write-Host ("来源目录不存在，跳过：{0}" -f $SourceDir) -ForegroundColor DarkGray
} else {
    $incoming = Get-ChildItem $SourceDir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension.ToLowerInvariant() -in $audioExts } |
                Sort-Object LastWriteTime
    if (@($incoming).Count -eq 0) {
        Write-Host '没有需要整理的新音频。' -ForegroundColor DarkGray
    } else {
        $next = Get-NextNumber $DestDir
        foreach ($f in $incoming) {
            $stamp   = $f.LastWriteTime.ToString('yyyyMMdd-HHmmss')
            $kind    = Get-AudioKind $f.Name
            $newName = 'audio-{0:D4}-{1}-{2}{3}' -f $next, $kind, $stamp, $f.Extension.ToLowerInvariant()
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
Write-Host ('音频目录：' + $DestDir) -ForegroundColor Cyan
Get-ChildItem $DestDir -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending |
    Select-Object -First 10 | ForEach-Object { '  {0,-52} {1,8:N1} MB' -f $_.Name, ($_.Length/1MB) }
exit 0
