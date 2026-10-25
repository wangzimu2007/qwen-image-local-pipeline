# 停Strata.ps1 —— 手动停止 Strata（并告诉守护：这是我主动停的，别自动拉回来）
#
# 用户意图标记：D:\qwen-image-2.1\.jobs\user-stop.flag
#   - Keeper（watchdog）看到这个标记就不自动拉起
#   - 你下次双击「Strata IQ3_S - 启动」会清掉标记
#   - 标记 12 小时后自动失效（防止忘记后永远不恢复）
param(
    [ValidateSet('iq3s', 'nvfp4')]
    [string]$Variant = 'iq3s',
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_backend.ps1')
$jobsRoot = 'D:\qwen-image-2.1\.jobs'
$flag = Join-Path $jobsRoot 'user-stop.flag'
if (-not (Test-Path $jobsRoot)) { New-Item -ItemType Directory -Force -Path $jobsRoot | Out-Null }

function Say { param([string]$t, [string]$c = 'Gray') if (-not $Quiet) { Write-Host ('  ' + $t) -ForegroundColor $c } }

# 1) 先写标记（这样即使停止过程中 Keeper 触发，也不会抢着拉起）
$rec = @{ at = (Get-Date).ToString('o'); variant = $Variant; by = 'manual' }
$flag = Set-UserStopFlag -Kind 'strata' -JobsRoot $jobsRoot
Say ('已记录手动停止标记：' + $flag) 'DarkGray'

# 2) 执行真正的停止脚本
$stopCmd = if ($Variant -eq 'nvfp4') { 'stop-nvfp4.cmd' } else { 'stop-iq3s.cmd' }
$stopPath = Join-Path $env:LOCALAPPDATA ('Strata\actions\' + $stopCmd)
if (-not (Test-Path $stopPath)) {
    Say ('找不到停止脚本：' + $stopPath) 'Red'
    exit 1
}
Say ('停止 Strata（' + $Variant + '）…') 'Yellow'
Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', ('"' + $stopPath + '"')) -WindowStyle Hidden -Wait

# 3) 等端口真正释放
$gone = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    if (-not (Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue)) { $gone = $true; break }
}
if ($gone) { Say '✓ 已停止，并且不会自动拉回来（直到你点「Strata IQ3_S - 启动」）' 'Green' }
else { Say '⚠ 8080 仍在监听，可能还没停干净（可再点一次）' 'Yellow' }

# 4) 顺手清掉"想恢复"的标记，避免守护批末又拉起
@('strata-wanted.json', 'backends-wanted.json') | ForEach-Object {
    $p = Join-Path $jobsRoot $_
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
exit 0
