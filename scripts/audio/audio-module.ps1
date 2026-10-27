# 音频模块.ps1 —— 统一音频入口（既可单独使用，也能被视频/图像流水线调用）
#
# 设计目标（2026-10-26 用户要求）：
#   1. 保留音频模块单独工作的能力（直接 -Action 调用）
#   2. 视频/图像工作流可通过同一入口调用（流水线.ps1 的 audio-mod 步骤）
#   3. 音频侧封装好后，只需改 audio-module.json 里的脚本路径，本入口不用动
#
# 用法：
#   .\音频模块.ps1 -Action probe -Input a.wav
#   .\音频模块.ps1 -Action split -Input a.wav
#   .\音频模块.ps1 -Action transcribe -Input a.mp4 -Params "Language=zh;Model=large-v3-turbo"
#   .\音频模块.ps1 -Action sfx -Params "Prompt=雨夜街道的环境音" -Out D:\audio-tools\gen-out
#   .\音频模块.ps1 -Action mix -Input video.mp4 -Params "Audio=bgm.wav;Volume=0.3"
#   .\音频模块.ps1 -Action dub -Input video.mp4 -Params "Prompt=自然旁白"     # 转发视频配音
#   .\音频模块.ps1 -Action lipsync -Input video.mp4 -Params "Audio=voice.wav"
#   ....\音频模块.ps1 -Action list        # 看支持的动作
#
# 输出：默认人读文本；加 -Json 输出机器可读 JSON（流水线用这个）。
param(
    [Parameter(Mandatory = $true)][string]$Action,
    [Alias('Input')][string]$Source = '',
    [string]$Out = '',
    [string]$Params = '',
    [switch]$Json,
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$cfgPath = Join-Path $here 'audio-module.json'
$ffmpeg = 'D:\tools\ffmpeg\bin\ffmpeg.exe'
$ffprobe = 'D:\tools\ffmpeg\bin\ffprobe.exe'

$sw = [Diagnostics.Stopwatch]::StartNew()
$result = [ordered]@{
    ok = $false; action = $Action; module = 'audio-module'; files = @()
    outDir = $Out; seconds = 0; log = ''; error = ''
}

function Parse-Params {
    param([string]$s)
    $h = @{}
    if (-not $s) { return $h }
    foreach ($kv in ($s -split ';')) {
        if (-not $kv.Trim()) { continue }
        $i = $kv.IndexOf('=')
        if ($i -lt 1) { continue }
        $h[$kv.Substring(0, $i).Trim()] = $kv.Substring($i + 1).Trim()
    }
    return $h
}
function Get-Duration {
    param([string]$f)
    try {
        $v = & $ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $f 2>$null
        return [double](($v | Select-Object -First 1).Trim())
    } catch { return 0 }
}
function New-Files {
    param([datetime]$since, [string[]]$roots)
    $list = @()
    foreach ($r in $roots) {
        if (-not $r -or -not (Test-Path $r)) { continue }
        $list += @(Get-ChildItem $r -Recurse -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.LastWriteTime -ge $since.AddSeconds(-2) -and $_.Length -gt 0 } |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 12)
    }
    return @($list | Select-Object -Unique FullName | ForEach-Object { $_.FullName })
}

$pm = Parse-Params $Params
if ($Out) { $pm['Out'] = $Out }
$scriptMap = @{
    split      = '分离音频.ps1'
    splitmr    = '分离音频MR.ps1'
    denoise    = '降噪DFN.ps1'
    enhance    = '降噪增强.ps1'
    transcribe = '录音转字幕.ps1'
    diarize    = '说话人分离.ps1'
    clone      = '声音克隆.ps1'
    sr         = '音频超分.ps1'
    midi       = '音频转MIDI.ps1'
    master     = '母带匹配.ps1'
    lipsync    = '口型同步.ps1'
    align      = '字幕对齐.ps1'
    dubprompt  = '视频配音提示词.ps1'
    dub        = '视频配音提示词.ps1'
    'tts-cosy' = 'CosyVoice2配音.ps1'
    'vc-seed'  = 'SeedVC变声.ps1'
}

