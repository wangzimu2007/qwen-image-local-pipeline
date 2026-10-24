# 显存体检：谁占着显存、目标模型够不够、要不要释放
# 用法：
#   .\vram-check.ps1                     # 默认按 Z-Image 档判断
#   .\vram-check.ps1 -Model h3           # 或 moss / wan / seedvr2 / flashvsr
#   .\vram-check.ps1 -Kill               # 强制停 llama-server 后复查
#   .\vram-check.ps1 -KeepOpen           # 跑完等回车（双击快捷方式用）
param(
    [ValidateSet('zimage', 'moss', 'h3', 'wan', 'seedvr2', 'flashvsr')]
    [string]$Model = 'zimage',
    [switch]$Kill,
    [switch]$KeepOpen
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\lib\common.ps1"

# 各模型"能跑得快"所需的最低可用显存（低于这个值驱动会回退系统内存 → 慢 5~10 倍但不报错）
$need = @{
    zimage   = 14000
    moss     = 15000
    h3       = 21000
    wan      = 16000
    seedvr2  = 15000
    flashvsr = 22000
}
$label = @{
    zimage   = 'Z-Image Turbo（含 LoRA）'
    moss     = 'MOSS-Image'
    h3       = 'MiniMax H3（带音频）'
    wan      = 'Wan 2.2 5B'
    seedvr2  = 'SeedVR2 超分'
    flashvsr = 'FlashVSR+ 超分'
}

function Get-VramLine {
    $raw = (& nvidia-smi --query-gpu=memory.total,memory.used,memory.free,utilization.gpu --format=csv,noheader,nounits 2>$null) -join ''
    $p = ($raw -split ',') | ForEach-Object { $_.Trim() }
    if (@($p).Count -ge 4) { return @{ Total = [int]$p[0]; Used = [int]$p[1]; Free = [int]$p[2]; Util = [int]$p[3] } }
    return @{ Total = 0; Used = 0; Free = 0; Util = 0 }
}

function Get-VramHolders {
    param([int]$Top = 8)
    try { $samples = (Get-Counter '\GPU Process Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples } catch { return @() }
    # 排除 Windows 自身：dwm/csrss 在 WDDM 下会虚报十几到二十 GB
    $skip = @('dwm', 'csrss', 'winlogon', 'LogonUI', 'Registry', 'Memory Compression')
    $acc = @{}
    foreach ($s in $samples) {
        if ($s.InstanceName -notmatch '^pid_(\d+)') { continue }
        if ($s.CookedValue -le 0) { continue }
        $procId = [int]$Matches[1]
        if (-not $acc.ContainsKey($procId)) { $acc[$procId] = 0.0 }
        $acc[$procId] += $s.CookedValue
    }
    $rows = foreach ($k in $acc.Keys) {
        $proc = Get-Process -Id $k -ErrorAction SilentlyContinue
        $nm = if ($proc) { $proc.ProcessName } else { '?' }
        if ($skip -contains $nm) { continue }
        if ($acc[$k] / 1GB -gt 6.0) { continue }
        [pscustomobject]@{ PID = $k; Name = $nm; GB = [math]::Round($acc[$k] / 1GB, 2) }
    }
    return ($rows | Sort-Object GB -Descending | Select-Object -First $Top)
}

$C = Get-PipelineConfig

Write-Head '显存体检'
$v = Get-VramLine
if ($v.Total -eq 0) { Fail '读不到 nvidia-smi（驱动或 PATH 问题）' }
Write-Info ("总显存 {0:N1} GB / 已用 {1:N1} GB / 可用 {2:N1} GB / GPU 占用 {3}%" -f ($v.Total / 1024), ($v.Used / 1024), ($v.Free / 1024), $v.Util)

Write-Head '占用显存的进程'
$holders = Get-VramHolders -Top 8
if (@($holders).Count -eq 0) { Write-Info '（读不到按进程统计）' }
else { $holders | ForEach-Object { Write-Info ('{0,-26} PID {1,-7} {2,6:N2} GB' -f $_.Name, $_.PID, $_.GB) } }

Write-Head '目标模型需求'
$req = $need[$Model]
Write-Info ("目标：{0}，需要可用 ≥ {1:N1} GB，当前 {2:N1} GB" -f $label[$Model], ($req / 1024), ($v.Free / 1024))
if ($v.Free -ge $req) {
    Write-Ok '显存足够，可以正常速度生成'
} elseif ($v.Free -gt 8000) {
    Write-Warn2 ("显存不足（差 {0:N1} GB）—— 不会报错，但会慢 5~10 倍" -f (($req - $v.Free) / 1024))
    Write-Warn2 '建议：关掉占显存的程序，或先跑 session-start.ps1 / .\vram-check.ps1 -Kill'
} else {
    Write-Warn2 ("显存只剩 {0:N1} GB，硬跑大概率失败" -f ($v.Free / 1024))
}

Write-Head 'Ollama 状态'
$ollamaUrl = if ($C.OllamaUrl) { $C.OllamaUrl } else { 'http://127.0.0.1:11434' }
try {
    $ps = Invoke-RestMethod ($ollamaUrl + '/api/ps') -TimeoutSec 5
    if ($ps.models) { $ps.models | ForEach-Object { Write-Info ('{0,-40} {1,6:N1} GB' -f $_.name, ($_.size / 1GB)) } }
    else { Write-Info '无模型加载' }
} catch { Write-Info 'Ollama 未响应' }

if ($Kill) {
    Write-Head '强制释放（-Kill）'
    $ls = Get-Process llama-server -ErrorAction SilentlyContinue
    if ($ls) {
        $ls | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue; Write-Info ('已停 llama-server PID ' + $_.Id) }
        Start-Sleep -Seconds 5
        $v2 = Get-VramLine
        Write-Ok ("现在可用显存 {0:N1} GB" -f ($v2.Free / 1024))
    } else { Write-Info '没有 llama-server 进程' }
}

if ($KeepOpen) { Write-Host ''; Write-Host '  按回车关闭窗口…' -ForegroundColor DarkGray; $null = Read-Host }
exit 0
