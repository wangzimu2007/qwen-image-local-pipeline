# _wait.ps1 —— 作业批"真正结束"的等待逻辑（可单独测试）
#
# 为什么需要它：
#   守护是"逐个作业写 done、批末才恢复聊天后端"，所以"done 文件出现"不等于"后端回来了"。
#   本地模型会话如果此时就去推理，会撞上 TRANSPORT。所以要等四个条件同时满足：
#     1) 所有作业的 done 文件存在
#     2) .jobs\guardian.lock 已释放（守护不再跑批）
#     3) .jobs\last-batch.json 的 batchFinishedAt 晚于本次提交（批末恢复与标记已做完）
#     4) 本地聊天后端能应答（Get-LocalBackends -Role chat 里 serving=true）
#
# 由 提交作业.ps1 -Wait 调用；也可单独 dot-source 测试。

function Wait-BatchReady {
    param(
        [string[]]$Ids,
        [string]$JobsRoot = 'D:\qwen-image-2.1\.jobs',
        [datetime]$SubmittedAt = (Get-Date),
        [int]$TimeoutSec = 600,
        [bool]$RequireBackend = $true,
        [switch]$Quiet,
        [int]$PollSeconds = 3
    )

    $doneDir = Join-Path $JobsRoot 'done'
    $lockFile = Join-Path $JobsRoot 'guardian.lock'
    $markFile = Join-Path $JobsRoot 'last-batch.json'
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $spin = '|/-\'
    $tick = 0
    $state = [pscustomobject]@{
        ok = $false; doneCount = 0; total = @($Ids).Count
        lockGone = $false; batchOk = $false; beOk = $false
        backendDesc = '未探测'; elapsedSec = 0; timedOut = $false
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()

    while ((Get-Date) -lt $deadline) {
        $tick++
        # 1) done 文件
        $doneCount = 0
        foreach ($qid in @($Ids)) {
            if (Test-Path (Join-Path $doneDir ($qid + '.json'))) { $doneCount++ }
        }
        # 2) 锁
        $lockGone = -not (Test-Path $lockFile)
        # 3) 批末标记
        $batchOk = $false
        if (Test-Path $markFile) {
            try {
                $mk = Get-Content $markFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($mk.batchFinishedAt -and ([datetime]$mk.batchFinishedAt) -gt $SubmittedAt.AddSeconds(-5)) { $batchOk = $true }
            } catch { }
        }
        # 4) 后端
        $beOk = -not $RequireBackend
        $beDesc = if ($RequireBackend) { '探测中' } else { '云端会话（跳过）' }
        if ($RequireBackend) {
            try {
                if (-not (Get-Command Get-LocalBackends -ErrorAction SilentlyContinue)) {
                    . (Join-Path $PSScriptRoot '_backend.ps1')
                }
                $chat = @(Get-LocalBackends -Role 'chat')
                $serving = @($chat | Where-Object { $_.serving })
                if ($serving.Count -gt 0) {
                    $beOk = $true
                    $beDesc = (($serving | ForEach-Object { $_.kind + ' ' + $_.port }) -join ' / ')
                } elseif ($chat.Count -gt 0) { $beDesc = '加载中' } else { $beDesc = '无本地后端' }
            } catch { $beDesc = '探测失败' }
        }

        $state.ok = ($doneCount -eq @($Ids).Count) -and $lockGone -and $batchOk -and $beOk
        $state.doneCount = $doneCount; $state.lockGone = $lockGone
        $state.batchOk = $batchOk; $state.beOk = $beOk; $state.backendDesc = $beDesc
        $state.elapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)

        if (-not $Quiet -and ($tick % 5 -eq 0 -or $state.ok)) {
            Write-Host ('  ' + $spin[$tick % 4] + (' 完成 {0}/{1} · 锁{2} · 批末{3} · 后端 {4}' -f `
                $doneCount, @($Ids).Count,
                $(if ($lockGone) { '已释放' } else { '占用中' }),
                $(if ($batchOk) { '已记录' } else { '未到' }), $beDesc)) -ForegroundColor DarkGray
        }
        if ($state.ok) { break }
        Start-Sleep -Seconds $PollSeconds
    }

    $sw.Stop()
    $state.elapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    if (-not $state.ok) { $state.timedOut = $true }
    return $state
}
