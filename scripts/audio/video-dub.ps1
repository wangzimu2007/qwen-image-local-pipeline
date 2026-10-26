param(
    [Parameter(Mandatory=$true)][string]$Video,
    [string]$Prompt = '',
    [ValidateSet('prompt','auto')][string]$Mode = 'prompt',
    [string]$Reference = '',
    [string]$Language = 'zh',
    [switch]$BurnSubtitles,
    [double]$Pitch = 0,
    [ValidateSet('preserved','shifted')][string]$Formant = 'preserved',
    [ValidateSet('original','bright','warm')][string]$Tone = 'original',
    [ValidateSet('auto','kokoro','chatterbox','cosyvoice','seedvc','cosyvoice+seedvc','qwen')][string]$Engine = 'auto',
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
$py = 'D:\audio-tools\qt-venv\Scripts\python.exe'
$helper = 'D:\audio-tools\video_dub_prompt.py'
if (-not (Test-Path $py)) { throw "缺少 Python：$py" }
if (-not (Test-Path $helper)) { throw "缺少脚本：$helper" }
$cliArgs = @($helper, '--video', $Video, '--mode', $Mode, '--language', $Language,
          '--pitch', $Pitch, '--formant', $Formant, '--tone', $Tone, '--engine', $Engine)
if ($Prompt) { $cliArgs += @('--prompt', $Prompt) }
if ($Reference) { $cliArgs += @('--reference', $Reference) }
if ($BurnSubtitles) { $cliArgs += '--burn-subtitles' }
& $py @cliArgs
if ($LASTEXITCODE -ne 0) { throw "视频配音提示词失败，退出码 $LASTEXITCODE" }
if (-not $NoPause) { Start-Sleep -Seconds 2 }
exit 0
