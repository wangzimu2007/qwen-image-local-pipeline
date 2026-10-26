# 视频统一入口（一句话干一件事）：把各脚本按 Action 分派，参数可调，带预设档位
#
# 用法举例：
#   powershell -File D:\qwen-image-2.1\视频.ps1 -Action t2v -Prompt "海边灯塔，黄昏" -Seconds 5 -Preset draft
#   ... -Action i2v -Image "某图.png" -Prompt "镜头推进"
#   ... -Action extend -Video "video-0002....mp4" -Segments 2
#   ... -Action join -Videos "a.mp4,b.mp4"
#   ... -Action trim -Video "x.mp4" -Start 1 -Duration 3
#   ... -Action upscale -Video "x.mp4" -Preset final        # AI 超分 720p + 插帧 2
#   ... -Action upscale -Video "x.mp4" -Resolution 1080 -Interp 1   # 只超分不插帧
#   ... -Action upscale -Video "x.mp4" -Method lanczos -Scale 1.5    # 快速放大
#   ... -Action restyle -Video "x.mp4" -Prompt "水彩风" -Every 8
#
# 预设（-Preset）：
#   draft  = 草稿：生成 832×480，不做后期（快）
#   fast   = 快速定稿：Lanczos 1.5× + 插帧 2（约 30 秒）
#   final  = 高质量定稿：AI 超分 720p + 插帧 2（约 2 分钟）
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('t2v', 'i2v', 'extend', 'join', 'trim', 'upscale', 'restyle')]
    [string]$Action,

    [string]$Prompt,
    [string]$Image,
    [string]$Video,
    [string]$Videos,

    [ValidateSet('draft', 'fast', 'final')]
    [string]$Preset = '',

    [int]$Seconds = 5,
    [int]$Fps = 24,
    [int]$Steps = 20,

    # upscale 专用
    [ValidateSet('ai', 'lanczos', 'flashvsr')]
    [string]$Method = 'ai',
    [int]$Resolution = 720,
    [int]$Width = 832,
    [int]$Height = 480,
    [int]$BatchSize = 21,
    [double]$Scale = 1.5,
    [int]$Interp = 2,

    # trim 专用
    [double]$Start = 0,
    [double]$Duration = 0,

    # restyle 专用
    [int]$Every = 8,
    [double]$Strength = 0.55,

    [int]$Segments = 1,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

function Newest-Video {
    param([string]$Dir = 'C:\Users\wangzimu\Desktop\视频')
    return (Get-ChildItem $Dir -Filter '*.mp4' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1)
}
$root = 'D:\qwen-image-2.1'
$desk = [Environment]::GetFolderPath('Desktop')
$videoDir = Join-Path $desk '视频'
$akiPy = 'D:\ComfyUI-aki-v3.2\python\python.exe'

function Need-Param {
    param([string]$Value, [string]$Name)
    if (-not $Value) { Write-Warning "缺少参数 -$Name"; exit 1 }
}

function Find-Video {
    param([string]$P)
    if (Test-Path $P) { return (Resolve-Path $P).Path }
    $cand = Join-Path $videoDir $P
    if (Test-Path $cand) { return (Resolve-Path $cand).Path }
    Write-Warning "找不到视频：$P"
    exit 1
}

function Run-Script {
    # 注意：参数名不能叫 $Args（PowerShell 自动变量，会被吃掉）
    param([string]$File, [string[]]$ScriptArgs)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $File) + $ScriptArgs
    # 子脚本会往 stderr 写原生命令的警告，Stop 模式下会被当终止性错误
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & powershell @all 2>&1 | ForEach-Object { '  ' + $_ }
    $ErrorActionPreference = $prev
}

# 预设 → 参数
if ($Preset -eq 'draft') {
    $Scale = 1; $Interp = 1; $Resolution = 0
}
elseif ($Preset -eq 'fast') {
    $Method = 'lanczos'; $Scale = 1.5; $Interp = 2
}
elseif ($Preset -eq 'final') {
    $Method = 'ai'; $Resolution = 720; $Interp = 2
}

Write-Host ("== Action={0}  Preset={1} ==" -f $Action, $(if ($Preset) { $Preset } else { '无' })) -ForegroundColor Cyan

