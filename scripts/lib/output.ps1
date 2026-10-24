# 输出归位：自增编号、统一命名、参数摘要
# 用法：. "$PSScriptRoot\lib\output.ps1"; Save-VideoOutput -Config $cfg -SourceFile $src -Kind wan

function Get-ComfyOutputDir {
    param($Config)
    if ($Config.ComfyOutputDir) { return $Config.ComfyOutputDir }
    return (Join-Path $Config.ComfyRoot 'output')
}

function Get-NextNumber {
    param([string]$Dir, [string]$Pattern = '^video-(\d{4,})-')
    $max = 0
    Get-ChildItem $Dir -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match $Pattern) {
            $n = [int]$Matches[1]
            if ($n -gt $max) { $max = $n }
        }
    }
    return ($max + 1)
}

function Save-VideoOutput {
    param($Config, [string]$SourceFile, [string]$Kind = 'wan')
    if (-not (Test-Path $SourceFile)) { throw ("找不到待归位的视频：" + $SourceFile) }
    $dir = Ensure-Dir $Config.OutVideoDir
    $n = Get-NextNumber -Dir $dir
    $name = "video-{0:D4}-{1}-{2}.mp4" -f $n, $Kind, (Get-Date -Format 'yyyyMMdd-HHmmss')
    $target = Join-Path $dir $name
    if ((Resolve-Path $SourceFile).Path -eq $target) { return $target }
    Move-Item -LiteralPath $SourceFile -Destination $target -Force
    return $target
}

function Copy-VideoOutput {
    param($Config, [string]$SourceFile, [string]$Kind = 'wan')
    $dir = Ensure-Dir $Config.OutVideoDir
    $n = Get-NextNumber -Dir $dir
    $name = "video-{0:D4}-{1}-{2}.mp4" -f $n, $Kind, (Get-Date -Format 'yyyyMMdd-HHmmss')
    $target = Join-Path $dir $name
    Copy-Item -LiteralPath $SourceFile -Destination $target -Force
    return $target
}

function Save-ImageOutput {
    param($Config, [string]$SourceFile, [string]$Kind = 'img')
    $dir = Ensure-Dir $Config.OutImageDir
    $ext = [System.IO.Path]::GetExtension($SourceFile)
    $name = "qwen-{0}-{1}{2}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Kind, $ext
    $target = Join-Path $dir $name
    Copy-Item -LiteralPath $SourceFile -Destination $target -Force
    return $target
}
