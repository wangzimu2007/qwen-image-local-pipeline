# 录音转字幕：faster-whisper（本地 GPU，中文优先）
#
# 用法：
#   .\录音转字幕.ps1 -Audio "C:\path\a.wav"
#   .\录音转字幕.ps1 -Video "C:\path\clip.mp4"          # 自动抽音轨
#   .\录音转字幕.ps1 -Audio a.wav -Model large-v3 -Language zh
#   .\录音转字幕.ps1 -Audio a.wav -Formats "srt,txt"
#
# 模型：默认 large-v3-turbo（快、准），可换 small / medium / large-v3
# 输出：桌面\音频\文字稿\<名字>-<时间>.srt / .txt / .json
param(
    [string]$Audio = '',
    [string]$Video = '',
    [string]$Model = 'large-v3-turbo',
    [string]$Language = 'auto',          # auto / zh / en / ja ...
    [string]$Formats = 'srt,txt,json',
    [string]$Device = 'cuda',            # cuda / cpu
    [string]$ComputeType = 'float16',    # cuda 用 float16，cpu 用 int8
    [string]$OutDir = '',
    [switch]$NoOpen,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$py = 'D:\ComfyUI-aki-v3.2\python\python.exe'
$libs = 'D:\audio-tools\whisper-pylibs'
$hfCache = 'D:\audio-tools\hf-cache'
if (-not $OutDir) {
    $OutDir = Join-Path ([Environment]::GetFolderPath('Desktop')) '音频\文字稿'
}
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

function Write-H { param([string]$t) Write-Host ''; Write-Host ("== " + $t + " ==") -ForegroundColor Cyan }
function Write-Ok { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Green }
function Write-In { param([string]$t) Write-Host ("  " + $t) -ForegroundColor DarkGray }
function Write-WarnP { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Yellow }

Write-H '录音转字幕（faster-whisper）'

if (-not $Audio -and -not $Video) {
    Write-Host '  ✗ 需要 -Audio 或 -Video' -ForegroundColor Red
    if (-not $NoPause) { Start-Sleep -Seconds 5 }
    exit 1
}
if (-not (Test-Path $libs)) {
    Write-Host ('  ✗ 缺少依赖目录：' + $libs) -ForegroundColor Red
    Write-Host '    装法：D:\ComfyUI-aki-v3.2\python\python.exe -m pip install --target D:\audio-tools\whisper-pylibs faster-whisper' -ForegroundColor DarkGray
    if (-not $NoPause) { Start-Sleep -Seconds 8 }
    exit 1
}

# ---- 准备输入：视频则抽音轨 ----
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('whisper-in-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$finalAudio = ''
$srcName = ''
if ($Video) {
    if (-not (Test-Path $Video)) { Write-Host ('  ✗ 找不到视频：' + $Video) -ForegroundColor Red; exit 1 }
    Write-In '抽取音轨…'
    $exScript = Join-Path $work 'extract.py'
    $exCode = @'
import sys, av
src, dst = sys.argv[1], sys.argv[2]
c = av.open(src)
if not c.streams.audio:
    print("NO_AUDIO"); sys.exit(2)
st = c.streams.audio[0]
out = av.open(dst, 'w')
ost = out.add_stream('pcm_s16le', rate=st.rate or 16000)
ost.rate = st.rate or 16000
for frame in c.decode(st):
    for p in ost.encode(frame):
        out.mux(p)
for p in ost.encode(None):
    out.mux(p)
out.close(); c.close()
print("OK")
'@
    [System.IO.File]::WriteAllText($exScript, $exCode, (New-Object System.Text.UTF8Encoding($false)))
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $env:PYTHONIOENCODING = 'utf-8'
    $r = & $py $exScript $Video (Join-Path $work 'extracted.wav') 2>&1
    $ErrorActionPreference = $prevEap
    if (($r -join ' ') -notmatch 'OK') {
        Write-Host ('  ✗ 抽音轨失败：' + ($r -join ' ')) -ForegroundColor Red
        exit 1
    }
    $finalAudio = Join-Path $work 'extracted.wav'
    $srcName = [System.IO.Path]::GetFileNameWithoutExtension($Video)
} else {
    if (-not (Test-Path $Audio)) { Write-Host ('  ✗ 找不到音频：' + $Audio) -ForegroundColor Red; exit 1 }
    $finalAudio = $Audio
    $srcName = [System.IO.Path]::GetFileNameWithoutExtension($Audio)
}
Write-In ('输入：' + (Split-Path $finalAudio -Leaf))

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$base = Join-Path $OutDir ($srcName + '-' + $stamp)

# ---- 跑转录 ----
Write-H '开始转录'
Write-In ("模型 {0} / 语言 {1} / {2} {3}" -f $Model, $Language, $Device, $ComputeType)
$script = Join-Path $work 'transcribe.py'
$code = @'
import sys, json, time, os
sys.path.insert(0, r"D:\audio-tools\whisper-pylibs")
import av
import numpy as np
from faster_whisper import WhisperModel

def decode_16k_mono(path):
    """自己解码成 16k 单声道 float32，绕开 faster-whisper 内置 av 接口的版本不兼容"""
    c = av.open(path)
    st = c.streams.audio[0]
    rs = av.AudioResampler(format="s16", layout="mono", rate=16000)
    chunks = []
    for frame in c.decode(st):
        for f in rs.resample(frame):
            chunks.append(f.to_ndarray())
    for f in rs.resample(None):
        chunks.append(f.to_ndarray())
    c.close()
    if not chunks:
        raise RuntimeError("解码得到 0 个采样块")
    return np.concatenate([x.reshape(-1) for x in chunks]).astype(np.float32) / 32768.0

audio, model_name, lang, base, formats = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
device, compute_type = sys.argv[6], sys.argv[7]
lang_arg = None if lang == "auto" else lang

t0 = time.time()
model = WhisperModel(model_name, device=device, compute_type=compute_type,
                     download_root=r"D:\audio-tools\hf-cache")
print("  模型加载 %.1fs" % (time.time() - t0), flush=True)

t1 = time.time()
samples = decode_16k_mono(audio)
print("  解码 %.1fs  %.2f 秒音频" % (time.time() - t1, len(samples) / 16000), flush=True)

segments, info = model.transcribe(samples, language=lang_arg, beam_size=5,
                                  vad_filter=True, vad_parameters={"min_silence_duration_ms": 400})
print("  检测语言: %s (概率 %.2f)  时长 %.1fs" % (info.language, info.language_probability, info.duration), flush=True)

def fmt(t):
    h = int(t // 3600); m = int((t % 3600) // 60); s = t % 60
    return "%02d:%02d:%06.3f" % (h, m, s)

lines = []
segs = []
n = 0
for seg in segments:
    n += 1
    text = seg.text.strip()
    segs.append({"start": round(seg.start, 3), "end": round(seg.end, 3), "text": text})
    lines.append("%d" % n)
    lines.append("%s --> %s" % (fmt(seg.start).replace(".", ","), fmt(seg.end).replace(".", ",")))
    lines.append(text)
    lines.append("")
    print("  [%s] %s" % (fmt(seg.start), text[:60]), flush=True)

want = [f.strip().lower() for f in formats.split(",")]
if "srt" in want:
    open(base + ".srt", "w", encoding="utf-8").write("\n".join(lines))
if "txt" in want:
    open(base + ".txt", "w", encoding="utf-8").write("\n".join(s["text"] for s in segs))
if "json" in want:
    json.dump({"language": info.language, "duration": info.duration, "segments": segs},
              open(base + ".json", "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print("  完成 %d 段，用时 %.1fs" % (n, time.time() - t0), flush=True)
print("BASE=" + base, flush=True)
'@
[System.IO.File]::WriteAllText($script, $code, (New-Object System.Text.UTF8Encoding($false)))

$env:PYTHONPATH = $libs
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
# ctranslate2 是 CUDA12 构建；本机秋叶环境是 CUDA13，需要借用自建 venv 里的 cu12 库
$cuda12LibDir = 'D:\ComfyUI\venv\Lib\site-packages\torch\lib'
if ($Device -eq 'cuda' -and (Test-Path $cuda12LibDir)) {
    if ($env:PATH -notlike ('*' + $cuda12LibDir + '*')) { $env:PATH = $cuda12LibDir + ';' + $env:PATH }
    Write-In ('CUDA12 库: ' + $cuda12LibDir)
}

$env:HF_ENDPOINT = 'https://hf-mirror.com'
$env:HF_HUB_DISABLE_XET = '1'                 # 镜像不支持 xet CAS，必须关掉走普通 HTTP
$env:HF_HUB_DISABLE_SYMLINKS_WARNING = '1'    # 非管理员无符号链接权限，警告没用
$env:HF_HOME = $hfCache
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$sw = [Diagnostics.Stopwatch]::StartNew()
& $py $script $finalAudio $Model $Language $base $Formats $Device $ComputeType 2>&1 | ForEach-Object { '  ' + ([string]$_) }
$sw.Stop()
$ErrorActionPreference = $prevEap

$produced = Get-ChildItem $OutDir -Filter ($srcName + '-' + $stamp + '.*') -ErrorAction SilentlyContinue
if (-not $produced) {
    Write-Host '  ✗ 没有产出文件' -ForegroundColor Red
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $NoPause) { Start-Sleep -Seconds 8 }
    exit 1
}

Write-H '结果'
if ($srt -and (Get-Item $srt.FullName).Length -lt 20) {
    Write-WarnP '没检测到语音（纯音乐/音效/VAD 过滤掉了），可以试 -Language zh 或换 small 模型'
}
Write-Ok ("用时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds)
$produced | Sort-Object Name | ForEach-Object { '  {0,-64} {1,7:N1} KB' -f $_.Name, ($_.Length/1KB) }
$srt = $produced | Where-Object { $_.Extension -eq '.srt' } | Select-Object -First 1
if ($srt) {
    Write-In '前 8 行字幕：'
    Get-Content $srt.FullName -TotalCount 8 -Encoding UTF8 | ForEach-Object { '    ' + $_ }
}
Write-In ('输出目录：' + $OutDir)

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if (-not $NoOpen) { Start-Process $produced[0].FullName }
if (-not $NoPause) { Write-Host ''; Write-Host '窗口将在 10 秒后关闭…' -ForegroundColor DarkGray; Start-Sleep -Seconds 10 }
exit 0
