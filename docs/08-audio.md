# 音频处理：7 个本地工具

> 全部本地 GPU 推理，不联网（模型下载除外）。脚本在 `scripts/audio/`，本机在 `D:\audio-tools\`。
> 输出统一进 `桌面\音频\`（转录进 `桌面\音频\文字稿\`）。

## 1. 一张表选工具

| 你要做的事 | 工具 | 一句话命令 |
|---|---|---|
| 拆人声/伴奏、K 歌伴奏 | Demucs | `分离音频.ps1 -Audio song.mp3` |
| 用我的声音念这段 | Chatterbox | `声音克隆.ps1 -Reference ref.wav -Text "..."` |
| 会议谁在说话 | pyannote + 3D-Speaker | `说话人分离.ps1 -Audio meeting.wav` |
| 降噪 / 去混响 / 人声更清楚 | Resemble Enhance | `降噪增强.ps1 -Audio noisy.wav -Enhance` |
| 低采样率修复 → 48 kHz | AudioSR | `音频超分.ps1 -Audio low.wav` |
| 扒谱 / 转 MIDI | Basic Pitch | `音频转MIDI.ps1 -Audio song.mp3` |
| 转字幕 / 转录 | faster-whisper | `录音转字幕.ps1 -Video clip.mp4` |

## 2. 实测速度（RTX 5090 Laptop 24 GB）

| 任务 | 输入 | 耗时 | 备注 |
|---|---|---|---|
| 转录 large-v3-turbo | 10 秒中文语音 | **2.6 秒** | GPU float16，首次含 1.8 秒模型加载 |
| 人声分离 Demucs v4 ft | 10 秒音频 | **7.0 秒** | 输出 2 个 stem |
| 音频超分 AudioSR | 0.5 MB | ~1 分钟 | 50 步 |
| 降噪增强 Resemble | 10 秒 | 数十秒 | `-Enhance` 更慢但更干净 |

## 3. 转字幕脚本参数（`录音转字幕.ps1`）

```powershell
# 视频转字幕（自动抽音轨）
录音转字幕.ps1 -Video clip.mp4

# 音频转字幕，指定中文，只要 srt
录音转字幕.ps1 -Audio a.wav -Language zh -Formats srt

# 大模型更准但慢；GPU 出问题退回 CPU
录音转字幕.ps1 -Audio a.wav -Model large-v3
录音转字幕.ps1 -Audio a.wav -Device cpu -ComputeType int8
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Audio` / `-Video` | — | 二选一，Video 自动抽音轨 |
| `-Model` | `large-v3-turbo` | `tiny`/`small`/`medium`/`large-v3` |
| `-Language` | `auto` | 中文建议显式 `zh` |
| `-Formats` | `srt,txt,json` | 逗号分隔 |
| `-Device` | `cuda` | GPU 报错时改 `cpu` |
| `-ComputeType` | `float16` | cpu 用 `int8` |

输出：`桌面\音频\文字稿\<原名>-<yyyyMMdd-HHmmss>.srt/.txt/.json`

## 4. 四个坑（照着躲）

### 4.1 ctranslate2 需要 CUDA 12，而 ComfyUI 环境常是 CUDA 13

```
RuntimeError: Library cublas64_12.dll is not found or cannot be loaded
```

解法：把带 cu12 的 `torch\lib` 加进 `PATH`：

```powershell
$env:PATH = 'D:\ComfyUI\venv\Lib\site-packages\torch\lib;' + $env:PATH
```

### 4.2 hf-mirror 不支持 Xet CAS

```
RuntimeError: ... HTTP status client error (401 Unauthorized), domain: https://cas-server.xethub.hf.co
```

解法：`$env:HF_HUB_DISABLE_XET = '1'`（回退普通 HTTP 下载）。

### 4.3 faster-whisper 内置解码与 PyAV 版本不符

```
TypeError: open() got an unexpected keyword argument 'metadata_errors'
```

解法：不用它的 `decode_audio`，自己解码后传数组：

```python
rs = av.AudioResampler(format="s16", layout="mono", rate=16000)
chunks = [f.to_ndarray() for frame in c.decode(st) for f in rs.resample(frame)]
samples = np.concatenate([x.reshape(-1) for x in chunks]).astype(np.float32) / 32768.0
model.transcribe(samples, ...)
```

### 4.4 纯音效视频转出 0 段

H3 / Wan 生成的视频音轨往往是环境声、音效，VAD 会判定"没有语音"→ 0 段是正确行为。
语音素材请显式指定 `-Language zh`。

## 5. 依赖隔离原则

**永远不要**把音频依赖装进 ComfyUI 的 venv（会升级 torch / numpy，直接把出图环境搞坏）。
本项目一律：

```powershell
pip install --target D:\audio-tools\<tool>-pylibs <package>
# 运行时
$env:PYTHONPATH = 'D:\audio-tools\<tool>-pylibs'
```

## 6. 和视频流程怎么接

```
H3 生成带音频视频 → 录音转字幕（出 srt）→ 需要改声音就 声音克隆 配音
                                        → 需要伴奏就 分离音频
                                        → 音质差就 降噪增强 / 音频超分
```

## 7. 许可证

Demucs / faster-whisper / Whisper 权重 / Basic Pitch / Chatterbox / pyannote 多为 MIT 或
Apache-2.0；**Resemble Enhance 上游为非商业类许可**，商用前务必确认。详见 `NOTICE.md`。
