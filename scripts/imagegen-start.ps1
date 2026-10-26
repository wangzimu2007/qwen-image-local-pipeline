# 启动本地生图服务（Qwen-Image-2.1-Turbo / stable-diffusion.cpp sd-server）
#
# 行为：
#   1. 记录启动前正在运行的本地聊天模型（Strata IQ3_S / Strata NVFP4 / Ollama / 无）
#   2. 停掉它，释放显存
#   3. 拉起 sd-server 并等到就绪
#   退出时用 stop-imggen.ps1 会自动恢复第 1 步记录的那个模型。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File D:\qwen-image-2.1\start-imggen.ps1
#   ... -Port 1235          换端口
#   ... -KeepChatBackend    不停本地聊天模型（显存够用时）
#   ... -NoPause            结束时不等待（自动化调用用）
#   ... -OpenBrowser        就绪后自动打开内置网页界面（图形化操作入口）
param(
    [int]$Port = 1234,
    [switch]$KeepChatBackend,
    [switch]$NoPause,
    [switch]$OpenBrowser
)

$ErrorActionPreference = 'Stop'
$root      = 'D:\qwen-image-2.1'
$exe       = Join-Path $root 'bin\sdcpp\sd-server.exe'
$actions   = Join-Path $env:LOCALAPPDATA 'Strata\actions'
$stateFile = Join-Path $root '.chat-backend-state.json'
$webUrl    = "http://127.0.0.1:$Port/"

function Open-WebUI {
    if (-not $OpenBrowser) { return }
    try {
        Start-Process $webUrl
        Write-Host ("已打开网页界面：{0}" -f $webUrl) -ForegroundColor Green
    } catch {
        Write-Warning "打开浏览器失败，请手动访问 $webUrl"
    }
}

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

# 从 8080 上的模型 id 推断 Strata 变体（进程命令行读不到，只能靠模型名判断）
function Get-StrataVariant {
    param([string]$ModelId)
    if ($ModelId -match 'nvfp4') { return 'nvfp4' }
    if ($ModelId -match 'iq3')   { return 'iq3_s' }
    return ''
}

