# 图生图（在已有图上按提示词重绘）
# 用法：scripts\img2img.ps1 -Image x.png -Prompt "改成油画风格" -Strength 0.85
# 强度参考：0.55~0.7 局部微调 / 0.85 整体重绘 / 0.9+ 明显脱离原图
param(
    [Parameter(Mandatory = $true)][string]$Image,
    [Parameter(Mandatory = $true)][string]$Prompt,
    [double]$Strength = 0.85,
    [int]$Width = 1024,
    [int]$Height = 1024,
    [int]$Steps = 8,
    [int]$Seed = -1,
    [string]$OutDir = '',
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\info.ps1"
$cfg = Get-PipelineConfig
$py  = Get-Python $cfg

$exe = Assert-FilePath $cfg.SdCli 'sd-cli.exe'
$src = Assert-FilePath $Image '输入图片'
$model = if ($cfg.ModelRedraw) { $cfg.ModelRedraw } else { $cfg.ModelT2I }
Assert-FilePath $model '图生图模型' '见 NOTICE.md 模型清单' | Out-Null
Assert-FilePath $cfg.ModelT2I_Te '文本编码器' | Out-Null
Assert-FilePath $cfg.ModelT2I_Vae 'VAE' | Out-Null

$dir = if ($OutDir) { Ensure-Dir $OutDir } else { Ensure-Dir $cfg.OutImageDir }
$out = Join-Path $dir ("qwen-{0}-redraw.png" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$sigmas = if ($cfg.T2ISigmas) { $cfg.T2ISigmas } else { '1.0,0.978453,0.95418,0.926626,0.89508,0.845148,0.704534,0.414568,0.0' }

Write-Head '图生图'
Write-Info ("强度 {0} / {1} × {2}" -f $Strength, $Width, $Height)
Wait-FreeVram -MinMB 12000 -TimeoutSec $cfg.VramWaitSec | Out-Null

$a = @(
    '--diffusion-model', $model,
    '--llm', $cfg.ModelT2I_Te,
    '--vae', $cfg.ModelT2I_Vae,
    '-p', $Prompt,
    '--steps', "$Steps",
    '--cfg-scale', '1.0',
    '--sampling-method', 'euler',
    '--sigmas', $sigmas,
    '-W', "$Width", '-H', "$Height",
    '--diffusion-fa',
    '-i', $src,
    '--strength', "$Strength",
    '-o', $out
)
if ($Seed -ge 0) { $a += @('--seed', "$Seed") }

$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Exe -Exe $exe -Arguments $a
$sw.Stop()

if ($r.ExitCode -ne 0 -or -not (Test-Path $out)) {
    Write-Warn2 ("重绘失败（退出码 {0}）" -f $r.ExitCode)
    ($r.Output | Select-Object -Last 12) | ForEach-Object { Write-Info $_ }
    exit 1
}
Write-Ok ("重绘完成，用时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds)
Show-MediaInfo -Path $out -Python $py -Extra @{ '模型' = 'Qwen-Image 2.1 Turbo（图生图）'; '强度' = $Strength }
if (-not $NoOpen) { try { Start-Process $out } catch {} }
exit 0
