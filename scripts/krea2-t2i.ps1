# Krea 2 Turbo 文生图（12B DiT，8 步）—— v2 支持多 LoRA 串联 + 自动触发词
#
# 许可：Krea 2 Community License（商用前务必看 https://huggingface.co/krea/Krea-2-Turbo 的 LICENSE）
# 实测（RTX 5090 Laptop 24GB）：1024² 8 步 —— 冷启动 33.6 秒 / 热启动 3.1 秒 / 带 LoRA 首次 12.1 秒
# 显存：约 17~18 GB
#
# 用法：
#   .\Krea2画图.ps1 -Prompt "high fashion editorial portrait, cinematic light"
#   .\Krea2画图.ps1 -Prompt "..." -Lora softwatercolor
#   .\Krea2画图.ps1 -Prompt "..." -Lora "aoi_haru:0.9,softwatercolor:0.7"    # 多 LoRA 串联
#   .\Krea2画图.ps1 -List
#
# 分类：
#   风格 —— softwatercolor / retroanime / neondrip / rainywindow / sunsetblur /
#           darkbrush / dotmatrix / kidsdrawing / vintagetarot / style_reference
#   人物 —— aikasawaguchi / aoiharu / ayakamiyoshi（带触发词，脚本自动补）
#   编辑 —— identity_edit_v2 / general_edit_v2（需参考图 + comfyui-krea2edit 节点，
#           本脚本不处理，走工作流 `Krea2-身份编辑.json`）
#   加速 —— turbo_lora_rank_64（8 步已够，一般不用）
param(
    [Parameter(Mandatory = $false)][string]$Prompt = '',
    [string]$Negative = '',
    [int]$Width = 1024,
    [int]$Height = 1024,
    [int]$Steps = 8,
    [double]$Cfg = 1.0,
    [string]$Sampler = 'euler',
    [string]$Scheduler = 'simple',
    [string]$Lora = '',
    [double]$LoraStrength = 0.8,
    [switch]$NoTrigger,
    [int]$Seed = 0,
    [string]$OutDir = '',
    [switch]$List,
    [switch]$KeepServer,
    [switch]$NoOpen,
    [switch]$NoInfo,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_ui.ps1')
. (Join-Path $PSScriptRoot '_meta.ps1')

$inst     = 'D:\Comfy-Desktop\ComfyUI-Installs\ComfyUI (1)\ComfyUI'
$pyExe    = Join-Path $inst '.venv\Scripts\python.exe'
$outComfy = 'C:\Users\wangzimu\Desktop\ComfyUI 输出'
$loraDir  = 'D:\krea2\models\loras'
if (-not $OutDir) { $OutDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Qwen 图片' }
foreach ($d in @($OutDir, $outComfy)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

function Write-H { param([string]$t) Write-Host ''; Write-Host ("== " + $t + " ==") -ForegroundColor Cyan }
function Write-Ok { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Green }
function Write-In { param([string]$t) Write-Host ("  " + $t) -ForegroundColor DarkGray }
function Write-WarnP { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Yellow }
function Test-EngineHere { try { $null = Invoke-RestMethod 'http://127.0.0.1:8188/system_stats' -TimeoutSec 3; return $true } catch { return $false } }

$loraMeta = @{
    'krea2_softwatercolor'          = @{ cat = '风格'; trigger = ''; w = 0.8; desc = '水彩' }
    'krea2_retroanime'              = @{ cat = '风格'; trigger = ''; w = 0.8; desc = '复古动漫' }
    'krea2_neondrip'                = @{ cat = '风格'; trigger = ''; w = 0.8; desc = '霓虹流体' }
    'krea2_rainywindow'             = @{ cat = '风格'; trigger = ''; w = 0.8; desc = '雨窗' }
    'krea2_sunsetblur'              = @{ cat = '风格'; trigger = ''; w = 0.8; desc = '日落虚化' }
    'krea2_darkbrush'               = @{ cat = '风格'; trigger = ''; w = 0.8; desc = '暗调笔刷' }
    'krea2_dotmatrix'               = @{ cat = '风格'; trigger = ''; w = 0.8; desc = '点阵' }
    'krea2_kidsdrawing'             = @{ cat = '风格'; trigger = ''; w = 0.8; desc = '儿童蜡笔' }
    'krea2_vintagetarot'            = @{ cat = '风格'; trigger = ''; w = 0.8; desc = '复古塔罗' }
    'krea2_style_reference'         = @{ cat = '风格'; trigger = ''; w = 0.8; desc = '风格参考（需参考图）' }
    'krea2_turbo_lora_rank_64_bf16' = @{ cat = '加速'; trigger = ''; w = 1.0; desc = '加速 LoRA' }
    'aikasawaguchi_krea2v6_30_qfloat8' = @{ cat = '人物'; trigger = 'aika_sawaguchi'; w = 0.9; desc = '人物 A' }
    'aoiharu_krea2v2_28_float8'        = @{ cat = '人物'; trigger = 'aoi_haru';       w = 0.9; desc = '人物 B' }
    'ayakamiyoshi_krea2v2_30_qfloat8'  = @{ cat = '人物'; trigger = 'ayaka_miyoshi';  w = 0.9; desc = '人物 C' }
    'krea2_identity_edit_v2_r64'    = @{ cat = '编辑'; trigger = ''; w = 1.0; desc = '身份编辑（需工作流）' }
    'krea2_general_edit_v2_r64'     = @{ cat = '编辑'; trigger = ''; w = 1.0; desc = '通用编辑（需工作流）' }
}

$files = @{}
if (Test-Path $loraDir) {
    Get-ChildItem $loraDir -File -Filter '*.safetensors' | ForEach-Object { $files[$_.BaseName] = $_.Name }
}

function Resolve-LoraName {
    param([string]$name)
    $k = $name.Trim()
    if (-not $k) { return $null }
    $k = $k -replace '\.safetensors$', ''
    if ($files.ContainsKey($k)) { return $k }
    if ($files.ContainsKey('krea2_' + $k)) { return 'krea2_' + $k }
    $hit = $files.Keys | Where-Object { $_ -like ($k + '*') } | Select-Object -First 1
    if ($hit) { return $hit }
    return $null
}

if ($List) {
    Write-H 'Krea 2 LoRA 清单'
    foreach ($cat in '风格', '人物', '编辑', '加速') {
        $items = $files.Keys | Where-Object { $loraMeta.ContainsKey($_) -and $loraMeta[$_].cat -eq $cat } | Sort-Object
        if (-not $items) { continue }
        Write-Host ('  [' + $cat + ']') -ForegroundColor Yellow
        foreach ($k in $items) {
            $m = $loraMeta[$k]
            $trig = if ($m.trigger) { '  触发词: ' + $m.trigger } else { '' }
            '    {0,-38} 建议 {1}  {2}{3}' -f $k, $m.w, $m.desc, $trig
        }
    }
    Write-Host ''
    Write-In '多 LoRA：-Lora "aoi_haru:0.9,softwatercolor:0.7"'
    Write-In '编辑类 LoRA 需要参考图，走工作流 Krea2-身份编辑.json'
    exit 0
}

if (-not $Prompt) {
    Write-Host '  ✗ 需要 -Prompt（或用 -List 查看 LoRA）' -ForegroundColor Red
    if (-not $NoPause) { Start-Sleep -Seconds 6 }
    exit 1
}
if ($Seed -le 0) { $Seed = Get-Random -Minimum 1 -Maximum 2147483646 }

Write-H 'Krea 2 Turbo 文生图'
Write-WarnP 'Krea 2 Community License：商用前请确认条款'
Write-In ("{0}×{1} / {2} 步 / cfg {3} / {4}+{5} / seed {6}" -f $Width, $Height, $Steps, $Cfg, $Sampler, $Scheduler, $Seed)

$loraPlan = @()
$extraTriggers = @()
if ($Lora) {
    foreach ($item in ($Lora -split ',')) {
        if (-not $item.Trim()) { continue }
        $parts = $item.Split(':')
        $rawName = $parts[0].Trim()
        $key = Resolve-LoraName $rawName
        if (-not $key) {
            Write-Host ('  ✗ 找不到 LoRA：' + $rawName) -ForegroundColor Red
            Write-In ('可用：' + (($files.Keys | Sort-Object) -join ', '))
            if (-not $NoPause) { Start-Sleep -Seconds 8 }
            exit 1
        }
        $w = 0.0
        if ($parts.Count -gt 1) { [void][double]::TryParse($parts[1], [ref]$w) }
        if ($w -le 0) {
            if ($loraMeta.ContainsKey($key)) { $w = [double]$loraMeta[$key].w } else { $w = $LoraStrength }
        }
        $loraPlan += @{ key = $key; file = $files[$key]; weight = $w }
        if (-not $NoTrigger -and $loraMeta.ContainsKey($key) -and $loraMeta[$key].trigger) {
            $extraTriggers += $loraMeta[$key].trigger
        }
    }
}

$finalPrompt = $Prompt
if ($extraTriggers.Count -gt 0) {
    $trig = (($extraTriggers | Select-Object -Unique) -join ', ')
    if ($finalPrompt -notmatch [regex]::Escape($extraTriggers[0])) {
        $finalPrompt = $trig + ', ' + $finalPrompt
        Write-In ('自动补触发词：' + $trig)
    }
}
if ($loraPlan.Count -gt 0) {
    Write-In ('LoRA 链：' + (($loraPlan | ForEach-Object { $_.key + '@' + $_.weight }) -join ' → '))
}

$startedHere = $false
if (-not (Test-EngineHere)) {
    Write-In '启动桌面版 ComfyUI（8188）…'
    Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
    $argList = @('main.py', '--port', '8188', '--listen', '127.0.0.1', ('--output-directory="' + $outComfy + '"'))
    Start-Process -FilePath $pyExe -ArgumentList $argList -WorkingDirectory $inst -WindowStyle Hidden
    $startedHere = $true
    $ok = $false
    for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Seconds 2; if (Test-EngineHere) { $ok = $true; break } }
    if (-not $ok) { throw 'ComfyUI 启动超时' }
} else { Write-In '引擎已在运行' }

$graph = @{
    '1' = @{ class_type = 'UNETLoader'; inputs = @{ unet_name = 'krea2_turbo_nvfp4.safetensors'; weight_dtype = 'default' } }
    '2' = @{ class_type = 'CLIPLoader'; inputs = @{ clip_name = 'qwen3vl_4b_fp8_scaled.safetensors'; type = 'krea2'; device = 'default' } }
    '3' = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('2', 0); text = $finalPrompt } }
    '4' = @{ class_type = 'ConditioningZeroOut'; inputs = @{ conditioning = @('3', 0) } }
    '5' = @{ class_type = 'EmptySD3LatentImage'; inputs = @{ width = $Width; height = $Height; batch_size = 1 } }
    '7' = @{ class_type = 'VAELoader'; inputs = @{ vae_name = 'qwen_image_vae.safetensors' } }
    '8' = @{ class_type = 'VAEDecode'; inputs = @{ samples = @('6', 0); vae = @('7', 0) } }
    '9' = @{ class_type = 'SaveImage'; inputs = @{ images = @('8', 0); filename_prefix = 'krea2' } }
}
if ($Negative) {
    $graph['11'] = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('2', 0); text = $Negative } }
    $negRef = @('11', 0)
} else { $negRef = @('4', 0) }

