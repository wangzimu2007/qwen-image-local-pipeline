# 给生成的图片写元数据（PNG text 块），用于溯源：模型 / 参数 / 提示词 / 时间
# 用法（脚本里）：
#   . (Join-Path $PSScriptRoot '_meta.ps1')
#   Write-MediaMeta -Path $final -Extra @{ Model='Z-Image Turbo'; Prompt=$Prompt; Steps=$Steps }
# 说明：
#   - 只对 PNG 生效（jpg/webp 跳过，不报错）
#   - 依赖 _pngmeta.py + 带 Pillow 的 Python
#   - 想全局关掉：设置环境变量 PIPE_NOMETA=1

function Write-MediaMeta {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Extra = @{}
    )
    try {
        if ($env:PIPE_NOMETA -eq '1') { return }
        if (-not $Path -or -not (Test-Path $Path)) { return }
        if ([System.IO.Path]::GetExtension($Path).ToLower() -ne '.png') { return }

        $metaPy = Join-Path $PSScriptRoot '_pngmeta.py'
        if (-not (Test-Path $metaPy)) { return }

        $py = 'D:\deepseek harness\resources\runtime\primary-runtime\dependencies\python\python.exe'
        if (-not (Test-Path $py)) {
            $c = Get-Command python -ErrorAction SilentlyContinue
            if (-not $c) { return }
            $py = $c.Source
        }

        # 记录"哪个脚本"生成的（函数定义在 _meta.ps1，所以不能用 $PSCommandPath）
        $callerName = ''
        try {
            $stack = Get-PSCallStack
            if ($stack.Count -gt 1 -and $stack[1].ScriptName) { $callerName = Split-Path $stack[1].ScriptName -Leaf }
        } catch { }
        if (-not $callerName -or $callerName -eq '_meta.ps1') { $callerName = 'unknown' }
        $data = @{ GeneratedBy = $callerName; GeneratedAt = (Get-Date).ToString('s') }
        foreach ($k in $Extra.Keys) {
            if ($null -ne $Extra[$k] -and "$($Extra[$k])" -ne '') { $data[$k] = "$($Extra[$k])" }
        }

        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('meta-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        [System.IO.File]::WriteAllText($tmp, ($data | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))

        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $env:PYTHONIOENCODING = 'utf-8'
        & $py $metaPy --in $Path --jsonfile $tmp 2>&1 | Out-Null
        $ErrorActionPreference = $prevEap
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    } catch { }
}

# 读取 PNG 元数据（排查用）
function Get-MediaMeta {
    param([Parameter(Mandatory = $true)][string]$Path)
    $py = 'D:\deepseek harness\resources\runtime\primary-runtime\dependencies\python\python.exe'
    if (-not (Test-Path $py)) { return @{} }
    $code = @'
import json, sys
from PIL import Image
im = Image.open(sys.argv[1])
out = {k: v for k, v in (im.info or {}).items() if isinstance(v, str) and len(v) < 500}
print(json.dumps(out, ensure_ascii=False))
'@
    $f = Join-Path ([System.IO.Path]::GetTempPath()) ('readmeta-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.py')
    [System.IO.File]::WriteAllText($f, $code, (New-Object System.Text.UTF8Encoding($false)))
    $env:PYTHONIOENCODING = 'utf-8'
    $raw = & $py $f $Path 2>$null
    Remove-Item $f -Force -ErrorAction SilentlyContinue
    try { return ($raw | ConvertFrom-Json -AsHashtable) } catch { return @{} }
}
