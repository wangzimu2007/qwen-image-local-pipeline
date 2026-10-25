---
name: audio-processing
description: 音频处理skill（本地 GPU 全套）：人声分离 / 声音克隆配音 / 说话人分离 / 降噪增强 / 音频超分 / 音频转 MIDI / 录音转字幕。7 个脚本都在 D:\audio-tools，双击桌面「本地AI快捷方式」里的「音频* - 一次性」也能跑。Use for 分离人声、去人声、伴奏、克隆声音、配音、谁在说话、会议分人、降噪、变清晰、音频修复、音频超分、转 MIDI、转录、字幕、srt requests.
---

# 音频处理skill（本地 GPU，7 个工具）

全部在 `D:\audio-tools\`，输出统一进 `C:\Users\wangzimu\Desktop\音频\`（转录进 `音频\文字稿\`）。
桌面「本地AI快捷方式」里有对应的 `音频* - 一次性` 快捷方式。

## 1. 一句话 → 用哪个

| 用户说 | 脚本 | 说明 | 实测 |
|---|---|---|---|
| **把人声/伴奏分开**、去人声、卡拉OK | `分离音频.ps1 -Audio x.mp3` | Demucs v4 htdemucs_ft，出 人声/伴奏 | 5 秒歌约 30 秒 |
| **用我的声音念这段**、克隆配音 | `声音克隆.ps1 -Reference ref.wav -Text "..."` | Chatterbox Multilingual（支持中文） | 10 秒音频约 20 秒 |
| **谁在说话 / 会议分人** | `说话人分离.ps1 -Audio x.wav` | pyannote 分段 + 3D-Speaker 声纹 | 适合 2 人对话 |
| **降噪 / 去混响 / 声音更清楚** | `降噪增强.ps1 -Audio x.wav [-Enhance]` | Resemble Enhance（GPU） | `-Enhance` 更慢、可能改音色 |
| **低采样率修复**、电话音质提升 | `音频超分.ps1 -Audio x.wav [-Steps 50]` | AudioSR → 48 kHz | 0.5 MB 样本约 1 分钟 |
| **转 MIDI**、扒谱 | `音频转MIDI.ps1 -Audio x.mp3` | Basic Pitch（独立 py3.11 环境） | — |
| **转字幕 / 转录 / srt** | `录音转字幕.ps1 -Audio x.wav` 或 `-Video x.mp4` | faster-whisper large-v3-turbo，GPU | 10 秒语音 **2.6 秒** |

## 2. 常用命令

```powershell
# 分离人声（输出到桌面\音频）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\audio-tools\分离音频.ps1 -Audio "C:\path\song.mp3"

# 克隆配音（参考音色 5~15 秒最佳）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\audio-tools\声音克隆.ps1 -Reference "ref.wav" -Text "要读的内容" -Language zh

# 视频转字幕（自动抽音轨）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\audio-tools\录音转字幕.ps1 -Video "C:\path\clip.mp4"

# 音频转字幕（指定中文、只出 srt）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\audio-tools\录音转字幕.ps1 -Audio "a.wav" -Language zh -Formats srt

# 降噪 + 语音增强
powershell -NoProfile -ExecutionPolicy Bypass -File D:\audio-tools\降噪增强.ps1 -Audio "noisy.wav" -Enhance

# 音频超分到 48kHz
powershell -NoProfile -ExecutionPolicy Bypass -File D:\audio-tools\音频超分.ps1 -Audio "low.wav"
```

## 3. 参数速查

**录音转字幕.ps1**（我写的那个）
- `-Audio` 或 `-Video`（二选一，Video 自动抽音轨）
- `-Model`：默认 `large-v3-turbo`；可选 `small`/`medium`/`large-v3`
- `-Language`：默认 `auto`；中文建议显式 `zh`（更稳）
- `-Formats`：默认 `srt,txt,json`
- `-Device`：默认 `cuda`；GPU 出问题改 `cpu`（配 `-ComputeType int8`）
- 输出：`桌面\音频\文字稿\<原名>-<时间>.{srt,txt,json}`

**声音克隆.ps1**：`-Reference`（必填）/ `-Text`（必填）/ `-Language zh|en|ja...` / `-Exaggeration 0.5` / `-CfgWeight 0.5`

**降噪增强.ps1**：`-Audio`（必填）/ `-Enhance`（开关：生成式增强，更慢）

**音频超分.ps1**：`-Audio`（必填）/ `-Steps`（默认 50，越大越慢）

## 4. 踩过的坑（改脚本前先看）

| 坑 | 现象 | 解法 |
|---|---|---|
| **ctranslate2 要 CUDA 12** | `Library cublas64_12.dll is not found` | 脚本已把 `D:\ComfyUI\venv\Lib\site-packages\torch\lib` 加进 PATH |
| **hf-mirror 不支持 Xet** | 下载报 401 `cas-server.xethub.hf.co` | 设 `HF_HUB_DISABLE_XET=1`（脚本已设）|
| **faster-whisper 内置解码与 PyAV 版本不符** | `open() got an unexpected keyword argument 'metadata_errors'` | 脚本自己用 `av.AudioResampler` 解成 16k 单声道数组再喂模型 |
| **纯音效视频转出 0 段** | srt 为空 | 属正常（VAD 认为没语音）；语音素材显式 `-Language zh` |
| **依赖装进 ComfyUI venv 会污染出图环境** | 出图报错 | 一律 `pip install --target D:\audio-tools\*-pylibs` + `PYTHONPATH` |

## 5. 依赖位置（别乱动）

| 工具 | 依赖目录 |
|---|---|
| 转录 | `D:\audio-tools\whisper-pylibs`（faster-whisper 1.2.1）+ 模型 `D:\audio-tools\hf-cache` |
| 分离 | `D:\audio-tools\demucs-pylibs` |
| 克隆 | `D:\audio-tools\chatterbox-pylibs` |
| 降噪 | `D:\audio-tools\resemble-pylibs` + `resemble-model` |
| 超分 | `D:\audio-tools\audiosr-pylibs` |
| MIDI | `D:\audio-tools\basicpitch-venv`（独立 py3.11）|
| 说话人 | `D:\audio-tools\diarization-models` |

## 6. 交付时报告

按项目惯例输出：**成品路径 / 参数 / 耗时 / 评价**。字幕类额外给出前 3 行内容，音频类给出时长与采样率。

## 7. 相关

- 视频（带音频）生成：`text-to-video-h3` skill（H3 唯一能出声）
- 视频后期：`video-edit` / `video-upscale` skill
- 图片：`text-to-image` skill
