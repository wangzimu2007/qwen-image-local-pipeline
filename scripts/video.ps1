# 统一入口：按 -Action 分派到各脚本，带 draft/fast/final 预设
#
# 用法：
#   scripts\video.ps1 -Action t2v  -Prompt "海边灯塔" -Seconds 5 -Preset draft
#   scripts\video.ps1 -Action i2v  -Image x.png -Prompt "镜头推进" -Preset final
#   scripts\video.ps1 -Action extend -Video x.mp4 -Segments 2
#   scripts\video.ps1 -Action join  -Videos "a.mp4,b.mp4"
#   scripts\video.ps1 -Action trim  -Video x.mp4 -Start 1 -Duration 3
#   scripts\video.ps1 -Action upscale -Video x.mp4 -Preset final
#   scripts\video.ps1 -Action restyle -Video x.mp4 -Prompt "水彩风" -Every 8
#
# 预设：draft=不后期 / fast=Lanczos1.5+插帧2 / final=AI超分720+插帧2
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('t2v', 'i2v', 'extend', 'join', 'trim', 'upscale', 'restyle')]
    [string]$Action,

    [string]$Prompt,
    [string]$Image,
    [string]$Video,
    [string]$Videos,

    [ValidateSet('', 'draft', 'fast', 'final')]
    [string]$Preset = '',

    [int]$Seconds = 5,
    [int]$Fps = 24,
    [int]$Steps = 20,

    [ValidateSet('ai', 'lanczos')]
    [string]$Method = 'ai',
    [int]$Resolution = 720,
    [int]$BatchSize = 21,
    [double]$Scale = 1.5,
    [int]$Interp = 2,

    [double]$Start = 0,
    [double]$Duration = 0,
    [int]$Every = 8,
    [double]$Strength = 0.55,
    [int]$Segments = 1,
    [switch]$NoInfo
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\output.ps1"
$cfg = Get-PipelineConfig
$py  = Get-Python $cfg

function Run-Script {
    param([string]$File, [string[]]$ScriptArgs)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $File) + $ScriptArgs
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & powershell @all 2>&1 | ForEach-Object { '  ' + $_ }
    $ErrorActionPreference = $prev
}

function Newest-Video { Get-ChildItem $cfg.OutVideoDir -Filter '*.mp4' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1 }

if ($Preset -eq 'draft')      { $Scale = 1;   $Interp = 1; $Resolution = 0 }
elseif ($Preset -eq 'fast')   { $Method = 'lanczos'; $Scale = 1.5; $Interp = 2 }
elseif ($Preset -eq 'final')  { $Method = 'ai'; $Resolution = 720; $Interp = 2 }

Write-Head ("Action={0}  Preset={1}" -f $Action, $(if ($Preset) { $Preset } else { '无' }))

switch ($Action) {
    'i2v' {
        if (-not $Image) { Fail '缺少 -Image' }
        $a = @('-Image', $Image, '-Prompt', $Prompt, '-Seconds', $Seconds, '-Fps', $Fps, '-Steps', $Steps)
        Run-Script (Join-Path $PSScriptRoot 'i2v.ps1') $a
    }
    't2v' {
        if (-not $Prompt) { Fail '缺少 -Prompt' }
        Write-Info '[1/2] 生成首帧'
        Run-Script (Join-Path $PSScriptRoot 't2i.ps1') @('-Prompt', $Prompt, '-NoOpen')
        $still = Get-ChildItem $cfg.OutImageDir -Filter '*.png' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $still) { Fail '首帧生成失败' }
        Write-Info '[2/2] 首帧 → 视频'
        Run-Script (Join-Path $PSScriptRoot 'i2v.ps1') @('-Image', $still.FullName, '-Prompt', "镜头缓慢推进，$Prompt", '-Seconds', $Seconds, '-Fps', $Fps, '-Steps', $Steps)
    }
    'extend' {
        if (-not $Video) { Fail '缺少 -Video' }
        Run-Script (Join-Path $PSScriptRoot 'extend.ps1') @('-Video', $Video, '-Prompt', $Prompt, '-Segments', $Segments, '-Seconds', $Seconds, '-Steps', $Steps)
    }
    'join' {
        if (-not $Videos) { Fail '缺少 -Videos' }
        Run-Script (Join-Path $PSScriptRoot 'concat.ps1') @('-Videos', $Videos)
    }
    'trim' {
        if (-not $Video) { Fail '缺少 -Video' }
        Run-Script (Join-Path $PSScriptRoot 'trim.ps1') @('-Video', $Video, '-Start', $Start, '-Duration', $Duration)
    }
    'upscale' {
        if (-not $Video) { Fail '缺少 -Video' }
        if ($Method -eq 'ai' -and $Resolution -gt 0) {
            Run-Script (Join-Path $PSScriptRoot 'ai-upscale.ps1') @('-Video', $Video, '-Resolution', $Resolution, '-BatchSize', $BatchSize)
            if ($Interp -ge 2) {
                $latest = Newest-Video
                if ($latest) { Run-Script (Join-Path $PSScriptRoot 'post.ps1') @('-Video', $latest.FullName, '-Scale', 1, '-Interp', $Interp) }
            }
        } else {
            $sc = if ($Scale -le 0) { 1 } else { $Scale }
            Run-Script (Join-Path $PSScriptRoot 'post.ps1') @('-Video', $Video, '-Scale', $sc, '-Interp', $Interp)
        }
    }
    'restyle' {
        if (-not $Video) { Fail '缺少 -Video' }
        if (-not $Prompt) { Fail '缺少 -Prompt' }
        Run-Script (Join-Path $PSScriptRoot 'restyle.ps1') @('-Video', $Video, '-Prompt', $Prompt, '-Every', $Every, '-Strength', $Strength)
    }
}

# 生成类动作在 fast/final 下自动接后期
if (($Action -eq 't2v' -or $Action -eq 'i2v') -and ($Preset -eq 'fast' -or $Preset -eq 'final')) {
    $latest = Newest-Video
    if ($latest) {
        Write-Head ("后期处理（{0}）：{1}" -f $Preset, $latest.Name)
        if ($Preset -eq 'final') {
            Run-Script (Join-Path $PSScriptRoot 'ai-upscale.ps1') @('-Video', $latest.FullName, '-Resolution', $Resolution, '-BatchSize', $BatchSize)
            if ($Interp -ge 2) {
                $latest2 = Newest-Video
                if ($latest2) { Run-Script (Join-Path $PSScriptRoot 'post.ps1') @('-Video', $latest2.FullName, '-Scale', 1, '-Interp', $Interp) }
            }
        } else {
            $sc = if ($Scale -le 0) { 1.5 } else { $Scale }
            Run-Script (Join-Path $PSScriptRoot 'post.ps1') @('-Video', $latest.FullName, '-Scale', $sc, '-Interp', $Interp)
        }
    }
}

$final = Newest-Video
if ($final) {
    Write-Host ''
    Write-Ok ("成品：" + $final.FullName)
    if (-not $NoInfo) { . "$PSScriptRoot\lib\info.ps1"; Show-MediaInfo -Path $final.FullName -Python $py }
}
exit 0
