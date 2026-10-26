# 显存体检：看清谁占了显存、够不够跑目标模型
# 用法：
#   .\显存体检.ps1                 # 默认按 Z-Image 需求判断
#   .\显存体检.ps1 -Model moss     # 按 MOSS 判断
#   .\显存体检.ps1 -Model h3       # 按 H3 判断
#   .\显存体检.ps1 -Kill          # 杀掉占显存最多的 llama-server（Ollama 模型）
param(
    [ValidateSet('zimage', 'moss', 'h3', 'wan', 'seedvr2', 'flashvsr')]
    [string]$Model = 'zimage',
    [switch]$Kill,
    [switch]$KeepOpen   # 跑完停住等回车（双击快捷方式时用）
)

$ErrorActionPreference = 'Continue'

# 各模型"能跑得快"所需的最低可用显存（低于这个值会回退到系统内存 → 慢 5~10 倍，但不报错）
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

function Write-H { param([string]$t) Write-Host ''; Write-Host ("== " + $t + " ==") -ForegroundColor Cyan }
function Get-VramLine {
    $raw = (& nvidia-smi --query-gpu=memory.total,memory.used,memory.free,utilization.gpu --format=csv,noheader,nounits) -join ''
    $p = ($raw -split ',') | ForEach-Object { $_.Trim() }
    if($p.Count -ge 4){ return @{ Total=[int]$p[0]; Used=[int]$p[1]; Free=[int]$p[2]; Util=[int]$p[3] } }
    return @{ Total=0; Used=0; Free=0; Util=0 }
}

function Get-VramHolders {
    param([int]$Top = 8)
    try{
        $samples = (Get-Counter '\GPU Process Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples
    } catch { return @() }
    $acc = @{}
    foreach($s in $samples){
        if($s.InstanceName -notmatch '^pid_(\d+)'){ continue }
        $p = [int]$Matches[1]
        if($s.CookedValue -le 0){ continue }
        if(-not $acc.ContainsKey($p)){ $acc[$p] = 0.0 }
        $acc[$p] += $s.CookedValue
    }
    # 排除 Windows 自身进程：dwm/csrss 等的"专用显存"计数器在 WDDM 下会虚报十几 GB
    $skip = @('dwm', 'csrss', 'winlogon', 'LogonUI', 'Registry', 'Memory Compression')
    $rows = foreach($k in $acc.Keys){
        $proc = Get-Process -Id $k -ErrorAction SilentlyContinue
        $nm = if($proc){ $proc.ProcessName } else { '?' }
        if($skip -contains $nm){ continue }
        if($acc[$k]/1GB -gt 6.0){ continue }   # 单个非计算进程不可能占 6 GB 以上
        [pscustomobject]@{
            PID  = $k
            Name = $nm
            GB   = [math]::Round($acc[$k]/1GB, 2)
        }
    }
    return ($rows | Sort-Object GB -Descending | Select-Object -First $Top)
}

Write-H '显存体检'
$v = Get-VramLine
Write-Host ("  总显存 {0:N1} GB / 已用 {1:N1} GB / 可用 {2:N1} GB / GPU 占用 {3}%" -f ($v.Total/1024), ($v.Used/1024), ($v.Free/1024), $v.Util)

Write-H '占用显存的进程'
$holders = Get-VramHolders -Top 8
if(@($holders).Count -eq 0){ Write-Host '  （读不到按进程统计）' }
else {
    $holders | ForEach-Object { '  {0,-28} PID {1,-7} {2,6:N2} GB' -f $_.Name, $_.PID, $_.GB }
}

Write-H '目标模型需求'
$req = $need[$Model]
$free = $v.Free
Write-Host ("  目标：{0}" -f $label[$Model])
Write-Host ("  需要可用显存 ≥ {0:N1} GB，当前 {1:N1} GB" -f ($req/1024), ($free/1024))
if($free -ge $req){
    Write-Host '  ✓ 显存足够，可以正常速度生成' -ForegroundColor Green
} else {
    Write-Host ("  ✗ 显存不足（差 {0:N1} GB）" -f (($req-$free)/1024)) -ForegroundColor Red
    Write-Host '    后果：驱动会把权重放到系统内存 —— 不报错，但慢 5~10 倍' -ForegroundColor Yellow
    Write-Host '    建议：关掉占显存的进程（通常是本地聊天模型的 llama-server），或先跑 会话开始/结束' -ForegroundColor Yellow
}

Write-H 'Ollama 状态'
try{
    $ps = Invoke-RestMethod 'http://127.0.0.1:11434/api/ps' -TimeoutSec 5
    if($ps.models){
        $ps.models | ForEach-Object { '  {0,-40} {1,6:N1} GB' -f $_.name, ($_.size/1GB) }
    } else { Write-Host '  无模型加载' }
} catch { Write-Host '  Ollama 未响应' }

if($Kill){
    Write-H '强制释放（-Kill）'
    $ls = Get-Process llama-server -ErrorAction SilentlyContinue
    if($ls){
        $ls | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue; Write-Host ('  已停 llama-server PID ' + $_.Id) }
        Start-Sleep -Seconds 5
        $v2 = Get-VramLine
        Write-Host ("  现在可用显存 {0:N1} GB" -f ($v2.Free/1024)) -ForegroundColor Green
    } else {
        Write-Host '  没有 llama-server 进程'
    }
}
if ($KeepOpen) { Write-Host ''; Write-Host '  按回车关闭窗口…' -ForegroundColor DarkGray; $null = Read-Host }
exit 0
