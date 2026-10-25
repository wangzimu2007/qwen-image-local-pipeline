# 电源记录.ps1 —— 记录电源模式与功耗，用于对照蓝屏/卡死时间点
#
# 每 30 秒采样一次，写入 .jobs\电源记录.csv
# 用途：下次崩溃后，看崩溃前几分钟是否刚好切过奥创模式/改过功率上限。
#
# 用法：
#   .\电源记录.ps1            # 常驻（每 30 秒）
#   .\电源记录.ps1 -Once      # 只采一次
#   .\电源记录.ps1 -Interval 60
param(
    [switch]$Once,
    [int]$Interval = 30
)

$ErrorActionPreference = 'Continue'
$jobsRoot = 'D:\qwen-image-2.1\.jobs'
if (-not (Test-Path $jobsRoot)) { New-Item -ItemType Directory -Force -Path $jobsRoot | Out-Null }
$csv = Join-Path $jobsRoot '电源记录.csv'
$pidFile = Join-Path $jobsRoot '电源记录.pid'

if (-not $Once -and (Test-Path $pidFile)) {
    $old = (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($old -and (Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue)) {
        Write-Host ('  已有电源记录在跑（PID ' + $old + '），本次退出')
        exit 0
    }
}

if (-not (Test-Path $csv)) {
    'time,powerPlan,powerPlanGuid,gpuPowerLimitW,gpuPowerDrawW,gpuTempC,gpuMemUsedMiB,freeRamGB,queuePending,queueRunning' |
        Set-Content -Path $csv -Encoding UTF8
}

# 轮转：超过 5 MB 就改名归档
function Rotate-Log {
    if ((Test-Path $csv) -and ((Get-Item $csv).Length -gt 5MB)) {
        $bak = Join-Path $jobsRoot ('电源记录-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
        Move-Item $csv $bak -Force -ErrorAction SilentlyContinue
        'time,powerPlan,powerPlanGuid,gpuPowerLimitW,gpuPowerDrawW,gpuTempC,gpuMemUsedMiB,freeRamGB,queuePending,queueRunning' |
            Set-Content -Path $csv -Encoding UTF8
    }
}

function Get-PowerPlan {
    $out = powercfg /getactivescheme 2>&1
    $m = [regex]::Match(($out -join ' '), '([0-9a-fA-F-]{36})\s+\(([^)]+)\)')
    if ($m.Success) {
        return [pscustomobject]@{ guid = $m.Groups[1].Value; name = $m.Groups[2].Value }
    }
    return [pscustomobject]@{ guid = ''; name = '' }
}

function Sample {
    $plan = Get-PowerPlan
    $pl = ''; $draw = ''; $temp = ''; $memUsed = ''
    try {
        $q = & nvidia-smi --query-gpu=enforced.power.limit,power.draw,temperature.gpu,memory.used --format=csv,noheader,nounits 2>&1
        if ($q -and ($q -join '') -notmatch 'N/A') {
            $parts = ($q -join ' ').Trim() -split '\s*,\s*'
            if ($parts.Count -ge 4) { $pl = $parts[0].Trim(); $draw = $parts[1].Trim(); $temp = $parts[2].Trim(); $memUsed = $parts[3].Trim() }
        }
    } catch { }
    $freeRam = ''
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $freeRam = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    } catch { }
    $pending = @(Get-ChildItem (Join-Path $jobsRoot 'pending') -File -Filter '*.json' -ErrorAction SilentlyContinue).Count
    $running = @(Get-ChildItem (Join-Path $jobsRoot 'running') -File -Filter '*.json' -ErrorAction SilentlyContinue).Count
    $row = '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $plan.name, $plan.guid, $pl, $draw, $temp, $memUsed, $freeRam, $pending, $running
    Add-Content -Path $csv -Value $row -Encoding UTF8
}

if ($Once) {
    Sample
    Write-Host ('  已采样一次 → ' + $csv)
    Get-Content $csv -Tail 2 -Encoding UTF8 | ForEach-Object { '  ' + $_ }
    exit 0
}

Set-Content -Path $pidFile -Value $PID -Encoding ASCII
Write-Host ('  电源记录启动，PID ' + $PID + '，间隔 ' + $Interval + ' 秒 → ' + $csv)
while ($true) {
    try { Sample; Rotate-Log } catch { }
    Start-Sleep -Seconds $Interval
}
