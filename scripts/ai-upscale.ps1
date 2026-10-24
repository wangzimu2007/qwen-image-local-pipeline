# 视频 AI 超分（SeedVR2 3B，官方 CLI）——带时序信息，不闪
# 用法：
#   scripts\ai-upscale.ps1 -Video x.mp4 -Resolution 720
#   scripts\ai-upscale.ps1 -Video x.mp4 -Resolution 1080 -BatchSize 13   # 1080p 必须开分块（脚本自动加）
param(
    [Parameter(Mandatory = $true)][string]$Video,
    [int]$Resolution = 720,      # 目标短边：720 / 1080
    [int]$BatchSize = 21,        # 必须 4n+1，显存不够就降到 13/9/5
    [string]$Color = 'lab',      # lab / wavelet / waveinet / adain / none
    [switch]$NoInfo
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\output.ps1"
. "$PSScriptRoot\lib\info.ps1"
$cfg = Get-PipelineConfig
$py  = Get-Python $cfg
$tools = Join-Path $PSScriptRoot 'lib\video_tools.py'

$cli = Assert-FilePath (Join-Path $cfg.SeedVR2Root 'inference_cli.py') 'SeedVR2 CLI' 'git clone numz/ComfyUI-SeedVR2_VideoUpscaler'
Assert-FilePath (Join-Path $cfg.SeedVR2Models $cfg.SeedVR2Dit) 'SeedVR2 3B 模型' '见 NOTICE.md 模型清单' | Out-Null
$svPy = if ($cfg.SeedVR2Python -and (Test-Path $cfg.SeedVR2Python)) { $cfg.SeedVR2Python } else { $py }

$videoPath = $Video
if (-not (Test-Path $videoPath)) {
    $cand = Join-Path $cfg.OutVideoDir $Video
    if (Test-Path $cand) { $videoPath = $cand } else { throw ("找不到视频：" + $Video) }
}
$videoPath = (Resolve-Path $videoPath).Path

# batch 必须 4n+1
if ((($BatchSize - 1) % 4) -ne 0) {
    $BatchSize = 4 * [int][math]::Round(($BatchSize - 1) / 4.0) + 1
    if ($BatchSize -lt 5) { $BatchSize = 5 }
}

# CLI 内部用 OpenCV 读文件，中文路径会失败 → 统一复制到英文临时目录
$tmp = Ensure-Dir (Join-Path $env:TEMP 'pipeline-aiup')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$srcAscii = Join-Path $tmp ("src-$stamp.mp4")
Copy-Item -LiteralPath $videoPath -Destination $srcAscii -Force
$outTmp = Join-Path $tmp ("out-$stamp.mp4")

Write-Head 'AI 超分（SeedVR2）'
Write-Info ((Split-Path $videoPath -Leaf) + '  ' + (& $py $tools info $videoPath 2>&1))
Write-Info ("目标短边 {0}p / batch {1} / 色彩 {2}" -f $Resolution, $BatchSize, $Color)

$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'

$a = @($srcAscii,
       '--output', $outTmp,
       '--model_dir', $cfg.SeedVR2Models,
       '--resolution', "$Resolution",
       '--batch_size', "$BatchSize",
       '--color_correction', $Color)
# 1080p 及以上不开 VAE 分块，解码阶段会把显存吃爆（实测 24GB 卡直接崩）
if ($Resolution -ge 900) {
    $a += @('--vae_encode_tiled', '--vae_encode_tile_size', '768', '--vae_encode_tile_overlap', '96',
            '--vae_decode_tiled', '--vae_decode_tile_size', '768', '--vae_decode_tile_overlap', '96')
    Write-Info '已启用 VAE 分块编解码（避免解码爆显存）'
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Exe -Exe $svPy -Arguments (@($cli) + $a)
$sw.Stop()

if (-not (Test-Path $outTmp)) {
    Write-Warn2 '超分失败'
    ($r.Output | Where-Object { $_ -match 'ERROR|Error|Traceback|⚠|❌' } | Select-Object -Last 8) | ForEach-Object { Write-Info $_ }
    exit 1
}

$final = Save-VideoOutput -Config $cfg -SourceFile $outTmp -Kind 'aiup'
Write-Ok ("超分完成，用时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds)
Write-Ok ("成品：" + $final)
if (-not $NoInfo) {
    Show-MediaInfo -Path $final -Python $py -Extra @{ '模型' = 'SeedVR2 3B fp8'; '目标短边' = ("{0}p" -f $Resolution) }
}
exit 0
