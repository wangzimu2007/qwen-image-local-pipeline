# 指令式编辑（Qwen-Image-Edit-2511）：按语义只改指定部分
# 用法：scripts\edit.ps1 -Image x.png -Prompt "把天空换成夕阳"
# 注意：2511 必须启用 zero_cond_t，否则画质明显退化（脚本已默认加上）
param(
    [Parameter(Mandatory = $true)][string]$Image,
    [Parameter(Mandatory = $true)][string]$Prompt,
    [int]$Width = 1024,
    [int]$Height = 1024,
    [int]$Steps = 20,
    [double]$CfgScale = 2.5,
    [double]$FlowShift = 3,
    [int]$Seed = -1,
    [string]$OutDir = '',
    [switch]$OffloadCpu,
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\info.ps1"
$cfg = Get-PipelineConfig
$py  = Get-Python $cfg

$exe   = Assert-FilePath $cfg.SdCli 'sd-cli.exe'
$src   = Assert-FilePath $Image '输入图片'
$dit   = Assert-FilePath $cfg.ModelEdit '编辑模型（Qwen-Image-Edit-2511）' '见 NOTICE.md'
$te    = Assert-FilePath $cfg.ModelEdit_Te '编辑文本编码器（Qwen2.5-VL）'
$vae   = Assert-FilePath $cfg.ModelEdit_Vae '编辑 VAE（qwen_image_vae，不是 2.1 版）'
$mmproj = $cfg.ModelEdit_Mmproj
if (-not $mmproj -or -not (Test-Path $mmproj)) { $mmproj = '' }

$dir = if ($OutDir) { Ensure-Dir $OutDir } else { Ensure-Dir $cfg.OutImageDir }
$out = Join-Path $dir ("qwen-{0}-edit.png" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

Write-Head '指令式编辑'
Write-Info ("{0} × {1} / {2} 步 / CFG {3}" -f $Width, $Height, $Steps, $CfgScale)
Wait-FreeVram -MinMB 17000 -TimeoutSec $cfg.VramWaitSec | Out-Null

$base = @(
    '--diffusion-model', $dit,
    '--vae', $vae,
    '--llm', $te,
    '--cfg-scale', "$CfgScale",
    '--sampling-method', 'euler',
    '--flow-shift', "$FlowShift",
    '--steps', "$Steps",
    '--diffusion-fa',
    '-W', "$Width", '-H', "$Height",
    '-r', $src,
    '-p', $Prompt,
    '-o', $out
)
if ($mmproj) { $base += @('--llm_vision', $mmproj) }
if ($Seed -ge 0) { $base += @('--seed', "$Seed") }
if ($OffloadCpu) { $base += '--offload-to-cpu' }

# zero_cond_t：不同构建暴露方式不同，按顺序尝试
$variants = @(
    @{ Name = '--model-args qwen_image_zero_cond_t=1'; Extra = @('--model-args', 'qwen_image_zero_cond_t=1') },
    @{ Name = '--qwen-image-zero-cond-t';              Extra = @('--qwen-image-zero-cond-t') },
    @{ Name = '（未启用 zero_cond_t，画质可能下降）';   Extra = @() }
)

$sw = [Diagnostics.Stopwatch]::StartNew()
$ok = $false
$start = Get-Date
foreach ($v in $variants) {
    Write-Info ("尝试参数：" + $v.Name)
    $r = Invoke-Exe -Exe $exe -Arguments @($base + $v.Extra)
    $fresh = (Test-Path $out) -and ((Get-Item $out).LastWriteTime -ge $start.AddSeconds(-5))
    if ($r.ExitCode -eq 0 -and $fresh) { $ok = $true; break }
    Write-Warn2 ("该组合失败（退出码 {0}），尝试下一种" -f $r.ExitCode)
}
$sw.Stop()

if (-not $ok) { Write-Warn2 '编辑失败'; exit 1 }
Write-Ok ("编辑完成，用时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds)
Show-MediaInfo -Path $out -Python $py -Extra @{ '模型' = 'Qwen-Image-Edit-2511'; '步数' = $Steps }
if (-not $NoOpen) { try { Start-Process $out } catch {} }
exit 0
