# 音频脚本（本机适配版）

这 7 个脚本是**在作者本机跑通的版本**，路径按本机环境写死（`D:\audio-tools\`、
`D:\ComfyUI-aki-v3.2\python\python.exe`、`D:\ComfyUI\venv\...`）。
直接拿到别的机器上需要改路径，或参照 `scripts/lib/common.ps1` 的配置化做法重写。

放在这里的目的：**证明每条链路怎么接**，包括依赖隔离、模型路径、以及踩到的坑。

## 七个工具

| 脚本 | 功能 | 引擎 | 依赖目录 | 体积 |
|---|---|---|---|---|
| `分离音频.ps1` | 人声/伴奏分离 | Demucs v4 htdemucs_ft | `D:\audio-tools\demucs-pylibs` | 6.8 MB |
| `声音克隆.ps1` | 给参考声音，朗读任意文本（中/英/日…） | Chatterbox Multilingual | `chatterbox-pylibs` | 562 MB |
| `录音转字幕.ps1` | 音频/视频 → srt + txt + json | faster-whisper large-v3-turbo | `whisper-pylibs` + `hf-cache` | 691 MB + 1.6 GB 模型 |
| `说话人分离.ps1` | 多人对话分段 + 声纹 | sherpa-onnx pyannote + 3D-Speaker | `diarization-models` | 52 MB |
| `降噪增强.ps1` | 降噪 / 语音增强 | Resemble Enhance | `resemble-pylibs` + `resemble-model` | 556 MB + 680 MB |
| `音频超分.ps1` | 低采样率 → 48 kHz | AudioSR basic | `audiosr-pylibs` | 691 MB |
| `音频转MIDI.ps1` | 音轨 → MIDI | Basic Pitch（独立 py3.11 venv） | `basicpitch-venv` | 1.6 GB |

输出统一进 `桌面\音频\`（转录进 `桌面\音频\文字稿\`）。

## 安装方式（本机做法）

```powershell
# 所有 Python 依赖都用 --target 装进独立目录，绝不装进 ComfyUI 的 venv
$py = 'D:\ComfyUI-aki-v3.2\python\python.exe'
& $py -m pip install --target D:\audio-tools\whisper-pylibs faster-whisper -i https://pypi.tuna.tsinghua.edu.cn/simple

# Basic Pitch 需要 py3.11，单独 venv
python -m venv D:\audio-tools\basicpitch-venv
D:\audio-tools\basicpitch-venv\Scripts\pip install basic-pitch
```

运行时把目录加进 `PYTHONPATH`，或在脚本里 `sys.path.insert(0, ...)`。

## 四个必踩的坑（作者实测）

| 坑 | 现象 | 解法 |
|---|---|---|
| **ctranslate2 是 CUDA 12 构建** | `Library cublas64_12.dll is not found` | 把带 cu12 的 `torch\lib` 加进 `PATH`（本机用自建 venv 的 `D:\ComfyUI\venv\Lib\site-packages\torch\lib`）|
| **hf-mirror 不支持 Xet CAS** | 下载模型报 `401 Unauthorized ... cas-server.xethub.hf.co` | 设 `HF_HUB_DISABLE_XET=1`，回退普通 HTTP |
| **faster-whisper 内置解码与 PyAV 版本不符** | `open() got an unexpected keyword argument 'metadata_errors'` | 自己用 `av.AudioResampler` 解成 16 kHz 单声道 float32 数组，再喂模型 |
| **H3 生成的视频音频转出 0 段** | srt 为空 | 属正常：那是音效/环境声，VAD 判定无语音；语音素材要显式 `-Language zh` |

## 实测数据（RTX 5090 Laptop 24 GB）

| 任务 | 输入 | 耗时 |
|---|---|---|
| 转录 | 10 秒中文语音 | **2.6 秒**（GPU 热） / 16 秒（含首次加载） |
| 分离 | 10 秒音频 | **7.0 秒** |
| 超分 | 0.5 MB 低采样率 | 约 1 分钟 |
| 降噪增强 | 10 秒 | 数十秒量级 |

## 许可证提醒

各引擎许可不同，**商用前必查**：

- Demucs — MIT；faster-whisper — MIT（Whisper 权重 MIT）；Basic Pitch — Apache-2.0
- Chatterbox — MIT（Resemble AI）；pyannote / 3D-Speaker — MIT / Apache-2.0
- **AudioSR — MIT**
- **Resemble Enhance — 上游为 CC-BY-NC 4.0 类非商业许可，商用请自行确认**

本项目不授予任何模型权重权利，见仓库根目录 `NOTICE.md`。
