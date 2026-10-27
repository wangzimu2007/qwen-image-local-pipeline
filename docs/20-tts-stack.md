# 本地 TTS 栈实测与选型（2026-10-27）

## 结论

| 需求 | 用哪个 | 理由 |
|---|---|---|
| **克隆某人声音念台词** | **F5-TTS**（`F5克隆.ps1` / `音频模块 -Action clone`）| ASR 字错率 0.00，预热 RTF 0.65，比 Chatterbox 准得多也快得多 |
| **自然语言描述音色**（"低沉磁性中年男声"）| **Qwen3-TTS 1.7B VoiceDesign**（`语音设计.ps1`）| 唯一支持自由音色描述，CER 3.1% |
| **固定音色 + 风格指令，要快** | **Qwen3-TTS 0.6B CustomVoice**（`音频模块 -Action customvoice`，视频配音 `-Engine qwen-fast`）| CER 0~4.6%，预热 RTF 1.45（比 1.7B 快一倍）|
| **草稿/超快/不在意音质** | Kokoro（`-Action tts`）| RTF≈0.1，但中文 CER 78% |
| 其他语言 / 兜底 | CosyVoice2（`-Action tts-cosy`）| RTF 0.59，但中文质量差（见下）|

## 实测数据

| 引擎 | 权重/环境 | 冷启动 | 预热生成 | ASR 字错率 | 备注 |
|---|---|---|---|---|---|
| **F5-TTS v1.1.22** | `f5-venv` + `hf-cache` 中 `F5TTS_v1_Base`（约 1.35 GB）| 约 23 秒（含加载 7 秒）| 7.15 秒音频 **4.67 秒（RTF 0.65）** | **0.000（2/2 句满分）** | 零样本克隆，参考音频自动转写文案 |
| **Qwen3-TTS 0.6B CustomVoice** | `qwen3-tts\customvoice-0.6b`（2.33 GB）+ `tts-venv` | 加载 2.75 秒 | RTF **1.45** | 4.6% / 0%（两句）| 9 个固定音色（aiden/ryan/serena/uncle_fu…）|
| Qwen3-TTS 1.7B VoiceDesign | `qwen3-tts\voicedesign`（4.2 GB）| 加载约 7 秒 | RTF 2.9 | 3.1% | 音色描述最自由 |
| CosyVoice2-0.5B | `cosyvoice\venv2` | 约 35 秒 | RTF 0.59 | instruct2 **把指令念出来**；零样本 CER 41% | 中文不推荐当默认，留作兜底 |
| Chatterbox | `chatterbox-pylibs` | 约 60 秒/句 | 慢 | **59%** | 已从默认克隆降级（`-Engine chatterbox` 仍可用）|
| Kokoro | `音频工作台` | 秒级 | RTF≈0.1 | 78% | 草稿用 |

> 字错率算法：faster-whisper large-v3-turbo 回读 + 去标点后编辑距离，越小越准；0 表示完全听对。

## 关键修复

1. **F5 不能装进 tts-venv**：它会把 transformers 升到 5.x，破坏 Qwen3-TTS 的 4.57.3 锁定
   → 独立 `f5-venv`，从 tts-venv 复制 CUDA torch（2.11.0+cu128），其余依赖单独装
2. **F5/torchaudio 的 torchcodec 不兼容**：`_mod_f5_tts.py` 用 soundfile 读取并 monkeypatch `torchaudio.load`
3. **CosyVoice2 instruct2 缺陷**：0.5B 不支持，会把"用沉稳的中年男声…"当正文念出来
   → 改零样本 `inference_zero_shot`（参考音频文案自动转写）
4. **参考音频文案自动转写**：`_ref_asr.py`（faster-whisper），F5/CosyVoice 都复用

## 用法

```powershell
# 克隆（默认 F5，参考文案自动转写）
D:\audio-tools\音频模块.ps1 -Action clone -Input ref.wav -Params "Text=要读的台词" -Json

# 旧版 Chatterbox（对比/兜底）
D:\audio-tools\音频模块.ps1 -Action clone -Input ref.wav -Params "Text=...;Engine=chatterbox" -Json

# 固定音色（0.6B，快）
D:\audio-tools\音频模块.ps1 -Action customvoice -Params "Text=...;Speaker=uncle_fu;Instruct=沉稳男声" -Json

# 音色描述（1.7B，最自然）
D:\audio-tools\语音设计.ps1 -Text "..." -Instruct "低沉磁性的中年男声，语速偏慢"

# 视频配音换快速引擎
D:\audio-tools\视频配音提示词.ps1 -Video x.mp4 -Prompt "沉稳男声" -Mode auto -Engine qwen-fast -BurnSubtitles
```

## AudioSep（已装，见文末）

AudioSep 不在 PyPI，官方仓库在 GitHub；本机 `github.com` 与 `ghproxy`/`gitee` 镜像均不可达（连接重置），
**无法安装**。分离需求由已装的 **MelBand RoFormer**（`分离音频MR.ps1`，MDX 系）承担，质量比 Demucs 强。

## 环境占用

| 目录 | 大小 |
|---|---|
| `D:\audio-tools\f5-venv` | 约 1.2 GB（torch 复用自 tts-venv 的复制件）|
| `D:\audio-tools\qwen3-tts\customvoice-0.6b` | 2.33 GB |
| `D:\audio-tools\f5-venv` 权重缓存 | 在 `hf-cache\hub\models--SWivid--F5-TTS` |
## AudioSep（文本查询分离，2026-10-27 已装通）

**是什么**：Audio-AGI 的「语言查询音频分离」模型——用一句英文描述把目标声音从混合里抽出来，
例如 `speech`（人声）、`music`（音乐）、`singing voice`、`dog barking`、`rain`。
和 Demucs/MelBand 的区别：那两者只能按「人声/伴奏」固定两轨分；AudioSep 按**任意文字描述**分。

**怎么装上的**：`github.com` 网页/git 协议在本机被重置（`git clone` 不可用），但 `api.github.com` 通。
于是用 GitHub API 逐文件镜像了 91 个文件到 `D:\audio-tools\audiosep-src`，权重从 hf-mirror 下载
（`audo/AudioSep`：ckpt 1.21 GB + CLAP 2.24 GB），并建了独立 `audiosep-venv`（复制 tts-venv 的 CUDA torch）。

**实测（受控混合：F5 人声 + 伴奏，14.5 秒）**：

| 查询 | 语音相关度 | SI-SDR | 耗时 |
|---|---|---|---|
| `speech` | 0.991 | **17.6 dB** | 加载 3.5 秒 + 分离 1.8 秒 |
| `music` | 0.987 | **15.8 dB** | 加载 3.4 秒 + 分离 1.7 秒 |

**用法**：

```powershell
# 统一入口
D:\audio-tools\音频模块.ps1 -Action septext -Input mix.wav -Params "Query=speech" -Json

# 直接调用
D:\audio-tools\AudioSep分离.ps1 -Input mix.wav -Query "dog barking" -Out out.wav
```

**注意**：Query 用英文效果最好；中文描述支持有限（训练文本是英文 AudioSet/Music/Speech 标签）。