switch ($Action) {
    'i2v' {
        Need-Param $Image 'Image'
        $a = @('-Image', $Image, '-Seconds', $Seconds, '-Fps', $Fps, '-Steps', $Steps, '-NoPause')
        if ($Prompt) { $a += @('-Prompt', $Prompt) }
        if ($Preset -eq 'final') { $a += @('-KeepServer') }
        Run-Script (Join-Path $root '图生视频.ps1') $a
    }

    't2v' {
        Need-Param $Prompt 'Prompt'
        # 第一步：出一张图（用文生图脚本，尺寸小一点，给视频留余量）
        $still = Join-Path $env:TEMP ("t2v-" + (Get-Date -Format 'HHmmss') + ".png")
        $sa = @('-Prompt', $Prompt, '-Width', 1024, '-Height', 1024, '-OutDir', $env:TEMP, '-NoOpen', '-NoPause', '-NoAsk')
        Write-Host '  [1/2] 生成首帧...' -ForegroundColor Yellow
        Run-Script (Join-Path $root '画图.ps1') $sa
        $latest = Get-ChildItem $env:TEMP -Filter 'qwen-*-t2i-*.png' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) { Write-Warning '首帧生成失败'; exit 1 }
        Write-Host '  [2/2] 首帧 → 视频...' -ForegroundColor Yellow
        $a = @('-Image', $latest.FullName, '-Seconds', $Seconds, '-Fps', $Fps, '-Steps', $Steps, '-NoPause')
        if ($Prompt) { $a += @('-Prompt', "镜头缓慢推进，$Prompt") }
        Run-Script (Join-Path $root '图生视频.ps1') $a
    }

    'extend' {
        Need-Param $Video 'Video'
        $v = Find-Video $Video
        $a = @('-Video', $v, '-Segments', $Segments, '-Seconds', $Seconds, '-Steps', $Steps, '-NoPause')
        if ($Prompt) { $a += @('-Prompt', $Prompt) }
        Run-Script (Join-Path $root '续接视频.ps1') $a
    }

    'join' {
        Need-Param $Videos 'Videos'
        Run-Script (Join-Path $root '拼接视频.ps1') @('-Videos', $Videos, '-NoPause')
    }

    'trim' {
        Need-Param $Video 'Video'
        $v = Find-Video $Video
        $out = Join-Path (Join-Path $desk 'ComfyUI 输出') ("wan-trim-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".mp4")
        & $akiPy (Join-Path $root '_video_tools.py') trim $v $out $Start $Duration 2>&1 | ForEach-Object { '  ' + $_ }
        Run-Script (Join-Path $root '整理视频.ps1') @('-NoPause')
    }

    'upscale' {
        Need-Param $Video 'Video'
        $v = Find-Video $Video
        if ($Method -eq 'flashvsr') {
            $fv = Join-Path $PSScriptRoot 'AI超分FlashVSR.ps1'
            $fvScale = if ($Scale -ge 2) { [int][math]::Round($Scale) } else { 2 }
            $a = @('-Video', $Video, '-Scale', $fvScale)
            if ($Width -gt 0) { $a += @('-Width', $Width) }
            if ($Height -gt 0) { $a += @('-Height', $Height) }
            Run-Script $fv $a
            $latest = Newest-Video
            if ($latest -and $Interp -ge 2) {
                Run-Script (Join-Path $PSScriptRoot '后期处理.ps1') @('-Video', $latest.FullName, '-Scale', 1, '-Interp', $Interp)
            }
        }
        elseif ($Method -eq 'ai' -and $Resolution -gt 0) {
            Write-Host ("  AI 超分到短边 {0}p ..." -f $Resolution) -ForegroundColor Yellow
            Run-Script (Join-Path $root 'AI超分.ps1') @('-Video', $v, '-Resolution', $Resolution, '-BatchSize', $BatchSize, '-NoPause')
            if ($Interp -ge 2) {
                $latest = Get-ChildItem $videoDir -Filter '*.mp4' | Sort-Object Name -Descending | Select-Object -First 1
                Write-Host ("  再插帧 ×{0} ..." -f $Interp) -ForegroundColor Yellow
                Run-Script (Join-Path $root '后期处理.ps1') @('-Video', $latest.FullName, '-Scale', 1, '-Interp', $Interp, '-NoPause')
            }
        }
        else {
            $sc = if ($Scale -le 0) { 1 } else { $Scale }
            Write-Host ("  Lanczos 放大 ×{0}，插帧 ×{1} ..." -f $sc, $Interp) -ForegroundColor Yellow
            Run-Script (Join-Path $root '后期处理.ps1') @('-Video', $v, '-Scale', $sc, '-Interp', $Interp, '-NoPause')
        }
    }

    'restyle' {
        Need-Param $Video 'Video'
        Need-Param $Prompt 'Prompt'
        Run-Script (Join-Path $root '视频生视频.ps1') @('-Video', $Video, '-Prompt', $Prompt, '-Every', $Every, '-Strength', $Strength, '-NoPause')
    }
}

# 生成类动作（t2v / i2v）在 fast/final 预设下自动接后期
if (($Action -eq 't2v' -or $Action -eq 'i2v') -and ($Preset -eq 'fast' -or $Preset -eq 'final')) {
    $latest = Get-ChildItem $videoDir -Filter '*.mp4' -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending | Select-Object -First 1
    if ($latest) {
        Write-Host ("== 后期处理（{0}）：{1} ==" -f $Preset, $latest.Name) -ForegroundColor Cyan
        if ($Preset -eq 'final') {
            Write-Host ("  [1/2] AI 超分到短边 {0}p ..." -f $Resolution) -ForegroundColor Yellow
            Run-Script (Join-Path $root 'AI超分.ps1') @('-Video', $latest.FullName, '-Resolution', $Resolution, '-BatchSize', $BatchSize, '-NoPause')
            if ($Interp -ge 2) {
                $latest2 = Get-ChildItem $videoDir -Filter '*.mp4' | Sort-Object Name -Descending | Select-Object -First 1
                Write-Host ("  [2/2] 插帧 ×{0} ..." -f $Interp) -ForegroundColor Yellow
                Run-Script (Join-Path $root '后期处理.ps1') @('-Video', $latest2.FullName, '-Scale', 1, '-Interp', $Interp, '-NoPause')
            }
        }
        else {
            $sc = if ($Scale -le 0) { 1.5 } else { $Scale }
            Write-Host ("  Lanczos 放大 ×{0} + 插帧 ×{1} ..." -f $sc, $Interp) -ForegroundColor Yellow
            Run-Script (Join-Path $root '后期处理.ps1') @('-Video', $latest.FullName, '-Scale', $sc, '-Interp', $Interp, '-NoPause')
        }
    }
}

if (-not $NoPause) {
    Write-Host ''
    Write-Host '完成。成品在桌面「视频」文件夹（按名称降序，最新在最上面）。' -ForegroundColor Green
    Start-Sleep -Seconds 6
}
exit 0
