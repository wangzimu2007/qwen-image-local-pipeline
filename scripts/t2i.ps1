# 文生图（Qwen-Image 2.1 Turbo，stable-diffusion.cpp）
# 用法：scripts\t2i.ps1 -Prompt "黄昏的海岸灯塔"
param(
    [Parameter(Mandatory = $true)][string]$Prompt,
    [int]$Width = 1024,
    [int]$Height = 1024,
    [int]$Steps = 8,
    [int]$Seed = -1,
    [string]$Negative = '',
    [string]$OutDir = '',
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\info.ps1"
$cfg = Get-PipelineConfig
$py  = Get-Python $cfg

$exe = Assert-FilePath $cfg.SdCli 'sd-cli.exe' '编译 stable-diffusion.cpp 或从 Release 下载'
Assert-FilePath $cfg.ModelT2I '文生图模型' '见 NOTICE.md 模型清单' | Out-Null
Assert-FilePath $cfg.ModelT2I_Te '文生图文本编码器' '见 NOTICE.md 模型清单' | Out-Null
Assert-FilePath $cfg.ModelT2I_Vae '文生图 VAE' '见 NOTICE.md 模型清单' | Out-Null

$dir = if ($OutDir) { Ensure-Dir $OutDir } else { Ensure-Dir $cfg.OutImageDir }
$out = Join-Path $dir ("qwen-{0}-t2i.png" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

# Turbo 模型用 8 步蒸馏 sigma 序列；若 config 里没写就用默认
$sigmas = if ($cfg.T2ISigmas) { $cfg.T2ISigmas } else { '1.0,0.978453,0.95418,0.926626,0.89508,0.845148,0.704534,0.414568,0.0' }

Write-Head '文生图'
Write-Info ("{0} × {1} / {2} 步 / {3}" -f $Width, $Height, $Steps, (Split-Path $cfg.ModelT2I -Leaf))
Wait-FreeVram -MinMB 12000 -TimeoutSec $cfg.VramWaitSec | Out-Null

$a = @(
    '--diffusion-model', $cfg.ModelT2I,
    '--llm', $cfg.ModelT2I_Te,
    '--vae', $cfg.ModelT2I_Vae,
    '-p', $Prompt,
    '--steps', "$Steps",
    '--cfg-scale', '1.0',
    '--sampling-method', 'euler',
    '--sigmas', $sigmas,
    '-W', "$Width", '-H', "$Height",
    '--diffusion-fa',
    '-o', $out
)
if ($Negative) { $a += @('--negative-prompt', $Negative) }
if ($Seed -ge 0) { $a += @('--seed', "$Seed") }

$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Exe -Exe $exe -Arguments $a
$sw.Stop()

if ($r.ExitCode -ne 0 -or -not (Test-Path $out)) {
    Write-Warn2 ("生成失败（退出码 {0}）" -f $r.ExitCode)
    ($r.Output | Select-Object -Last 12) | ForEach-Object { Write-Info $_ }
    exit 1
}
Write-Ok ("生成完成，用时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds)
Show-MediaInfo -Path $out -Python $py -Extra @{ '模型' = 'Qwen-Image 2.1 Turbo'; '步数' = $Steps }
if (-not $NoOpen) { try { Start-Process $out } catch {} }
exit 0
