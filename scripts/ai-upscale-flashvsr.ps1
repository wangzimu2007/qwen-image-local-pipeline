# 视频 AI 超分（FlashVSR+，官方 triton 稀疏注意力环境）——高分辨率档
#
# 用法：
#   scripts\ai-upscale-flashvsr.ps1 -Video x.mp4
#   scripts\ai-upscale-flashvsr.ps1 -Video x.mp4 -Width 512 -Height 288     # 省显存
#   scripts\ai-upscale-flashvsr.ps1 -Video x.mp4 -Scale 4                   # 更慢更大
#
# 与 seedvr2（ai-upscale.ps1）的分工：
#   · SeedVR2  ：日常 720p / 1080p，显存友好（16GB 够）
#   · FlashVSR+：要超过 720p（1664×896），显存吃得满（24GB 卡实测 23.3GB）
#
# 依赖：ComfyUI + ComfyUI_FlashVSR 节点 + FlashVSR+ turbo 权重 + flashvsr_attn(triton) 内核
#       （安装步骤见 docs/03-upscale.md）
param(
    [Parameter(Mandatory = $true)][string]$Video,
    [int]$Width = 832,          # 处理分辨率（显存由它主导，不是帧数）
    [int]$Height = 480,
    [int]$Scale = 2,            # 1~4
    [string]$PlusTemporal = '4',# 每 latent 帧输入帧数；大运动用 2 或 1（更慢）
    [switch]$KeepServer,
    [switch]$NoInfo
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\output.ps1"
. "$PSScriptRoot\lib\info.ps1"
$cfg = Get-PipelineConfig
$py  = Get-Python $cfg

# ---- 输入解析 ----
$videoPath = $Video
if (-not (Test-Path $videoPath)) {
    $cand = Join-Path $cfg.OutVideoDir $Video
    if (Test-Path $cand) { $videoPath = $cand } else { Fail ("找不到视频：" + $Video) }
}
$videoPath = (Resolve-Path $videoPath).Path

Write-Head 'FlashVSR+ 超分（高分辨率档）'
Write-Info ((Split-Path $videoPath -Leaf) + '  ' + (& $py (Join-Path $PSScriptRoot 'lib\video_tools.py') info $videoPath 2>&1))
Write-Info ("处理 {0}×{1} ×{2} → 输出约 {3}×{4}（高度对齐到 64 倍数）" -f $Width, $Height, $Scale, ($Width * $Scale), ([int]([Math]::Floor($Height * $Scale / 64.0) * 64)))

# ---- ComfyUI 就绪 ----
$startedHere = Start-ComfyIfNeeded -Config $cfg
$inName = Copy-ToComfyInput -Config $cfg -FilePath $videoPath

# ---- 组图 ----
$graph = @{
    '1' = @{ class_type = 'LoadVideo'; inputs = @{ file = $inName } }
    '2' = @{ class_type = 'GetVideoComponents'; inputs = @{ video = @('1', 0) } }
    '3' = @{ class_type = 'FlashVSR_SM_Model'; inputs = @{
                dit = $cfg.FlashVSRDit
                proj_pt = $cfg.FlashVSRProj
                emb_pt = $cfg.FlashVSREmb
                version = $cfg.FlashVSRVersion
                tiny_long = $false
                offload = $true
                plus_temporal = $PlusTemporal
                plus_attn = 'triton_block_sparse' } }
    '4' = @{ class_type = 'FlashVSR_SM_Vae'; inputs = @{
                vae = 'none'; tcd_encoder = $cfg.FlashVSRTcd; lite_vae = 'none' } }
    '5' = @{ class_type = 'FlashVSR_SM_KSampler'; inputs = @{
                model = @('3', 0); image = @('2', 0)
                width = $Width; height = $Height; seed = 42; scale = $Scale
                kv_ratio = 3.5; local_range = 9; steps = 1; cfg = 1.0; sparse_ratio = 2.0 } }
    '6' = @{ class_type = 'FlashVSR_SM_Decoder'; inputs = @{
                vae = @('4', 0); latent = @('5', 0)
                full_tiled = $true; color_fix = $true; fix_method = 'wavelet' } }
    '7' = @{ class_type = 'CreateVideo'; inputs = @{ images = @('6', 0); audio = @('2', 1); fps = @('2', 2) } }
    '8' = @{ class_type = 'SaveVideo'; inputs = @{
                video = @('7', 0); filename_prefix = 'flashvsr-up'
                format = 'mp4'; codec = 'h264' } }
}

$r = Invoke-ComfyPrompt -Config $cfg -Graph $graph -DoneNode '8'
if (-not $r.Ok) {
    Write-Warn2 ('超分失败：' + $r.Error)
    Stop-ComfyIfOwned -Config $cfg -StartedHere $startedHere
    Fail 'FlashVSR+ 执行失败（显存不足就把 -Width/-Height 调小）'
}
Write-Ok ("执行完成，用时 {0:N1} 秒（{1:N1} 分钟）" -f $r.Seconds, ($r.Seconds / 60))

# ---- 产物归位 ----
$comfyOut = Get-ComfyOutputDir -Config $cfg
$produced = Get-NewestFile -Dir $comfyOut -Filter 'flashvsr-up*.mp4'
if (-not $produced) { Stop-ComfyIfOwned -Config $cfg -StartedHere $startedHere; Fail '找不到输出视频' }
$final = Save-VideoOutput -Config $cfg -SourceFile $produced.FullName -Kind 'aiup'
Write-Ok ('成品：' + $final)
if (-not $NoInfo) {
    Show-MediaInfo -Path $final -Python $py -Extra @{
        '模型' = 'FlashVSR+ turbo（triton sparse）'
        '档位' = ("{0}×{1} ×{2}" -f $Width, $Height, $Scale)
    }
}
Stop-ComfyIfOwned -Config $cfg -StartedHere ($startedHere -and -not $KeepServer)
exit 0