# ---------- 配置覆盖（音频侧封装后可改这里，不用改本脚本）----------
$overrides = @{}
if (Test-Path $cfgPath) {
    try {
        $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $cfg.PSObject.Properties) {
            if ($p.Name -eq 'actions' -and $p.Value) {
                foreach ($a in $p.Value.PSObject.Properties) { $overrides[$a.Name] = $a.Value }
            }
        }
    } catch { }
}

if ($Action -eq 'list') {
    $all = @($scriptMap.Keys) + @('sfx', 'mix', 'probe', 'tts') | Sort-Object -Unique
    Write-Host ''
    Write-Host '  可用动作：' -ForegroundColor Cyan
    $desc = @{
        split = '人声/伴奏分离'; splitmr = '人声伴奏分离(MR)'; denoise = '降噪(DFN)'; enhance = '降噪增强'
        transcribe = '录音/视频转字幕'; diarize = '说话人分离'; clone = '声音克隆（F5，Engine=chatterbox 可切）'; septext = '文本查询分离（AudioSep）'; sr = '音频超分'
        midi = '音频转 MIDI'; master = '母带匹配'; lipsync = '口型同步'; align = '字幕对齐'
        dubprompt = '视频→配音提示词'; dub = '视频→自动配音出片'; sfx = '文生音效/BGM'
        mix = '把音频混进视频'; probe = '探测时长/音量'; tts = '文字转语音'; voicedesign = '文字+声音描述→语音（Qwen3-TTS）'
        'tts-cosy' = 'CosyVoice2 文字转语音/风格指令'
        'vc-seed'  = 'Seed-VC 音色转换'
    }
    foreach ($a in $all) {
        $s = if ($overrides.ContainsKey($a) -and $overrides[$a].script) { $overrides[$a].script } elseif ($scriptMap.ContainsKey($a)) { $scriptMap[$a] } else { '（内置）' }
        '    {0,-11} {1,-16} → {2}' -f $a, $desc[$a], $s
    }
    Write-Host ''
    exit 0
}

function Invoke-Script {
    param([string]$scriptName, [string[]]$argList, [string[]]$scanRoots)
    $path = Join-Path $here $scriptName
    if (-not (Test-Path $path)) { throw ('缺少脚本：' + $path) }
    $start = Get-Date
    $outText = & powershell -NoProfile -ExecutionPolicy Bypass -File $path @argList 2>&1
    $text = ($outText | ForEach-Object { [string]$_ }) -join "`n"
    $result.log = $text
    $files = New-Files -since $start -roots $scanRoots
            if ($isFile -and (Test-Path $outTarget)) { $files = @($outTarget) }
    # 从输出里抓明确标注的产物路径（最可靠）
    $labeled = @()
    foreach ($m in [regex]::Matches($text, '(?:成品|输出文件|视频完成|音频完成|字幕|结果|输出)[：:]\s*(.+?\.(?:wav|mp3|flac|m4a|srt|midi|mid|mp4|json))', 'IgnoreCase')) {
        $labeled += $m.Groups[1].Value.Trim()
    }
    foreach ($f in $labeled) {
        if ((Test-Path $f) -and ($files -notcontains $f)) { $files += $f }
    }
    if (($outText -join "`n") -match '失败|错误|Traceback') { throw '子脚本输出包含错误信息' }
    return $files
}

