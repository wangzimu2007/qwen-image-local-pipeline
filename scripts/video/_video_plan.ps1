# 视频规划共享规则：根据提示词/时长/帧率/显存返回生成策略
# 由 视频规划.ps1、智能出片.ps1 共用，避免规则重复。
function Get-FreeVramMiB {
    try {
        $raw = & nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null
        if ($raw) { return [int](($raw -split "`n")[0].Trim()) }
    } catch { }
    return 0
}

function Get-VideoPlan {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [string]$Image = '',
        [double]$Seconds = 5,
        [int]$Fps = 24,
        [ValidateSet('draft', 'normal', 'high')][string]$Quality = 'normal',
        [switch]$WithAudio
    )

    $sceneStatic = $Prompt -match '固定|静止|不动|完全静止|保持不动|极慢|缓慢|微小|轻微|轻轻|呼吸|眨眼|慢动作|微风'
    $sceneCamera = $Prompt -match '推进|拉远|拉近|环绕|摇镜|旋转|跟随|运镜|平移|俯冲|镜头移动|移动镜头|推镜'
    $sceneAction = $Prompt -match '跑|跳|打斗|转身|挥手|快速|奔跑|舞蹈|大幅|剧烈|冲刺|翻滚|挥舞|拥抱|亲吻'
    $needAudio = $WithAudio -or ($Prompt -match '声音|对白|台词|配音|音效|环境音|BGM|音乐')

    if ($sceneCamera -and $sceneAction) { $scene = 'camera+action' }
    elseif ($sceneCamera) { $scene = 'camera' }
    elseif ($sceneAction) { $scene = 'action' }
    elseif ($sceneStatic) { $scene = 'static' }
    else { $scene = 'neutral' }

    $steps = if ($Quality -eq 'draft') { 12 } elseif ($Quality -eq 'high') { 24 } else { 20 }
    $free = Get-FreeVramMiB

    $mode = ''
    $useFps = $Fps
    $useSeconds = $Seconds
    $post = ''
    $segments = 1
    $segSeconds = $Seconds
    $notes = New-Object System.Collections.ArrayList

    if ($Seconds -le 5) {
        $mode = 'single'
        [void]$notes.Add('时长 ≤5 秒，单段生成最稳，不需要续接')
    }
    elseif ($Seconds -le 10 -and $scene -in @('static', 'neutral')) {
        $mode = 'single_lowfps'
        $useFps = 12
        $post = 'interp2'
        [void]$notes.Add('镜头/主体基本不动：单段 12fps 生成，再用 FILM ×2 补到 24fps，避免分段接缝')
        [void]$notes.Add('10 秒 @12fps = 120 帧，显存约 17~18GB，比 24fps 的 240 帧稳很多')
    }
    elseif ($Seconds -le 10) {
        $mode = 'segments_continuation'
        $segments = [int][math]::Ceiling($Seconds / 5)
        $segSeconds = 5
        $useSeconds = 5
        [void]$notes.Add('镜头有运动/动作较复杂：单段 10 秒容易崩，建议 2×5 秒续接')
        [void]$notes.Add('续接用上一段末帧，接缝可能轻微跳变；必要时后续加交叉淡化')
    }
    else {
        if ($scene -in @('static', 'neutral')) {
            $mode = 'segments_same_first'
            [void]$notes.Add('超过 10 秒且画面基本静止：建议同首帧多段生成，再加交叉淡化，避免末帧漂移')
        } else {
            $mode = 'segments_continuation'
            [void]$notes.Add('超过 10 秒且镜头/动作持续：建议 5 秒一段续接，段间加 0.4~0.5 秒交叉淡化')
        }
        $segments = [int][math]::Ceiling($Seconds / 5)
        $segSeconds = 5
        $useSeconds = 5
    }

    $plannedFrames = if ($mode -in @('segments_continuation', 'segments_same_first')) {
        [int]($segSeconds * 24)
    } else {
        [int][math]::Round($useSeconds * $useFps)
    }
    $estimate = 17500 + [math]::Max(0, ($plannedFrames - 120)) * 60
    $risk = ($free -gt 0 -and $free -lt $estimate)

    if ($needAudio) {
        if ([string]::IsNullOrWhiteSpace($Image)) {
            [void]$notes.Add('需要声音：优先用文本生视频 H3（自带音频）')
        } else {
            [void]$notes.Add('需要声音：Wan 图生视频本身无声，生成后用音频模块/视频配音补音效或旁白')
        }
    }
    if ($risk) {
        [void]$notes.Add(('显存风险：当前可用 {0} MB < 预估 {1} MB；先走 提交作业/显存门禁 卸载聊天模型' -f $free, $estimate))
        [void]$notes.Add('本地模型会话请用：提交作业.ps1 -Task smarti2v ... -Wait')
    } else {
        [void]$notes.Add(('显存：当前可用 {0} MB，预估 {1} MB' -f $free, $estimate))
    }

    return [pscustomobject]@{
        prompt = $Prompt
        image = $Image
        seconds = $Seconds
        fps = $Fps
        quality = $Quality
        scene = $scene
        needAudio = [bool]$needAudio
        mode = $mode
        useSeconds = $useSeconds
        useFps = $useFps
        steps = $steps
        post = $post
        segments = $segments
        segmentSeconds = $segSeconds
        plannedFrames = $plannedFrames
        vramFreeMB = $free
        vramEstimateMB = $estimate
        vramRisk = $risk
        notes = @($notes)
    }
}
