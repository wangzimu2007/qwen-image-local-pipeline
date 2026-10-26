# 共用的交互式选择组件（被 画图.ps1 / 改图.ps1 / 编辑.ps1 引用）
# 提供：选图片文件对话框、选分辨率菜单、自增序号文件名

function Select-ImageFile {
    param(
        [string]$Title = '选择要作为底图的图片',
        [string]$InitialDir = ''
    )
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = $Title
        if ($InitialDir -and (Test-Path $InitialDir)) { $dlg.InitialDirectory = $InitialDir }
        $dlg.Filter = '图片文件|*.png;*.jpg;*.jpeg;*.webp;*.bmp|所有文件|*.*'
        $dlg.Multiselect = $false
        $dlg.RestoreDirectory = $true
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
        return ''
    } catch {
        # 环境不支持对话框时，退回控制台输入
        Write-Host '（无法弹出文件选择框，请手动粘贴图片路径，直接回车=用最新一张）' -ForegroundColor DarkYellow
        return (Read-Host '图片路径')
    }
}

function Format-Dimension {
    param([int]$Value)
    $v = [int]([math]::Round($Value / 8.0) * 8)
    if ($v -lt 256) { $v = 256 }
    if ($v -gt 2048) { $v = 2048 }
    return $v
}

# 返回 @(宽, 高)
function Select-Resolution {
    param(
        [int]$DefaultWidth = 1024,
        [int]$DefaultHeight = 1024
    )
    Write-Host ''
    Write-Host '选择输出分辨率：' -ForegroundColor Cyan
    Write-Host ('  1) 1024 × 1024   方形（常用）' + $(if ($DefaultWidth -eq 1024 -and $DefaultHeight -eq 1024) { '  ← 默认' } else { '' }))
    Write-Host '  2) 768 × 768     小图，更快'
    Write-Host '  3) 1024 × 1536   竖版（海报/人物）'
    Write-Host '  4) 1536 × 1024   横版（风景）'
    Write-Host '  5) 自定义宽高'
    Write-Host '  6) 跟随底图尺寸（仅改图/编辑有意义）'
    $a = Read-Host '输入序号（直接回车 = 1）'

    switch ("$a".Trim()) {
        '2' { return @(768, 768) }
        '3' { return @(1024, 1536) }
        '4' { return @(1536, 1024) }
        '6' { return @(0, 0) }   # 0,0 = 由调用方决定（跟随底图）
        '5' {
            $w = Read-Host '输入宽度（像素，256-2048，自动对齐到 8 的倍数）'
            $h = Read-Host '输入高度（像素，256-2048，自动对齐到 8 的倍数）'
            $wi = 0; $hi = 0
            if (-not [int]::TryParse("$w".Trim(), [ref]$wi) -or -not [int]::TryParse("$h".Trim(), [ref]$hi)) {
                Write-Warning '输入的不是数字，改用 1024×1024'
                return @(1024, 1024)
            }
            $wi = Format-Dimension $wi
            $hi = Format-Dimension $hi
            Write-Host ("  使用 {0} × {1}" -f $wi, $hi) -ForegroundColor Green
            return @($wi, $hi)
        }
        default { return @(1024, 1024) }
    }
}

# 读取图片的实际像素尺寸（不依赖任何图像库，用 System.Drawing）
function Get-ImageSize {
    param([string]$Path)
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $img = [System.Drawing.Image]::FromFile($Path)
        $r = @($img.Width, $img.Height)
        $img.Dispose()
        return $r
    } catch {
        return @(0, 0)
    }
}

# 生成下一个图片路径：序号自增（qwen-0001-t2i-20261024-095500.png）
# 配合资源管理器的「名称 + 降序」排序，最新生成的永远排在第一。
function Get-NextImagePath {
    param(
        [string]$OutDir,
        [string]$Kind = 'img'   # t2i=文生图 / redraw=改图 / edit=指令编辑
    )
    $max = 0
    Get-ChildItem (Join-Path $OutDir '*.png') -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match '^qwen-(\d{4,})-') {
            $n = [int]$Matches[1]
            if ($n -gt $max) { $max = $n }
        }
    }
    $next  = $max + 1
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    return (Join-Path $OutDir ("qwen-{0:D4}-{1}-{2}.png" -f $next, $Kind, $stamp))
}