# 探测当前有哪些本地聊天模型在跑
function Get-ChatBackends {
    $list = New-Object System.Collections.ArrayList

    # 只按 API 是否真的在响应判断；有进程但服务没起不算在跑
    $r = $null
    try { $r = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/models' -TimeoutSec 3 } catch { }
    if ($r -and $r.data) {
        $strataModel = ($r.data | Select-Object -First 1).id
        [void]$list.Add([pscustomobject]@{
            kind    = 'strata'
            variant = (Get-StrataVariant $strataModel)
            modelId = $strataModel
        })
    } elseif (Get-Process -Name 'strata' -ErrorAction SilentlyContinue) {
        Write-Host '提示：有 strata 进程，但 8080 没有响应，视为未在提供服务，不处理它。' -ForegroundColor DarkGray
    }

    try {
        $ps = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/ps' -TimeoutSec 3
        $names = @($ps.models | ForEach-Object { $_.name })
        if ($names.Count -gt 0) {
            [void]$list.Add([pscustomobject]@{ kind = 'ollama'; models = $names })
        }
    } catch { }

    return ,$list
}

# ---------- 开始 ----------
if (-not (Test-Path $exe)) { throw "找不到 sd-server.exe：$exe" }

if (Test-HttpUp "http://127.0.0.1:$Port/v1/models") {
    Write-Host "生图服务已在 http://127.0.0.1:$Port 运行，无需重复启动。" -ForegroundColor Green
    Open-WebUI
    Pause-Brief 5
    exit 0
}

# 清掉上一次异常退出/带 -NoRestore 关闭时残留的状态文件，
# 否则本次即使没停任何模型，关闭时也会照着旧记录去"恢复"，误启 Strata。
if (Test-Path $stateFile) {
    Write-Host '发现上次运行残留的状态记录，已清理（本次不会误恢复）。' -ForegroundColor DarkGray
    Remove-Item $stateFile -ErrorAction SilentlyContinue
}

if (-not $KeepChatBackend) {
    $backends = Get-ChatBackends
    $state = [pscustomobject]@{
        capturedAt    = (Get-Date).ToString('o')
        requestedPort = $Port
        backends      = @($backends)
    }
    $state | ConvertTo-Json -Depth 6 | Set-Content -Path $stateFile -Encoding UTF8

    if (@($backends).Count -eq 0) {
        Write-Host '记录：启动前没有正在运行的本地聊天模型。'
    }
    foreach ($b in @($backends)) {
        if ($b.kind -eq 'strata') {
            Write-Host ("记录：Strata {0}（{1}）正在运行。" -f $b.variant, $b.modelId)
            Write-Host '停止 Strata 以释放显存...' -ForegroundColor Yellow
            $stopCmd = if ($b.variant -eq 'nvfp4') { 'stop-nvfp4.cmd' } else { 'stop-iq3s.cmd' }
            $stopPath = Join-Path $actions $stopCmd
            if (-not (Test-Path $stopPath)) { $stopPath = Join-Path $actions 'stop-iq3s.cmd' }
            if (Test-Path $stopPath) { & cmd /c "`"$stopPath`"" | Out-Null }
        }
        elseif ($b.kind -eq 'ollama') {
            $names = @($b.models) -join ', '
            Write-Host "记录：Ollama 正在运行（已加载: $names）"
            Write-Host '让 Ollama 卸载模型以释放显存...' -ForegroundColor Yellow
            foreach ($m in @($b.models)) {
                try {
                    $body = @{ model = $m; keep_alive = 0 } | ConvertTo-Json -Compress
                    Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method POST -ContentType 'application/json' -Body $body -TimeoutSec 30 | Out-Null
                } catch {
                    Write-Warning "  卸载 $m 失败：$($_.Exception.Message)"
                }
            }
        }
    }
    Start-Sleep -Seconds 3
}

$free = (& nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits) -replace '\s', ''
if ($free -and [int]$free -lt 17500) {
    Write-Warning "当前空闲显存 ${free} MiB，生图约需 17000 MiB，可能会失败。"
}

$sigmas = '1.0,0.978453,0.95418,0.926626,0.89508,0.845148,0.704534,0.414568,0.0'
$sdArgs = @(
    '--diffusion-model', (Join-Path $root 'models\diffusion_models\Qwen-Image-2.1-Turbo-AD-Q6_K.gguf'),
    '--llm',             (Join-Path $root 'models\text_encoders\Qwen-Image-2.1-Turbo-Uncensored-Q8_0.gguf'),
    '--vae',             (Join-Path $root 'models\vae\qwen_image_2.1_vae_bf16.safetensors'),
    '--steps', '8',
    '--cfg-scale', '1.0',
    '--sampling-method', 'euler',
    '--sigmas', $sigmas,
    '--diffusion-fa',
    '--listen-ip', '127.0.0.1',
    '--listen-port', "$Port"
)

Write-Host "启动 sd-server（端口 $Port）..." -ForegroundColor Cyan
$proc = Start-Process -FilePath $exe -ArgumentList $sdArgs -WorkingDirectory (Join-Path $root 'bin\sdcpp') -PassThru
Write-Host "PID $($proc.Id)，等待模型加载（约 10-20 秒）..."

for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 2
    if ($proc.HasExited) { throw "sd-server 启动失败，退出码 $($proc.ExitCode)" }
    if (Test-HttpUp "http://127.0.0.1:$Port/v1/models") {
        $ids = ''
        try {
            $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/models" -TimeoutSec 3
            $ids = ($r.data | ForEach-Object { $_.id }) -join ', '
        } catch { }
        Write-Host ''
        Write-Host "就绪：http://127.0.0.1:$Port   模型：$ids" -ForegroundColor Green
        if ($OpenBrowser) {
            Open-WebUI
            Write-Host '在网页界面里可以直接调参数出图（英文界面）。'
        } else {
            Write-Host '在 DSH 对话里直接让我出图即可（首张会慢几秒，模型要预热）。'
        }
        Write-Host '用完执行 stop-imggen.ps1，会自动恢复启动前的本地模型。'
        Pause-Brief 8
        exit 0
    }
}
throw '等待超时：模型可能还在加载，请稍后重试或检查 sd-server 进程。'
