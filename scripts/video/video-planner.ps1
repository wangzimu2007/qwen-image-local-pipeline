# 视频规划：根据提示词、时长、帧率、显存，智能选择生成策略
# 规则在 _video_plan.ps1 中，和 智能出片.ps1 共用。
param(
    [Parameter(Mandatory = $true)][string]$Prompt,
    [string]$Image = '',
    [double]$Seconds = 5,
    [int]$Fps = 24,
    [ValidateSet('draft', 'normal', 'high')][string]$Quality = 'normal',
    [switch]$WithAudio,
    [switch]$Json,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_video_plan.ps1')

function Pause-Brief { param([int]$S = 8) if ($NoPause) { return }; Write-Host ''; Write-Host "窗口将在 $S 秒后自动关闭..." -ForegroundColor DarkGray; Start-Sleep -Seconds $S }

$plan = Get-VideoPlan -Prompt $Prompt -Image $Image -Seconds $Seconds -Fps $Fps -Quality $Quality -WithAudio:$WithAudio

$imgArg = if ($Image) { '-Image "' + $Image + '"' } else { '-Image "你的图.png"' }
$cmd = ''
if ($plan.mode -in @('single', 'single_lowfps')) {
    $cmd = 'D:\qwen-image-2.1\图生视频.ps1 ' + $imgArg + ' -Prompt "' + $Prompt + '" -Seconds ' + $plan.useSeconds + ' -Fps ' + $plan.useFps + ' -Steps ' + $plan.steps
    if ($plan.post -eq 'interp2') {
        $cmd += "`n# 生成完成后：`nD:\qwen-image-2.1\后期处理.ps1 -Video `"生成的视频.mp4`" -Interp 2"
    }
} elseif ($plan.mode -eq 'segments_continuation') {
    $cmd = 'D:\qwen-image-2.1\图生视频.ps1 ' + $imgArg + ' -Prompt "' + $Prompt + '" -Seconds 5 -Fps 24 -Steps ' + $plan.steps
    $cmd += "`n# 然后续接：`nD:\qwen-image-2.1\续接视频.ps1 -Video `"第一段.mp4`" -Segments " + ($plan.segments - 1) + ' -Seconds 5 -Prompt "' + $Prompt + '"'
} else {
    $cmd = 'D:\qwen-image-2.1\图生视频.ps1 ' + $imgArg + ' -Prompt "' + $Prompt + '" -Seconds 5 -Fps 24 -Steps ' + $plan.steps
    $cmd += "`n# 重复生成 " + $plan.segments + " 段（同一张图），最后用拼接+交叉淡化合成"
}

$plan | Add-Member -NotePropertyName commands -NotePropertyValue $cmd -Force

if ($Json) {
    $plan | ConvertTo-Json -Depth 5
    exit 0
}

Write-Host ''
Write-Host '=== 视频生成规划 ===' -ForegroundColor Cyan
Write-Host ('需求：{0} 秒 / {1}fps / 质量 {2}' -f $Seconds, $Fps, $Quality)
Write-Host ('提示词：{0}' -f $Prompt)
Write-Host ('场景判断：{0}' -f $plan.scene) -ForegroundColor Yellow
Write-Host ''
Write-Host ('建议模式：{0}' -f $plan.mode) -ForegroundColor Green
if ($plan.mode -eq 'single') {
    Write-Host ('  单段 {0} 秒 @ {1}fps，{2} 步' -f $plan.useSeconds, $plan.useFps, $plan.steps)
} elseif ($plan.mode -eq 'single_lowfps') {
    Write-Host ('  单段 {0} 秒 @ 12fps（{1} 帧），{2} 步；生成后用 FILM ×2 补到 24fps' -f $plan.useSeconds, $plan.plannedFrames, $plan.steps)
} elseif ($plan.mode -eq 'segments_continuation') {
    Write-Host ('  分 {0} 段，每段 {1} 秒 @ 24fps，用续接' -f $plan.segments, $plan.segmentSeconds)
} else {
    Write-Host ('  分 {0} 段，每段 {1} 秒 @ 24fps，同首帧生成 + 交叉淡化' -f $plan.segments, $plan.segmentSeconds)
}
Write-Host ('显存：可用 {0} MB / 预估 {1} MB（按推荐规格 {2} 帧）{3}' -f $plan.vramFreeMB, $plan.vramEstimateMB, $plan.plannedFrames, $(if ($plan.vramRisk) { '  ⚠ 不足，先卸载聊天模型' } else { '' })) -ForegroundColor $(if ($plan.vramRisk) { 'Red' } else { 'DarkGray' })
Write-Host ''
Write-Host '说明：' -ForegroundColor Yellow
foreach ($n in $plan.notes) { Write-Host ('  · ' + $n) }
Write-Host ''
Write-Host '推荐命令：' -ForegroundColor Yellow
$cmd -split "`n" | ForEach-Object { Write-Host ('  ' + $_) }
Pause-Brief
exit 0
