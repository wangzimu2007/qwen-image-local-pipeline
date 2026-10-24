# 输出参数摘要：分辨率 / 帧率 / 时长 / 帧数 / 编码 / 码率 / 音轨 / 体积
# 用法：. "$PSScriptRoot\lib\info.ps1"; Show-MediaInfo -Path x.mp4 -Python "python.exe"

function Get-VideoProbe {
    param([string]$Path, [string]$Python)
    $probe = Join-Path $PSScriptRoot 'probe_video.py'
    if (-not (Test-Path $probe)) { return $null }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $Python $probe $Path 2>&1
    $ErrorActionPreference = $prev
    $line = ($out | Where-Object { $_ -match '^\{' } | Select-Object -First 1)
    if (-not $line) { return $null }
    try { return ($line | ConvertFrom-Json) } catch { return $null }
}

function Show-MediaInfo {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Extra = @{},
        [string]$Python = ''
    )
    if (-not (Test-Path $Path)) {
        Write-Host ("[参数] 找不到文件：{0}" -f $Path) -ForegroundColor DarkYellow
        return
    }
    $f = Get-Item $Path
    $ext = $f.Extension.ToLowerInvariant()

    Write-Host ''
    Write-Host '──────── 输出参数 ────────' -ForegroundColor Cyan
    Write-Host ("文件    {0}" -f $f.Name)
    Write-Host ("体积    {0} MB" -f [math]::Round($f.Length / 1MB, 2))

    if ($ext -in @('.mp4', '.webm', '.mov', '.gif')) {
        $py = if ($Python) { $Python } else { 'python' }
        $p = Get-VideoProbe -Path $Path -Python $py
        if ($p) {
            $g = 0
            if ($p.h -gt 0) { $g = [math]::Round($p.w / $p.h, 2) }
            $ratio = "  ({0}:1)" -f $g
            if ([Math]::Abs($g - 1.78) -lt 0.05) { $ratio = '  (16:9)' }
            elseif ([Math]::Abs($g - 1.0) -lt 0.05) { $ratio = '  (1:1)' }
            elseif ([Math]::Abs($g - 0.56) -lt 0.05) { $ratio = '  (9:16)' }
            elseif ([Math]::Abs($g - 1.33) -lt 0.05) { $ratio = '  (4:3)' }
            elseif ([Math]::Abs($g - 0.75) -lt 0.05) { $ratio = '  (3:4)' }
            Write-Host ("分辨率  {0} × {1}{2}" -f $p.w, $p.h, $ratio)
            Write-Host ("帧率    {0} fps" -f $p.fps)
            Write-Host ("时长    {0} 秒" -f $p.dur)
            Write-Host ("帧数    {0} 帧" -f $p.frames)
            Write-Host ("编码    {0}" -f $p.codec)
            if ($p.bitrate -gt 0) { Write-Host ("码率    {0:N0} kbps" -f ($p.bitrate / 1000)) }
            $audio = if (@($p.audio).Count -gt 0) { (@($p.audio) -join ', ') } else { '无（静音）' }
            Write-Host ("音轨    {0}" -f $audio)
        } else {
            Write-Host '（视频探测失败：需要 pip install av）' -ForegroundColor DarkYellow
        }
    } else {
        try {
            Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
            $img = [System.Drawing.Image]::FromFile($Path)
            $g = [math]::Round($img.Width / $img.Height, 2)
            $ratio = "  ({0}:1)" -f $g
            if ([Math]::Abs($g - 1.78) -lt 0.05) { $ratio = '  (16:9)' }
            elseif ([Math]::Abs($g - 1.0) -lt 0.05) { $ratio = '  (1:1)' }
            elseif ([Math]::Abs($g - 1.33) -lt 0.05) { $ratio = '  (4:3)' }
            elseif ([Math]::Abs($g - 0.75) -lt 0.05) { $ratio = '  (3:4)' }
            Write-Host ("分辨率  {0} × {1}{2}" -f $img.Width, $img.Height, $ratio)
            Write-Host ("像素量  {0} MP" -f [math]::Round($img.Width * $img.Height / 1000000.0, 2))
            Write-Host ("格式    {0}" -f $ext.TrimStart('.').ToUpper())
            $img.Dispose()
        } catch {
            Write-Host '（图片信息读取失败）' -ForegroundColor DarkYellow
        }
    }

    if ($Extra -and $Extra.Count -gt 0) {
        foreach ($k in $Extra.Keys) { Write-Host ("{0}    {1}" -f $k.PadRight(6), $Extra[$k]) }
    }
    Write-Host '──────────────────────────' -ForegroundColor Cyan
}
