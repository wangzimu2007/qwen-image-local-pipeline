# 媒体参数摘要（图片 / 视频通用）—— 给"生成完就报参数"用
#
# 用法（可 dot-source）：
#   . D:\qwen-image-2.1\_info.ps1
#   Show-MediaInfo -Path "C:\...\x.mp4"
#   Show-MediaInfo -Path "C:\...\x.png" -Extra @{ 模型='Qwen-Image 2.1 Turbo'; 步数=8 }
#
# 输出一份带标签的摘要：分辨率 / 帧率 / 时长 / 帧数 / 编码 / 码率 / 音轨 / 体积 / 比例

$script:_infoPy = 'D:\ComfyUI-aki-v3.2\python\python.exe'
$script:_infoTools = 'D:\qwen-image-2.1\_video_tools.py'

function Get-VideoProbe {
    param([string]$Path)
    $pyCode = @'
import sys, av, json
p = sys.argv[1]
c = av.open(p)
s = c.streams.video[0]
fps = float(s.average_rate) if s.average_rate else 0.0
dur = float(s.duration * s.time_base) if s.duration else 0.0
n = s.frames or 0
codec = s.codec_context.name
audio = [a.codec_context.name for a in c.streams if a.type == "audio"]
br = 0
if c.duration and c.bit_rate:
    br = c.bit_rate
print(json.dumps({"w": s.width, "h": s.height, "fps": round(fps, 2), "dur": round(dur, 2),
                  "frames": n, "codec": codec, "audio": audio, "bitrate": br}))
'@
    $tmp = Join-Path $env:TEMP 'probe_video.py'
    [System.IO.File]::WriteAllText($tmp, $pyCode, (New-Object System.Text.UTF8Encoding($false)))
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $script:_infoPy $tmp $Path 2>&1
    $ErrorActionPreference = $prev
    $json = ($out | Where-Object { $_ -match '^\{' } | Select-Object -First 1)
    if (-not $json) { return $null }
    try { return ($json | ConvertFrom-Json) } catch { return $null }
}

function Show-MediaInfo {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Extra = @{}
    )
    if (-not (Test-Path $Path)) { Write-Host ("[参数] 文件不存在：{0}" -f $Path) -ForegroundColor DarkYellow; return }
    $f = Get-Item $Path
    $sizeMB = [math]::Round($f.Length / 1MB, 2)
    $ext = $f.Extension.ToLowerInvariant()

    Write-Host ''
    Write-Host '──────── 输出参数 ────────' -ForegroundColor Cyan
    Write-Host ("文件    {0}" -f $f.Name)
    Write-Host ("体积    {0} MB" -f $sizeMB)

    if ($ext -in @('.mp4', '.webm', '.mov', '.gif')) {
        $p = Get-VideoProbe -Path $Path
        if ($p) {
            $ratio = ''
            if ($p.w -gt 0 -and $p.h -gt 0) {
                $g = [Math]::Round($p.w / $p.h, 2)
                $ratio = "  ($([math]::Round($p.w/$p.h,2)):1)"
                # 常见比例友好显示
                if ([Math]::Abs($g - 1.78) -lt 0.05) { $ratio = '  (16:9)' }
                elseif ([Math]::Abs($g - 1.6) -lt 0.05) { $ratio = '  (16:10)' }
                elseif ([Math]::Abs($g - 1.0) -lt 0.05) { $ratio = '  (1:1)' }
                elseif ([Math]::Abs($g - 0.56) -lt 0.05) { $ratio = '  (9:16)' }
                elseif ([Math]::Abs($g - 1.33) -lt 0.05) { $ratio = '  (4:3)' }
                elseif ([Math]::Abs($g - 0.75) -lt 0.05) { $ratio = '  (3:4)' }
            }
            Write-Host ("分辨率  {0} × {1}{2}" -f $p.w, $p.h, $ratio)
            Write-Host ("帧率    {0} fps" -f $p.fps)
            Write-Host ("时长    {0} 秒" -f $p.dur)
            Write-Host ("帧数    {0} 帧" -f $p.frames)
            Write-Host ("编码    {0}" -f $p.codec)
            if ($p.bitrate -gt 0) { Write-Host ("码率    {0:N0} kbps" -f ($p.bitrate / 1000)) }
            $audioText = if (@($p.audio).Count -gt 0) { (@($p.audio) -join ', ') } else { '无（静音）' }
            Write-Host ("音轨    {0}" -f $audioText)
        }
        else { Write-Host '（视频探测失败，仅显示文件信息）' -ForegroundColor DarkYellow }
    }
    else {
        $img = $null
        try {
            Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
            $img = [System.Drawing.Image]::FromFile($Path)
            $ratio = ''
            if ($img.Width -gt 0 -and $img.Height -gt 0) {
                $g = [Math]::Round($img.Width / $img.Height, 2)
                $ratio = "  ($([math]::Round($img.Width/$img.Height,2)):1)"
                if ([Math]::Abs($g - 1.78) -lt 0.05) { $ratio = '  (16:9)' }
                elseif ([Math]::Abs($g - 1.0) -lt 0.05) { $ratio = '  (1:1)' }
                elseif ([Math]::Abs($g - 1.33) -lt 0.05) { $ratio = '  (4:3)' }
                elseif ([Math]::Abs($g - 0.75) -lt 0.05) { $ratio = '  (3:4)' }
                elseif ([Math]::Abs($g - 0.56) -lt 0.05) { $ratio = '  (9:16)' }
            }
            Write-Host ("分辨率  {0} × {1}{2}" -f $img.Width, $img.Height, $ratio)
            $mp = [math]::Round($img.Width * $img.Height / 1000000.0, 2)
            Write-Host ("像素量  {0} MP" -f $mp)
            Write-Host ("格式    {0}" -f $ext.TrimStart('.').ToUpper())
        }
        catch { Write-Host '（图片信息读取失败）' -ForegroundColor DarkYellow }
        finally { if ($img) { $img.Dispose() } }
    }

    if ($Extra -and $Extra.Count -gt 0) {
        foreach ($k in $Extra.Keys) { Write-Host ("{0}    {1}" -f $k.PadRight(6), $Extra[$k]) }
    }
    Write-Host '──────────────────────────' -ForegroundColor Cyan
}

function Show-LatestMedia {
    param(
        [ValidateSet('video', 'image')][string]$Kind = 'video',
        [hashtable]$Extra = @{}
    )
    $desk = [Environment]::GetFolderPath('Desktop')
    $dir = if ($Kind -eq 'video') { Join-Path $desk '视频' } else { Join-Path $desk 'Qwen 图片' }
    $pat = if ($Kind -eq 'video') { '*.mp4' } else { '*.png' }
    $latest = Get-ChildItem $dir -Filter $pat -File -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending | Select-Object -First 1
    if ($latest) { Show-MediaInfo -Path $latest.FullName -Extra $Extra }
}
