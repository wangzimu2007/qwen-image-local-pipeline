# 崩溃记录.ps1 —— 汇总最近的蓝屏/意外关机记录，方便判断是不是同一类问题
#
# 用法：
#   .\崩溃记录.ps1              # 最近 30 天
#   .\崩溃记录.ps1 -Days 90
#   .\崩溃记录.ps1 -Json        # 机器可读
param(
    [int]$Days = 30,
    [switch]$Json
)

$ErrorActionPreference = 'Continue'
$since = (Get-Date).AddDays(-$Days)
$rows = @()

try {
    $events = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 1001, 6008; StartTime = $since } -ErrorAction Stop
} catch {
    $events = @()
}

foreach ($e in ($events | Sort-Object TimeCreated)) {
    $code = ''
    if ($e.Id -eq 1001) {
        $m = [regex]::Match($e.Message, '0x([0-9A-Fa-f]{8})')
        if ($m.Success) { $code = '0x' + $m.Groups[1].Value.ToUpper() }
    }
    $meaning = switch ($code) {
        '0X00000116' { 'VIDEO_TDR_FAILURE（显卡驱动超时）' }
        '0X00000119' { 'VIDEO_SCHEDULER_INTERNAL_ERROR（显卡调度器）' }
        '0X00000124' { 'WHEA_UNCORRECTABLE_ERROR（硬件错误）' }
        '0X0000019C' { 'WIN32K_POWER_WATCHDOG_TIMEOUT（显卡/电源转换卡死）' }
        '0X00020001' { 'HYPERVISOR_ERROR（虚拟化层）' }
        '0X0000009F' { 'DRIVER_POWER_STATE_FAILURE（驱动电源状态）' }
        '0X000000EF' { 'CRITICAL_PROCESS_DIED（关键进程崩溃）' }
        '0X00000050' { 'PAGE_FAULT_IN_NONPAGED_AREA（内存/驱动）' }
        '0X0000007A' { 'KERNEL_DATA_INPAGE_ERROR（磁盘/分页）' }
        '0X0000001A' { 'MEMORY_MANAGEMENT（内存管理）' }
        '0X00000133' { 'DPC_WATCHDOG_VIOLATION（驱动卡住）' }
        default { '' }
    }
    $dump = [regex]::Match($e.Message, '(C:\\Windows\\[^\s]+\.dmp)')
    $rows += [pscustomobject]@{
        time    = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
        eventId = $e.Id
        code    = $code
        meaning = $meaning
        dump    = $(if ($dump.Success) { $dump.Groups[1].Value } else { '' })
    }
}

if ($Json) {
    [pscustomobject]@{ days = $Days; count = $rows.Count; crashes = $rows } | ConvertTo-Json -Depth 5
    exit 0
}

Write-Host ''
Write-Host ('== 最近 ' + $Days + ' 天的崩溃/意外关机 ==') -ForegroundColor Cyan
if ($rows.Count -eq 0) {
    Write-Host '  没有记录 ✅' -ForegroundColor Green
} else {
    foreach ($r in $rows) {
        $c = if ($r.eventId -eq 41) { 'DarkGray' } elseif ($r.eventId -eq 1001) { 'Red' } else { 'Yellow' }
        Write-Host ('  {0}  ID={1,-5} {2,-12} {3}' -f $r.time, $r.eventId, $r.code, $r.meaning) -ForegroundColor $c
    }
}
Write-Host ''
Write-Host '  提示：0x116 / 0x19C / 0x124 多与显卡驱动或硬件有关；0x20001 与虚拟化层有关。' -ForegroundColor DarkGray
Write-Host '  转储文件在 C:\Windows\Minidump\，可用 WinDbg 分析 !analyze -v。' -ForegroundColor DarkGray
Write-Host ''
exit 0
