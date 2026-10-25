# PixelDiT 文生图（NVIDIA PixelDiT 1300M，像素空间扩散，ComfyUI 桌面版）
#
# ⚠ 许可：模型为 NVIDIA NSCLv1（NSCL v1），**仅限非商业**（研究/评估）用途，
#        且非商业限制会传导到生成的图片。商用请换 Z-Image / MOSS / Qwen 系列。
#
# 特点：像素空间扩散（不经过 VAE latent），1024² 约 9 秒，显存 ~10 GB
# 用法：
#   .\PixelDiT画图.ps1 -Prompt "a woman in white dress walking through stone arches"
#   .\PixelDiT画图.ps1 -Prompt "..." -Width 1024 -Height 1024 -Steps 30
param(
    [Parameter(Mandatory = $true)][string]$Prompt,
    [string]$Negative = 'low quality, worst quality, over-saturated, blurry, deformed, watermark',
    [int]$Width = 1024,
    [int]$Height = 1024,
    [int]$Steps = 30,
    [double]$Cfg = 4.0,
    [int]$Seed = 0,
    [string]$OutDir = '',
    [switch]$KeepServer,
    [switch]$KeepChatBackend,
    [switch]$NoOpen,
    [switch]$NoInfo,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_vram.ps1')
. (Join-Path $PSScriptRoot '_ui.ps1')

$inst    = 'D:\Comfy-Desktop\ComfyUI-Installs\ComfyUI (1)\ComfyUI'
$pyExe   = Join-Path $inst '.venv\Scripts\python.exe'
$outComfy = 'C:\Users\wangzimu\Desktop\ComfyUI 输出'
if (-not $OutDir) { $OutDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Qwen 图片' }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
if (-not (Test-Path $outComfy)) { New-Item -ItemType Directory -Path $outComfy -Force | Out-Null }
if ($Seed -le 0) { $Seed = Get-Random -Minimum 1 -Maximum 2147483646 }

function Write-H { param([string]$t) Write-Host ''; Write-Host ("== " + $t + " ==") -ForegroundColor Cyan }
function Write-Ok { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Green }
function Write-In { param([string]$t) Write-Host ("  " + $t) -ForegroundColor DarkGray }
function Write-WarnP { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Yellow }
function Test-EngineHere {
    try { $null = Invoke-RestMethod 'http://127.0.0.1:8188/system_stats' -TimeoutSec 3; return $true } catch { return $false }
}
function Get-UnetList {
    try {
        $r = Invoke-RestMethod 'http://127.0.0.1:8188/object_info/UNETLoader' -TimeoutSec 10
        return @($r.UNETLoader.input.required.unet_name[0])
    } catch { return @() }
}

Write-H 'PixelDiT 文生图（像素空间 / 非商业许可）'
Write-In ("{0}×{1} / {2} 步 / cfg {3} / seed {4}" -f $Width, $Height, $Steps, $Cfg, $Seed)
Write-WarnP 'NSCLv1 许可：仅限非商业（研究/评估），输出同样受限'

# ---- 显存快照（PixelDiT 全栈约 10 GB）----
$vramState = $null
trap {
    Write-Host ''
    Write-Host ('  X 出错: ' + $_.Exception.Message) -ForegroundColor Red
    try { Restore-VramPrep $vramState } catch { }
    exit 1
}
if (-not $KeepChatBackend) {
    $free = Get-FreeVramMiB
    if ($free -lt 11000) {
        Write-WarnP ("显存不足：{0} MB 可用（需要约 11000 MB），自动快照并卸载本地模型…" -f $free)
        $vramState = Start-VramPrep -NeedMiB 11000 -TimeoutSeconds 150
    } else {
        Write-In ("显存充足（{0:N1} GB 可用），跳过快照" -f ($free / 1024))
    }
}

# ---- 引擎：必须是桌面版（有 pixeldit 模型）----
$startedHere = $false
if (Test-EngineHere) {
    $unets = Get-UnetList
    if (@($unets | Where-Object { $_ -match 'pixeldit' }).Count -eq 0) {
        Write-WarnP '8188 上的引擎没有 pixeldit 模型（可能是自建版），先停掉再启桌面版…'
        Get-Process python -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -like '*Comfy-Desktop*' } |
            ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
        for ($i = 0; $i -lt 25; $i++) { Start-Sleep -Seconds 1; if (-not (Test-EngineHere)) { break } }
        $startedHere = $true
    } else { Write-In '桌面版引擎已在运行' }
}
if (-not (Test-EngineHere)) {
    Write-In '启动桌面版 ComfyUI（8188，输出到桌面「ComfyUI 输出」）…'
    Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
    $argList = @('main.py', '--port', '8188', '--listen', '127.0.0.1', ('--output-directory="' + $outComfy + '"'))
    Start-Process -FilePath $pyExe -ArgumentList $argList -WorkingDirectory $inst -WindowStyle Hidden
    $startedHere = $true
    $ok = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Seconds 2
        if (Test-EngineHere) { $ok = $true; Write-Ok ("引擎就绪（" + ($i * 2 + 2) + " 秒）"); break }
    }
    if (-not $ok) { throw 'ComfyUI 启动超时' }
}

