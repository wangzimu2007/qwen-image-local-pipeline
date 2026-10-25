# 启动常驻守护（幂等）：思考代理 / watchdog / 作业守护
#
# 为什么要用 WMI 而不是 Start-Process：
#   用 Start-Process 从 DSH 工具里拉起的进程会挂在 DSH 的进程树下，
#   **DSH 一重启/退出，这些守护全被带走**（2026-10-25 实测踩坑：
#   DSH 从 8169 端口重启到 12784 后，8081 代理 / watchdog / 作业守护全灭，
#   本地模型会话因为 baseURL 指向 8081 而报 TRANSPORT Connection error）。
#   WMI 的 Win32_Process.Create 由 WmiPrvSE.exe 创建进程，父进程不是 DSH → 不受影响。
#
# 用法：
#   .\启动守护.ps1              # 启动全部（已在跑就跳过）
#   .\启动守护.ps1 -Status      # 只看状态
#   .\启动守护.ps1 -Force       # 先停再起
param(
    [switch]$Status,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'
$ps1 = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$py = 'D:\deepseek harness\resources\runtime\primary-runtime\dependencies\python\pythonw.exe'

$services = @(
    @{
        Name = '思考代理'
        Port = 8081
        PidFile = 'D:\qwen-image-2.1\.think-proxy.pid'
        CommandLine = '"{0}" -u "D:\qwen-image-2.1\think-off-proxy.py" --port 8081 --log "D:\qwen-image-2.1\.think-proxy.log"' -f $py
        WorkDir = 'D:\qwen-image-2.1'
        Check = { param($s) $null = $s }
    },
    @{
        Name = 'watchdog'
        Port = 0
        PidFile = 'D:\tools\win-layout\watchdog.pid'
        CommandLine = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "D:\tools\win-layout\watchdog.ps1"' -f $ps1
        WorkDir = 'D:\tools\win-layout'
        Check = { param($s) $null = $s }
    },
    @{
        Name = '作业守护'
        Port = 0
        PidFile = 'D:\qwen-image-2.1\.jobs\守护.pid'
        CommandLine = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "D:\qwen-image-2.1\作业守护.ps1"' -f $ps1
        WorkDir = 'D:\qwen-image-2.1'
        Check = { param($s) $null = $s }
    }
)

function Test-Service {
    param($svc)
    if ($svc.Port -gt 0) {
        $c = Get-NetTCPConnection -LocalPort $svc.Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { return @{ up = $true; how = 'port'; pid = $c.OwningProcess } }
    }
    if (Test-Path $svc.PidFile) {
        $id = Get-Content $svc.PidFile -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($id -and (Get-Process -Id $id -ErrorAction SilentlyContinue)) {
            return @{ up = $true; how = 'pid'; pid = $id }
        }
    }
    return @{ up = $false; how = ''; pid = 0 }
}

function Start-Service-Wmi {
    param($svc)
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = $svc.CommandLine
        CurrentDirectory = $svc.WorkDir
    } -ErrorAction SilentlyContinue
    if ($r -and $r.ReturnValue -eq 0) { return $r.ProcessId }
    return 0
}

Write-Host ''
Write-Host '== 常驻守护状态 ==' -ForegroundColor Cyan
foreach ($svc in $services) {
    $st = Test-Service $svc
    $parent = ''
    if ($st.up -and $st.pid) {
        $p = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $st.pid) -ErrorAction SilentlyContinue
        if ($p) {
            $pp = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $p.ParentProcessId) -ErrorAction SilentlyContinue
            $parent = if ($pp) { $pp.Name } else { '?' }
        }
    }
    $mark = if ($st.up) { '✓ 在跑' } else { '✗ 没跑' }
    $extra = if ($st.up) { "（PID $($st.pid)，父进程 $parent）" } else { '' }
    Write-Host ("  {0,-8} {1}{2}" -f $svc.Name, $mark, $extra) -ForegroundColor $(if ($st.up) { 'Green' } else { 'Yellow' })
}

if ($Status) { Write-Host ''; exit 0 }

foreach ($svc in $services) {
    $st = Test-Service $svc
    if ($st.up -and -not $Force) { continue }
    if ($st.up -and $Force) {
        # 只按 PID 文件停，避免误杀别的会话
        if (Test-Path $svc.PidFile) {
            $id = Get-Content $svc.PidFile -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($id) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
        }
        if ($svc.Port -gt 0) {
            $c = Get-NetTCPConnection -LocalPort $svc.Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($c) { Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue }
        }
        Start-Sleep -Seconds 2
    }
    $newPid = Start-Service-Wmi $svc
    if ($svc.Name -eq '思考代理' -and $newPid -gt 0) {
        Set-Content -Path $svc.PidFile -Value $newPid -Encoding ASCII -ErrorAction SilentlyContinue
    }
    Write-Host ("  启动 {0} → PID {1}" -f $svc.Name, $newPid) -ForegroundColor Gray
}

Start-Sleep -Seconds 4
Write-Host ''
Write-Host '== 启动后核验 ==' -ForegroundColor Cyan
$allOk = $true
foreach ($svc in $services) {
    $st = Test-Service $svc
    Write-Host ("  {0,-8} {1}" -f $svc.Name, $(if ($st.up) { '✓' } else { '✗' })) -ForegroundColor $(if ($st.up) { 'Green' } else { 'Red' })
    if (-not $st.up) { $allOk = $false }
}
if ($allOk) { Write-Host '  全部就绪。' -ForegroundColor Green }
else { Write-Host '  有服务没起来，看上面的日志/端口。' -ForegroundColor Yellow }
Write-Host ''
exit 0
