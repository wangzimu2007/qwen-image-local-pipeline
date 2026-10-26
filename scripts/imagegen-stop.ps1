# 停止本地生图服务，并自动恢复启动前记录的那个本地聊天模型。
#
# 恢复依据是 start-imggen.ps1 写下的 .chat-backend-state.json：
#   - 启动前是 Strata IQ3_S  → 恢复 IQ3_S
#   - 启动前是 Strata NVFP4  → 恢复 NVFP4
#   - 启动前是 Ollama        → 重新加载当时已加载的模型
#   - 启动前什么都没开        → 什么都不做
# 不再询问，恢复完自动收尾。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File D:\qwen-image-2.1\stop-imggen.ps1
#   ... -NoRestore   只停生图服务，不恢复本地模型
#   ... -NoPause     结束时不等待（自动化调用用）
param(
    [switch]$NoRestore,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$root      = 'D:\qwen-image-2.1'
$actions   = Join-Path $env:LOCALAPPDATA 'Strata\actions'
$stateFile = Join-Path $root '.chat-backend-state.json'
$ollamaApp = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'

function Pause-Brief {
    param([int]$Seconds = 8)
    if ($NoPause) { return }
    Write-Host ''
    Write-Host "窗口将在 $Seconds 秒后自动关闭..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $Seconds
}

function Test-HttpUp {
    param([string]$Url)
    try { $null = Invoke-RestMethod -Uri $Url -TimeoutSec 3; return $true } catch { return $false }
}

function Wait-UntilUp {
    param([string]$Url, [int]$Seconds = 180)
    for ($i = 0; $i -lt [int]($Seconds / 2); $i++) {
        Start-Sleep -Seconds 2
        if (Test-HttpUp $Url) { return $true }
    }
    return $false
}

# ---------- 1. 停生图服务 ----------
$procs = Get-Process -Name 'sd-server' -ErrorAction SilentlyContinue
if ($procs) {
    foreach ($p in $procs) {
        Write-Host "停止 sd-server（PID $($p.Id)）..."
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
    Write-Host '生图服务已停止，显存已释放。' -ForegroundColor Green
} else {
    Write-Host 'sd-server 当前没有在运行。'
}

if ($NoRestore) {
    Write-Host '按 -NoRestore 要求，跳过恢复本地模型。'
    # 状态文件必须一起删掉，否则下次关闭时会拿旧记录误"恢复"模型
    if (Test-Path $stateFile) {
        Remove-Item $stateFile -ErrorAction SilentlyContinue
        Write-Host '已清理状态记录（下次不会误恢复）。' -ForegroundColor DarkGray
    }
    Pause-Brief 6
    exit 0
}

# ---------- 2. 读启动前的状态 ----------
if (-not (Test-Path $stateFile)) {
    Write-Host '没有找到启动前状态记录（.chat-backend-state.json），无法判断该恢复什么。'
    Write-Host '如需本地模型，请用桌面「Strata IQ3_S - 启动」「Strata NVFP4 - 启动」或启动 Ollama。'
    Pause-Brief 8
    exit 0
}

try {
    $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Warning "状态文件损坏，跳过恢复：$($_.Exception.Message)"
    Pause-Brief 8
    exit 0
}

$backends = @($state.backends) | Where-Object { $_ -ne $null }

if (@($backends).Count -eq 0) {
    Write-Host '启动生图服务前没有任何本地聊天模型在运行，无需恢复。'
    Remove-Item $stateFile -ErrorAction SilentlyContinue
    Pause-Brief 6
    exit 0
}

# ---------- 3. 逐个恢复 ----------
$restoredAnything = $false
foreach ($b in $backends) {
    if ($b.kind -eq 'strata') {
        $variant = "$($b.variant)"
        if (-not $variant) {
            Write-Warning "无法判断当时是哪个 Strata 变体（模型 id: $($b.modelId)），默认恢复 IQ3_S。"
            $variant = 'iq3_s'
        }
        $startCmd = if ($variant -eq 'nvfp4') { 'start-nvfp4.cmd' } else { 'start-iq3s.cmd' }
        $startPath = Join-Path $actions $startCmd
        if (-not (Test-Path $startPath)) {
            Write-Warning "找不到 $startCmd，跳过 Strata 恢复。"
            continue
        }
        $label = if ($variant -eq 'nvfp4') { 'Strata NVFP4' } else { 'Strata IQ3_S' }
        Write-Host ("恢复 {0}（约 1 分钟，期间电脑可能卡顿）..." -f $label) -ForegroundColor Yellow
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "`"$startPath`"" -WindowStyle Minimized
        if (Wait-UntilUp 'http://127.0.0.1:8080/v1/models' 420) {
            $rid = ''
            try {
                $r = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/models' -TimeoutSec 5
                $rid = ($r.data | ForEach-Object { $_.id }) -join ', '
            } catch { }
            Write-Host ("{0} 已就绪：http://127.0.0.1:8080/v1   模型：{1}" -f $label, $rid) -ForegroundColor Green
            $restoredAnything = $true
        } else {
            Write-Warning '等待 Strata 超时（200 秒），请检查最小化的 cmd 窗口里的报错。'
        }
    }
    elseif ($b.kind -eq 'ollama') {
        if (-not (Get-Process -Name 'ollama app' -ErrorAction SilentlyContinue)) {
            if (Test-Path $ollamaApp) {
                Write-Host '启动 Ollama...'
                Start-Process -FilePath $ollamaApp | Out-Null
                $null = Wait-UntilUp 'http://127.0.0.1:11434/api/tags' 60
            } else {
                Write-Warning "找不到 Ollama：$ollamaApp"
                continue
            }
        }
        $models = @($b.models) | Where-Object { $_ }
        if (@($models).Count -eq 0) {
            Write-Host 'Ollama 已就绪（当时没有已加载的模型，无需预热）。' -ForegroundColor Green
            $restoredAnything = $true
        } else {
            foreach ($m in $models) {
                Write-Host "重新加载 Ollama 模型 $m（可能要几十秒）..." -ForegroundColor Yellow
                try {
                    $body = @{ model = $m; prompt = ''; keep_alive = '30m' } | ConvertTo-Json -Compress
                    Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method POST -ContentType 'application/json' -Body $body -TimeoutSec 600 | Out-Null
                    Write-Host "  $m 已加载。" -ForegroundColor Green
                    $restoredAnything = $true
                } catch {
                    Write-Warning "  加载 $m 失败：$($_.Exception.Message)（下次对话时它会自动加载）"
                }
            }
        }
    }
}

Remove-Item $stateFile -ErrorAction SilentlyContinue
if ($restoredAnything) {
    Write-Host ''
    Write-Host '已恢复启动前的本地模型。' -ForegroundColor Green
}
Pause-Brief 8
exit 0