# ---- 组图 ----
$graph = @{
    '1' = @{ class_type = 'UNETLoader'; inputs = @{ unet_name = 'pixeldit_1300m_1024px_bf16.safetensors'; weight_dtype = 'default' } }
    '2' = @{ class_type = 'CLIPLoader'; inputs = @{ clip_name = 'gemma_2_2b_it_elm_bf16.safetensors'; type = 'pixeldit'; device = 'default' } }
    '3' = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('2', 0); text = $Prompt } }
    '4' = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('2', 0); text = $Negative } }
    '5' = @{ class_type = 'EmptyChromaRadianceLatentImage'; inputs = @{ width = $Width; height = $Height; batch_size = 1 } }
    '6' = @{ class_type = 'KSampler'; inputs = @{
            model = @('1', 0); seed = $Seed; steps = $Steps; cfg = $Cfg
            sampler_name = 'er_sde'; scheduler = 'simple'
            positive = @('3', 0); negative = @('4', 0); latent_image = @('5', 0); denoise = 1.0 } }
    '7' = @{ class_type = 'VAELoader'; inputs = @{ vae_name = 'pixel_space' } }
    '8' = @{ class_type = 'VAEDecode'; inputs = @{ samples = @('6', 0); vae = @('7', 0) } }
    '9' = @{ class_type = 'SaveImage'; inputs = @{ images = @('8', 0); filename_prefix = 'pixeldit' } }
}

Write-In '提交生成…'
$body = @{ prompt = $graph } | ConvertTo-Json -Depth 12 -Compress
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    $resp = Invoke-RestMethod 'http://127.0.0.1:8188/prompt' -Method POST -ContentType 'application/json' `
        -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60
} catch {
    $msg = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    throw ('提交失败：' + ($msg -split "`n")[0])
}
$id = $resp.prompt_id
$done = $false; $err = ''
while (-not $done) {
    Start-Sleep -Seconds 2
    try { $h = Invoke-RestMethod ('http://127.0.0.1:8188/history/' + $id) -TimeoutSec 10 } catch { continue }
    if (-not $h.$id) { continue }
    if ($h.$id.status.status_str -eq 'error') {
        $err = ($h.$id.status.messages | Where-Object { $_[0] -eq 'execution_error' } | ForEach-Object { $_[1].exception_message }) -join ' | '
        $done = $true
    } elseif ($h.$id.outputs) { $done = $true }
    if ($sw.Elapsed.TotalSeconds -gt 900) { $err = 'timeout'; $done = $true }
}
$sw.Stop()
if ($err) {
    if (-not $KeepServer -and $startedHere) { Get-Process python -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*Comfy-Desktop*' } | Stop-Process -Force -ErrorAction SilentlyContinue }
    Restore-VramPrep $vramState
    Write-Host ('  ✗ 生成失败：' + ($err -split "`n")[0]) -ForegroundColor Red
    exit 1
}
Write-Ok ("生成完成，用时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds)

# ---- 取图并归位 ----
$produced = Get-ChildItem $outComfy -Filter 'pixeldit*.png' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $produced) {
    $produced = Get-ChildItem (Join-Path $inst 'output') -Filter 'pixeldit*.png' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if (-not $produced) {
    Restore-VramPrep $vramState
    Write-Host '  ✗ 没找到输出图片' -ForegroundColor Red
    exit 1
}
$final = Get-NextImagePath -OutDir $OutDir -Kind 'pixeldit'
Copy-Item $produced.FullName $final -Force

# 写入许可/溯源元数据（PNG text 块）——比写进提示词可靠
if (-not $NoMeta) {
    $metaPy = Join-Path $PSScriptRoot '_pngmeta.py'
    $metaJson = @{
        Model   = 'PixelDiT 1.3B (pixeldit_1300m_1024px_bf16)'
        License = 'NVIDIA NSCLv1 - NON-COMMERCIAL use only (research/evaluation); outputs inherit restriction'
        License_ZH = '非商业用途（研究/评估）；输出同样受限。商用请改用 Z-Image/MOSS/Qwen'
        Prompt  = $Prompt
        Negative = $Negative
        Steps   = $Steps
        Cfg     = $Cfg
        Seed    = $Seed
        Size    = ("{0}x{1}" -f $Width, $Height)
        Sampler = 'er_sde/simple'
        GeneratedBy = 'PixelDiT画图.ps1'
        GeneratedAt = (Get-Date).ToString('s')
    } | ConvertTo-Json -Compress
    $pyForMeta = 'D:\deepseek harness\resources\runtime\primary-runtime\dependencies\python\python.exe'
    if (-not (Test-Path $pyForMeta)) { $pyForMeta = 'python' }
    $metaFile = Join-Path $env:TEMP ('pid-meta-' + [Guid]::NewGuid().ToString('N').Substring(0,8) + '.json')
    [System.IO.File]::WriteAllText($metaFile, $metaJson, (New-Object System.Text.UTF8Encoding($false)))
    $env:PYTHONIOENCODING = 'utf-8'
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $pyForMeta $metaPy --in $final --jsonfile $metaFile 2>&1 | Out-Null
    $ErrorActionPreference = $prevEap
    Remove-Item $metaFile -Force -ErrorAction SilentlyContinue
    Write-In '已写入许可元数据（PNG text）'
}
Write-Ok ('成品：' + $final)

if (-not $NoOpen) { Start-Process $final }
if (-not $NoInfo) {
    $infScript = Join-Path $PSScriptRoot '_info.ps1'
    if (Test-Path $infScript) {
        . $infScript
        Show-MediaInfo -Path $final -Extra @{
            '模型' = 'PixelDiT 1.3B（像素空间 + Gemma2-2B 编码器）'
            '档位' = ("{0}×{1} / {2} 步 / cfg {3} / er_sde" -f $Width, $Height, $Steps, $Cfg)
            '许可' = 'NSCLv1 仅限非商业'
        }
    }
}

if (-not $KeepServer -and $startedHere) {
    Write-In '关闭本次启动的引擎…'
    Get-Process python -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*Comfy-Desktop*' } |
        ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
}
Restore-VramPrep $vramState
if (-not $NoPause) { Write-Host ''; Write-Host '窗口将在 8 秒后自动关闭…' -ForegroundColor DarkGray; Start-Sleep -Seconds 8 }
exit 0