try {
    switch ($Action) {
        'probe' {
            if (-not (Test-Path $Source)) { throw ('输入不存在：' + $Source) }
            $result.files = @($Source)
            $result | Add-Member -NotePropertyName durationSec -NotePropertyValue (Get-Duration $Source) -Force
            $result.ok = $true
        }
        'mix' {
            if (-not (Test-Path $Source)) { throw ('视频不存在：' + $Source) }
            $aud = $pm['Audio']
            if (-not $aud -or -not (Test-Path $aud)) { throw '缺少 Audio=混入的音频' }
            $vol = if ($pm['Volume']) { [double]$pm['Volume'] } else { 1.0 }
            $outTarget = if ($Out) { $Out } else { Join-Path $here 'gen-out' }
            $isFile = $outTarget -match '\.(wav|flac)$'
            $outDir = if ($isFile) { Split-Path $outTarget -Parent } else { $outTarget }
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
            $outFile = Join-Path $outDir ('mixed-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.mp4')
            $args = @('-y', '-i', $Source, '-i', $aud,
                      '-filter_complex', ('[1:a]volume={0}[a]' -f $vol),
                      '-map', '0:v:0', '-map', '[a]', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-shortest', $outFile)
            $log = & $ffmpeg @args 2>&1
            $result.log = (($log | ForEach-Object { [string]$_ }) -join "`n")
            if (-not (Test-Path $outFile)) { throw '混流出错' }
            $result.files = @($outFile)
            $result.ok = $true
        }
        'sfx' {
            $py = Join-Path $here 'gen-venv\Scripts\python.exe'
            $helper = Join-Path $here '_mod_sfx.py'
            if (-not (Test-Path $py)) { throw 'gen-venv 还没装好（等 _install_extras.ps1 完成）' }
            if (-not (Test-Path $helper)) { throw '缺少 _mod_sfx.py' }
            $prompt = $pm['Prompt']
            if (-not $prompt) { throw '缺少 Prompt=音效描述' }
            $secs = if ($pm['Seconds']) { $pm['Seconds'] } else { '8' }
            $outTarget = if ($Out) { $Out } else { Join-Path $here 'gen-out' }
            $isFile = $outTarget -match '\.(wav|flac)$'
            $outDir = if ($isFile) { Split-Path $outTarget -Parent } else { $outTarget }
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
            $start = Get-Date
            $outText = & $py $helper '--prompt' $prompt '--seconds' $secs '--out' $outDir 2>&1
            $text = ($outText | ForEach-Object { [string]$_ }) -join "`n"
            $result.log = $text
            $files = New-Files -since $start -roots @($outDir)
            if ($isFile -and (Test-Path $outTarget)) { $files = @($outTarget) }
            if ($files.Count -eq 0) { throw '音效生成失败（无输出文件）' }
            $result.files = $files
            $result.ok = $true
        }
        'prompt' {
            # 文字 → 声音设计提示词（本地模型扩写，供 sfx / voicedesign 使用）
            $brief = $pm['Text']
            if (-not $brief) { throw '缺少 Text=声音要求' }
            $kind = if ($pm['Kind']) { $pm['Kind'] } else { 'audio' }
            $outTarget = if ($Out) { $Out } else { Join-Path $here ('gen-out\prompt-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt') }
            $outDir = Split-Path $outTarget -Parent
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
            $start = Get-Date
            $outText = & powershell -NoProfile -ExecutionPolicy Bypass -File 'D:\qwen-image-2.1\提示词扩写.ps1' -Text $brief -Kind $kind -Out $outTarget -NoPause 2>&1
            $text3 = ($outText | ForEach-Object { [string]$_ }) -join "`n"
            $result.log = if ($text3.Length -gt 4000) { $text3.Substring($text3.Length - 4000) } else { $text3 }
            $m = [regex]::Match($text3, 'RESULT=(.+)')
            if ($m.Success -and (Test-Path $m.Groups[1].Value.Trim())) { $result.files = @($m.Groups[1].Value.Trim()); $result.ok = $true }
            else { throw '提示词扩写没有产出文件' }
        }
        'customvoice' {
            # 固定 speaker + 风格指令（Qwen3-TTS 0.6B CustomVoice，更快）
            $py = Join-Path $here 'tts-venv\Scripts\python.exe'
            $helper = Join-Path $here '_mod_qwen_tts.py'
            if (-not (Test-Path $py)) { throw 'tts-venv 未就绪（Qwen3-TTS）' }
            $text = $pm['Text']
            if (-not $text -and $pm['TextFile'] -and (Test-Path $pm['TextFile'])) { $text = (Get-Content $pm['TextFile'] -Raw -Encoding UTF8).Trim() }
            if (-not $text) { throw '缺少 Text=要朗读的文字' }
            $instruct = $pm['Instruct']
            if (-not $instruct -and $pm['InstructFile'] -and (Test-Path $pm['InstructFile'])) { $instruct = (Get-Content $pm['InstructFile'] -Raw -Encoding UTF8).Trim() }
            $lang = if ($pm['Language']) { $pm['Language'] } else { 'Chinese' }
            $spk = $pm['Speaker']
            $outTarget = if ($Out) { $Out } else { Join-Path $here 'gen-out' }
            $outDir = if ($outTarget -match '\.(wav|flac)$') { Split-Path $outTarget -Parent } else { $outTarget }
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
            $start = Get-Date
            $tmpT = Join-Path $env:TEMP ('qi_text_' + [guid]::NewGuid().ToString('n') + '.txt')
            $tmpI = Join-Path $env:TEMP ('qi_instr_' + [guid]::NewGuid().ToString('n') + '.txt')
            [System.IO.File]::WriteAllText($tmpT, $text, (New-Object System.Text.UTF8Encoding($false)))
            [System.IO.File]::WriteAllText($tmpI, [string]$instruct, (New-Object System.Text.UTF8Encoding($false)))
            $argv2 = @($helper, '--mode', 'custom', '--text-file', $tmpT, '--instruct-file', $tmpI, '--language', $lang, '--out', $outTarget)
            if ($spk) { $argv2 += @('--speaker', $spk) }
            $outText = & $py @argv2 2>&1
            $qcode = $LASTEXITCODE
            Remove-Item $tmpT, $tmpI -Force -ErrorAction SilentlyContinue
            $text3 = ($outText | ForEach-Object { [string]$_ }) -join "`n"
            $result.log = if ($text3.Length -gt 4000) { $text3.Substring($text3.Length - 4000) } else { $text3 }
            if ($outTarget -match '\.wav$' -and (Test-Path $outTarget)) { $result.files = @($outTarget); $result.ok = $true }
            else {
                $files = New-Files -since $start -roots @($outDir)
                if ($files.Count -eq 0) { throw ('CustomVoice 失败（退出码 ' + $qcode + '）') }
                $result.files = $files; $result.ok = $true
            }
        }
        'voicedesign' {
            # 文字 + 声音描述 → 语音（Qwen3-TTS VoiceDesign，独立 tts-venv）
            $py = Join-Path $here 'tts-venv\Scripts\python.exe'
            $helper = Join-Path $here '_mod_qwen_tts.py'
            if (-not (Test-Path $py)) { throw 'tts-venv 未就绪（Qwen3-TTS）' }
            if (-not (Test-Path $helper)) { throw '缺少 _mod_qwen_tts.py' }
            $text = $pm['Text']
            if (-not $text -and $pm['TextFile'] -and (Test-Path $pm['TextFile'])) { $text = (Get-Content $pm['TextFile'] -Raw -Encoding UTF8).Trim() }
            if (-not $text) { throw '缺少 Text=要朗读的文字' }
            $instruct = $pm['Instruct']
            if (-not $instruct -and $pm['InstructFile'] -and (Test-Path $pm['InstructFile'])) { $instruct = (Get-Content $pm['InstructFile'] -Raw -Encoding UTF8).Trim() }
            $lang = if ($pm['Language']) { $pm['Language'] } else { 'Chinese' }
            $outTarget = if ($Out) { $Out } else { Join-Path $here 'gen-out' }
            $isFile = $outTarget -match '\.(wav|flac)$'
            $outDir = if ($isFile) { Split-Path $outTarget -Parent } else { $outTarget }
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
            $start = Get-Date
            $tmpT = Join-Path $env:TEMP ('qi_text_' + [guid]::NewGuid().ToString('n') + '.txt')
            $tmpI = Join-Path $env:TEMP ('qi_instr_' + [guid]::NewGuid().ToString('n') + '.txt')
            [System.IO.File]::WriteAllText($tmpT, $text, (New-Object System.Text.UTF8Encoding($false)))
            [System.IO.File]::WriteAllText($tmpI, [string]$instruct, (New-Object System.Text.UTF8Encoding($false)))
            $outText = & $py $helper --text-file $tmpT --instruct-file $tmpI --language $lang --out $outTarget 2>&1
            $qcode = $LASTEXITCODE
            Remove-Item $tmpT, $tmpI -Force -ErrorAction SilentlyContinue
            $text3 = ($outText | ForEach-Object { [string]$_ }) -join "`n"
            $result.log = if ($text3.Length -gt 4000) { $text3.Substring($text3.Length - 4000) } else { $text3 }
            $files = New-Files -since $start -roots @($outDir)
            if ($isFile -and (Test-Path $outTarget)) { $files = @($outTarget) }
            if ($files.Count -eq 0) { throw ('VoiceDesign 失败（退出码 ' + $qcode + '）') }
            $result.files = $files
            $result.ok = $true
        }
        'tts' {
            $py = Join-Path $here 'workbench-venv\Scripts\python.exe'
            $helper = Join-Path $here '_mod_tts.py'
            if (-not (Test-Path $py)) { $py = Join-Path $here 'qt-venv\Scripts\python.exe' }
            if (-not (Test-Path $helper)) { throw '缺少 _mod_tts.py' }
            $text = $pm['Text']
            if (-not $text) { throw '缺少 Text=要朗读的文字' }
            $voice = if ($pm['Voice']) { $pm['Voice'] } else { 'zf_001' }
            $speed = if ($pm['Speed']) { $pm['Speed'] } else { '1.0' }
            $outTarget = if ($Out) { $Out } else { Join-Path $here 'gen-out' }
            $isFile = $outTarget -match '\.(wav|flac)$'
            $outDir = if ($isFile) { Split-Path $outTarget -Parent } else { $outTarget }
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
            $start = Get-Date
            $outText = & $py $helper '--text' $text '--voice' $voice '--speed' $speed '--out' $outDir 2>&1
            $text2 = ($outText | ForEach-Object { [string]$_ }) -join "`n"
            $result.log = $text2
            $files = New-Files -since $start -roots @($outDir)
            if ($isFile -and (Test-Path $outTarget)) { $files = @($outTarget) }
            if ($files.Count -eq 0) { throw 'TTS 失败（无输出）' }
            $result.files = $files
            $result.ok = $true
        }
        'clone' {
            # 声音克隆：默认 F5-TTS（零样本，自动转写参考）；Engine=chatterbox 则用 Chatterbox
            $ref = if ($Source) { $Source } elseif ($pm['Reference']) { $pm['Reference'] } else { '' }
            if (-not $ref) { throw '缺少参考音频：-Input 或 Reference=' }
            if (-not (Test-Path $ref)) { throw ('参考音频不存在：' + $ref) }
            $text = $pm['Text']
            if (-not $text) { throw '缺少 Text=要朗读的文字' }
            $outTarget = if ($Out) { $Out } else { Join-Path $here 'gen-out' }
            $isFile = $outTarget -match '\.(wav|flac)$'
            $outDir = if ($isFile) { Split-Path $outTarget -Parent } else { $outTarget }
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
            $outFile = if ($isFile) { $outTarget } else { Join-Path $outDir ('audio-clone-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.wav') }
            $engine = if ($pm['Engine']) { $pm['Engine'] } else { 'f5' }
            if ($engine -eq 'chatterbox') {
                $argList = @('-Reference', $ref, '-Text', $text, '-NoPause')
                if ($pm['Language']) { $argList += @('-Language', $pm['Language']) }
                if ($pm['Exaggeration']) { $argList += @('-Exaggeration', $pm['Exaggeration']) }
                if ($pm['CfgWeight']) { $argList += @('-CfgWeight', $pm['CfgWeight']) }
                $outText = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here '声音克隆.ps1') @argList 2>&1
            } else {
                $argList = @('-Reference', $ref, '-Text', $text, '-Out', $outFile, '-NoPause')
                if ($pm['RefText']) { $argList += @('-RefText', $pm['RefText']) }
                if ($pm['Speed']) { $argList += @('-Speed', $pm['Speed']) }
                if ($pm['PauseMs']) { $argList += @('-PauseMs', $pm['PauseMs']) }
                $outText = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'F5克隆.ps1') @argList 2>&1
            }
            $result.log = (($outText | ForEach-Object { [string]$_ }) -join "`n")
            if ($LASTEXITCODE -ne 0) { throw ('声音克隆失败（' + $engine + '），退出码 ' + $LASTEXITCODE) }
            if (Test-Path $outFile) { $result.files = @($outFile); $result.ok = $true }
            else {
                $files = New-Files -since (Get-Date).AddMinutes(-5) -roots @($outDir)
                if ($files.Count -eq 0) { throw '声音克隆没有产出文件' }
                $result.files = $files; $result.ok = $true
            }
        }
        'septext' {
            # 文本查询分离（AudioSep）：Query=speech/music/...
            if (-not $Source) { throw '缺少 -Input 输入音频' }
            $query = if ($pm['Query']) { $pm['Query'] } else { 'speech' }
            $outTarget = if ($Out) { $Out } else { Join-Path $here 'gen-out' }
            $outDir = if ($outTarget -match '\.(wav|flac)$') { Split-Path $outTarget -Parent } else { $outTarget }
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
            $outFile = if ($outTarget -match '\.wav$') { $outTarget } else { Join-Path $outDir ('audio-sep-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.wav') }
            $argList = @('-Input', $Source, '-Query', $query, '-Out', $outFile, '-NoPause')
            if ($pm['Device']) { $argList += @('-Device', $pm['Device']) }
            $outText = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'AudioSep分离.ps1') @argList 2>&1
            $result.log = (($outText | ForEach-Object { [string]$_ }) -join "`n")
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $outFile)) { throw 'AudioSep 分离失败' }
            $result.files = @($outFile)
            $result.ok = $true
        }
        'tts-cosy' {
            $text = $pm['Text']
            if (-not $text) { throw '缺少 Text=要朗读的文字' }
            $outTarget = if ($Out) { $Out } else { Join-Path $here 'gen-out' }
            $isFile = $outTarget -match '\.(wav|flac)$'
            $outDir = if ($isFile) { Split-Path $outTarget -Parent } else { $outTarget }
            if ($outDir -match '\.wav$') {
                $outFile = $outDir
                $outDir = Split-Path $outFile -Parent
            } else {
                New-Item -ItemType Directory -Force -Path $outDir | Out-Null
                $outFile = Join-Path $outDir ('audio-cosy-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.wav')
            }
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
            $argList = @('-Text', $text, '-Out', $outFile, '-NoPause')
            if ($pm['Instruct']) { $argList += @('-Instruct', $pm['Instruct']) }
            if ($pm['Reference']) { $argList += @('-Reference', $pm['Reference']) }
            $start = Get-Date
            $outText = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'CosyVoice2配音.ps1') @argList 2>&1
            $result.log = (($outText | ForEach-Object { [string]$_ }) -join "`n")
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $outFile)) { throw 'CosyVoice2 TTS 失败' }
            $result.files = @($outFile)
            $result.ok = $true
        }
        'vc-seed' {
            if (-not $Source) { throw '缺少 -Input 源音频' }
            if (-not $pm['Reference']) { throw '缺少 Reference=目标音色参考音频' }
            $outTarget = if ($Out) { $Out } else { Join-Path $here 'gen-out' }
            $isFile = $outTarget -match '\.(wav|flac)$'
            $outDir = if ($isFile) { Split-Path $outTarget -Parent } else { $outTarget }
            if ($outDir -match '\.wav$') {
                $outFile = $outDir
                $outDir = Split-Path $outFile -Parent
            } else {
                New-Item -ItemType Directory -Force -Path $outDir | Out-Null
                $outFile = Join-Path $outDir ('audio-seedvc-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.wav')
            }
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
            $argList = @('-Source', $Source, '-Reference', $pm['Reference'], '-Out', $outFile, '-NoPause')
            if ($pm['Steps']) { $argList += @('-Steps', $pm['Steps']) }
            if ($pm['SemiToneShift']) { $argList += @('-SemiToneShift', $pm['SemiToneShift']) }
            $outText = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'SeedVC变声.ps1') @argList 2>&1
            $result.log = (($outText | ForEach-Object { [string]$_ }) -join "`n")
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $outFile)) { throw 'Seed-VC 失败' }
            $result.files = @($outFile)
            $result.ok = $true
        }
        default {
            if (-not $scriptMap.ContainsKey($Action) -and -not $overrides.ContainsKey($Action)) {
                throw ('未知动作：' + $Action + '（用 -Action list 看列表）')
            }
            $scriptName = if ($overrides.ContainsKey($Action) -and $overrides[$Action].script) { $overrides[$Action].script } else { $scriptMap[$Action] }
            $argList = @()
            # 主输入
            if ($Source) {
                if ($Action -in @('lipsync', 'dub', 'dubprompt')) { $argList += @('-Video', $Source) }
                elseif ($Action -eq 'master') { $argList += @('-Target', $Source) }
                elseif ($Action -in @('transcribe')) { $argList += @('-Video', $Source) }
                else { $argList += @('-Audio', $Source) }
            }
            # 其余参数直通
            $passKeys = @('Audio', 'Video', 'Text', 'Language', 'Model', 'Formats', 'Device', 'ComputeType', 'OutDir',
                          'Output', 'Reference', 'Enhance', 'Steps', 'BboxShift', 'Prompt', 'Mode', 'BurnSubtitles')
            foreach ($k in $passKeys) {
                if (-not $pm.ContainsKey($k)) { continue }
                $v = $pm[$k]
                if ($v -eq 'true') { $argList += ('-' + $k) }
                elseif ($v -eq 'false') { }
                else { $argList += @(('-' + $k), $v) }
            }
            if ($Out -and -not $pm.ContainsKey('OutDir')) { $argList += @('-OutDir', $Out) }
            $argList += @('-NoPause')
            $result.log = ('执行：' + $scriptName + ' ' + ($argList -join ' '))
            $scanRoots = @()
            if ($Out) { $scanRoots += $Out }
            foreach ($d in @('demucs-out', 'align-venv', 'basicpitch-out', 'tts-stage', 'lipsync-work', 'gen-out')) { $scanRoots += (Join-Path $here $d) }
            $scanRoots += (Join-Path $here '音频工作台')
            $files = Invoke-Script -scriptName $scriptName -argList $argList -scanRoots $scanRoots
            if ($files.Count -eq 0) { throw '子脚本没有产出文件' }
            $result.files = $files
            $result.ok = $true
        }
    }
} catch {
    $result.error = $_.Exception.Message
    $result.ok = $false
} finally {
    $sw.Stop()
    $result.seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
}

if ($Json) {
    Write-Output ($result | ConvertTo-Json -Depth 6 -Compress)
} else {
    Write-Host ''
    if ($result.ok) {
        Write-Host ('  ✓ 音频模块 {0} 完成（{1} 秒）' -f $Action, $result.seconds) -ForegroundColor Green
        foreach ($f in $result.files) {
            $label = if ($Action -in @('dub','dubprompt','lipsync','mix','image-dub')) { '视频完成' } else { '音频完成' }
            Write-Host ($label + '：' + $f) -ForegroundColor Green
        }
        if ($result.action -eq 'probe') { Write-Host ('    时长 ' + $result.durationSec + ' 秒') }
    } else {
        Write-Host ('  ✗ 音频模块 {0} 失败：{1}' -f $Action, $result.error) -ForegroundColor Red
        if ($result.log) { ($result.log -split "`n" | Select-Object -Last 8) | ForEach-Object { '    ' + $_ } }
    }
    Write-Host ''
}
if (-not $NoPause -and -not $Json -and -not $env:PIPE_AUDIO_MODULE_NO_PAUSE) { }
exit $(if ($result.ok) { 0 } else { 1 })
