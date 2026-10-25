# 接入新后端.ps1 —— 新模型接入标准动作（一条命令完成配置 + 快捷方式）
#
# 做什么：
#   1) 往 backends.json 追加/更新一条后端定义
#   2) 建桌面快捷方式「<Display> - 启动 / 停止」（走通用 后端启停.ps1）
#   3) 打印验证命令
#
# 之后这些能力自动生效（不用改代码）：
#   · 看状态 / 托盘：自动列出该后端并显示 就绪/启动中/离线/已手动停止
#   · Keeper：作业结束后自动拉回（尊重手动停止）
#   · 后端启停.ps1：通用启停
#
# 用法：
#   .\接入新后端.ps1 -ShowList
#   .\接入新后端.ps1 -Kind lmstudio -Display "LM Studio" -Port 1234 -StartCmd "C:\x\start.cmd" -StopCmd "C:\x\stop.cmd" -Procs "LM Studio"
#   .\接入新后端.ps1 -Kind myollama -Display "My Ollama" -Port 11435 -Api ollama -StartExe "C:\x\app.exe" -StopProcs "app","app-server" -Procs "app"
#   .\接入新后端.ps1 -Kind ninfer2 -Display "NInfer 2" -Port 8091 -StartVbs "D:\x\start.vbs" -StopPs "D:\x\stop.ps1"
param(
    [string]$Kind = '',
    [string]$Display = '',
    [int]$Port = 0,
    [ValidateSet('openai', 'ollama')][string]$Api = 'openai',
    [string]$StartCmd = '',
    [string]$StartExe = '',
    [string]$StartVbs = '',
    [string]$StopCmd = '',
    [string]$StopPs = '',
    [string[]]$StopProcs = @(),
    [string[]]$Procs = @(),
    [string]$Note = '',
    [switch]$Disabled,
    [switch]$NoShortcut,
    [switch]$Force,
    [switch]$ShowList
)

$ErrorActionPreference = 'Continue'
$cfgPath = Join-Path $PSScriptRoot 'backends.json'
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Say { param([string]$t, [string]$c = 'Gray') Write-Host ('  ' + $t) -ForegroundColor $c }

function Load-Cfg {
    if (-not (Test-Path $cfgPath)) { return [pscustomobject]@{ backends = @() } }
    try { return (Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return [pscustomobject]@{ backends = @() } }
}

if ($ShowList -or -not $Kind) {
    $cfg = Load-Cfg
    Write-Host ''
    Write-Host '== backends.json 里已配置的后端 ==' -ForegroundColor Cyan
    foreach ($b in @($cfg.backends)) {
        $en = if ($null -ne $b.enabled -and -not $b.enabled) { '  [disabled]' } else { '' }
        Write-Host ('  {0,-10} :{1,-6} {2,-14} api={3}{4}' -f $b.kind, $b.port, $b.display, $b.api, $en)
    }
    Write-Host ''
    Write-Host '  接入新后端：.\接入新后端.ps1 -Kind <kind> -Display "<名称>" -Port <端口> [启动/停止方式]'
    Write-Host ''
    if (-not $Kind) { exit 0 }
}

if ($Port -le 0) { Say '✗ 需要 -Port' 'Red'; exit 1 }
if (-not $Display) { $Display = $Kind }

$cfg = Load-Cfg
$entryList = New-Object System.Collections.ArrayList
foreach ($b in @($cfg.backends)) { [void]$entryList.Add($b) }

$exists = -1
for ($i = 0; $i -lt $entryList.Count; $i++) {
    if ([string]$entryList[$i].kind -eq $Kind) { $exists = $i; break }
}
if ($exists -ge 0 -and -not $Force) {
    Say ('✗ 已存在 kind=' + $Kind + '（要覆盖请加 -Force）') 'Red'
    exit 1
}

$entry = [pscustomobject]@{
    kind      = $Kind
    display   = $Display
    port      = $Port
    api       = $Api
    enabled   = (-not $Disabled)
    startCmd  = $StartCmd
    startExe  = $StartExe
    startVbs  = $StartVbs
    stopCmd   = $StopCmd
    stopPs    = $StopPs
    stopProcs = @($StopProcs)
    procs     = @($Procs)
    note      = $Note
}

if ($exists -ge 0) { $entryList[$exists] = $entry } else { [void]$entryList.Add($entry) }

$out = [pscustomobject]@{
    _comment = '本地模型后端清单（由 接入新后端.ps1 或手工维护）'
    backends = @($entryList)
}
[System.IO.File]::WriteAllText($cfgPath, ($out | ConvertTo-Json -Depth 6), $utf8)
Say ('✓ 已写入 backends.json：' + $Kind + '（端口 ' + $Port + '）') 'Green'

if (-not $NoShortcut) {
    $sh = New-Object -ComObject WScript.Shell
    $psExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $dir = 'C:\Users\wangzimu\Desktop\本地AI快捷方式'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    foreach ($pair in @(
        @{ name = ($Display + ' - 启动'); args = ('-Kind ' + $Kind + ' -Action start -Wait'); icon = 137; desc = '启动（解除禁止自动拉回）' },
        @{ name = ($Display + ' - 停止'); args = ('-Kind ' + $Kind + ' -Action stop'); icon = 131; desc = '停止（并禁止自动拉回）' }
    )) {
        $lnkPath = Join-Path $dir ($pair.name + '.lnk')
        $lnk = $sh.CreateShortcut($lnkPath)
        $lnk.TargetPath = $psExe
        $lnk.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "D:\qwen-image-2.1\后端启停.ps1" ' + $pair.args)
        $lnk.WorkingDirectory = 'D:\qwen-image-2.1'
        $lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll," + $pair.icon
        $lnk.Description = $pair.desc
        $lnk.Save()
        Say ('✓ 快捷方式：' + $pair.name) 'Green'
    }
}

Say ''
Say '== 接下来 ==' 'Cyan'
Say '  1) 状态确认：  D:\qwen-image-2.1\看状态.ps1'
Say ('  2) 启停测试：  D:\qwen-image-2.1\后端启停.ps1 -Kind ' + $Kind + ' -Action start -Wait')
Say ('                D:\qwen-image-2.1\后端启停.ps1 -Kind ' + $Kind + ' -Action stop')
Say '  3) 要在 DSH 里用它：设置 → 模型 → 加 provider（baseURL 指向该端口 /v1），切默认模型即可'
Say ''
Say '  手动停止标记 / Keeper / 托盘都自动生效，不需要改代码。' 'DarkGray'
exit 0