$modelRef = @('1', 0)
$nodeId = 20
foreach ($p in $loraPlan) {
    $id = [string]$nodeId
    $graph[$id] = @{ class_type = 'LoraLoaderModelOnly'; inputs = @{
            model = $modelRef; lora_name = $p.file; strength_model = $p.weight } }
    $modelRef = @($id, 0)
    $nodeId++
}

$graph['6'] = @{ class_type = 'KSampler'; inputs = @{
        model = $modelRef; seed = $Seed; steps = $Steps; cfg = $Cfg
        sampler_name = $Sampler; scheduler = $Scheduler
        positive = @('3', 0); negative = $negRef; latent_image = @('5', 0); denoise = 1.0 } }

Write-In '提交生成…'
$sw = [Diagnostics.Stopwatch]::StartNew()
$body = @{ prompt = $graph } | ConvertTo-Json -Depth 12 -Compress
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
    Write-Host ('  ✗ 生成失败：' + ($err -split "`n")[0]) -ForegroundColor Red
    exit 1
}
Write-Ok ("完成 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds)

$produced = Get-ChildItem $outComfy -Filter 'krea2*.png' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $produced) { $produced = Get-ChildItem (Join-Path $inst 'output') -Filter 'krea2*.png' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
if (-not $produced) { Write-Host '  ✗ 没找到输出' -ForegroundColor Red; exit 1 }

$final = Get-NextImagePath -OutDir $OutDir -Kind 'krea2'
Copy-Item $produced.FullName $final -Force
Write-MediaMeta -Path $final -Extra @{
    Model = 'Krea 2 Turbo (12B DiT, nvfp4)'
    Prompt = $finalPrompt
    Steps = "$Steps"; Cfg = "$Cfg"; Sampler = "$Sampler/$Scheduler"; Seed = "$Seed"
    Size = ("{0}x{1}" -f $Width, $Height)
    Lora = (($loraPlan | ForEach-Object { $_.key + '@' + $_.weight }) -join ', ')
    License = 'Krea 2 Community License - check terms before commercial use'
}
Write-Ok ('成品：' + $final)

if (-not $NoOpen) { Start-Process $final }
if (-not $NoInfo) {
    $infScript = Join-Path $PSScriptRoot '_info.ps1'
    if (Test-Path $infScript) {
        . $infScript
        Show-MediaInfo -Path $final -Extra @{
            '模型' = 'Krea 2 Turbo（12B / nvfp4 / Qwen3-VL 编码器）'
            '档位' = ("{0}×{1} / {2} 步 / cfg {3}" -f $Width, $Height, $Steps, $Cfg)
            'LoRA' = $(if ($loraPlan.Count -gt 0) { (($loraPlan | ForEach-Object { $_.key.Replace('krea2_','') + '@' + $_.weight }) -join ', ') } else { '无' })
        }
    }
}
if (-not $KeepServer -and $startedHere) {
    Get-Process python -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*Comfy-Desktop*' } |
        ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
}
if (-not $NoPause) { Write-Host ''; Write-Host '窗口将在 8 秒后自动关闭…' -ForegroundColor DarkGray; Start-Sleep -Seconds 8 }
exit 0
