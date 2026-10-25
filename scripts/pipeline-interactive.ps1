# 流水线交互入口：列出配方 → 选一个 → 填关键参数 → 执行
# 双击桌面「流水线 - 运行」用这个
$ErrorActionPreference = 'Continue'
$pipeRoot = 'D:\qwen-image-2.1'
$recipeDir = Join-Path $pipeRoot 'recipes'

Write-Host ''
Write-Host '=========  AI 流水线  =========' -ForegroundColor Cyan
$recipes = @(Get-ChildItem $recipeDir -Filter '*.json' | Sort-Object Name)
if ($recipes.Count -eq 0) {
    Write-Host '没有配方文件' -ForegroundColor Red
    Read-Host '回车关闭' | Out-Null
    exit 1
}

$i = 0
foreach ($r in $recipes) {
    $i++
    $o = [System.IO.File]::ReadAllText($r.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Write-Host ('  [' + $i + '] ' + $o.name) -ForegroundColor Yellow
    Write-Host ('      ' + $o.description) -ForegroundColor DarkGray
    Write-Host ('      步骤：' + (($o.steps | ForEach-Object { $_.id }) -join ' → ')) -ForegroundColor DarkGray
}
Write-Host ''
$pick = Read-Host '选配方编号（直接回车 = 1）'
if (-not $pick) { $pick = '1' }
$idx = 0
[void][int]::TryParse($pick, [ref]$idx)
if ($idx -lt 1 -or $idx -gt $recipes.Count) {
    Write-Host '编号无效' -ForegroundColor Red
    Read-Host '回车关闭' | Out-Null
    exit 1
}
$recipe = $recipes[$idx - 1]
$obj = [System.IO.File]::ReadAllText($recipe.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json

Write-Host ''
Write-Host ('已选：' + $obj.name) -ForegroundColor Green
Write-Host '（每项直接回车 = 用默认值）' -ForegroundColor DarkGray
$setArgs = @()
foreach ($p in $obj.vars.PSObject.Properties) {
    $cur = [string]$p.Value
    $label = '  ' + $p.Name
    if ($cur) { $label += '（默认：' + $cur + '）' }
    $v = Read-Host ($label + '：')
    if (-not $v) { $v = $cur }
    if ($v) { $setArgs += ($p.Name + '=' + $v) }
}

Write-Host ''
$dry = Read-Host '先 DryRun 看命令？(y/N)'
$argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $pipeRoot '流水线.ps1'), '-Recipe', $recipe.BaseName)
if ($setArgs.Count -gt 0) { $argv += @('-Set', ($setArgs -join ';')) }
if ($dry -match '^[Yy]') { $argv += '-DryRun' }
& 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' @argv

Write-Host ''
Read-Host '回车关闭' | Out-Null
