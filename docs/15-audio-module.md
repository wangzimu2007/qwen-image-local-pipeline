# 音频模块 ↔ 视频/图像工作流集成（2026-10-26）

## 目标

1. 音频模块**单独可用**（直接命令行 / 快捷方式）
2. 视频、图像工作流可通过**同一入口**调用（`流水线.ps1` 的 `audio-mod` / `image-dub` / `video-dub` 步骤）
3. 音频侧以后单独封装成模块时，**只改 `audio-module.json` 的 script 路径**，调用方不用动

## 统一入口

```powershell
D:\audio-tools\音频模块.ps1 -Action <动作> [-Input <文件>] [-Out <目录>] [-Params "k=v;k2=v2"] [-Json]
```

动作：`split` `splitmr` `denoise` `enhance` `transcribe` `diarize` `clone` `tts` `sr` `midi`
`master` `align` `lipsync` `dubprompt` `dub` `sfx` `mix` `probe`

输出约定：

- 人读：`音频完成：<路径>` / `视频完成：<路径>`（流水线据此串联下一步）
- 机器：`-Json` 输出 `{ok, action, files[], seconds, durationSec?, log, error}`

## 换模块的方式

`D:\audio-tools\audio-module.json` 里 `actions.<动作>.script` 指向实现脚本。
音频侧封装好后，把路径改到新模块即可，入口、配方、流水线都不用改。

## 已接入的配方

| 配方 | 链路 | 参数 |
|---|---|---|
| `video-dub.json` | 视频 → 视觉理解 → 旁白 → 配音 → 字幕 → 封装 | Video、Prompt、Mode |
| `video-sfx.json` | 文生音效/BGM → 混进视频 | Video、Prompt、Seconds、Volume |
| `image-dub.json` | 图片 → 视觉理解 → 旁白 → TTS → 静图视频（可烧字幕） | Image、Prompt、Seconds |
| `audio-chain.json` | 分离 → 降噪 → 字幕 → MIDI | Audio |

```powershell
D:\qwen-image-2.1\流水线.ps1 -Recipe D:\qwen-image-local-pipeline\recipes\video-sfx.json `
  -Set "Video=C:\...\a.mp4;Prompt=雨夜街道环境音"
```

## 流水线步骤映射

`流水线.ps1` 步骤表新增：`video-dub` / `video-lipsync` / `image-dub` / `audio-mod`。
产品标签解析已扩宽为 `成品 / 视频完成 / 音频完成 / 输出文件 / 结果文件 / 输出`，取最后一条。

## 当前已知限制

- `sfx` 依赖 `_install_extras.ps1` 装好的 gen-venv（Stable Audio Open 或 AudioLD2M）
- `tts` 依赖音频工作台 `desktop_backend.tts`（Kokoro）
- 配音时长与视频时长不一致时只在 `manifest.json` 的 `duration_fit` 里告警，不自动变速

## 2026-10-27 次轮验收（实测）

| 链路 | 结果 | 耗时 | 产物 |
|---|---|---|---|
| 视频配音 prompt | ✅ | 22.2 秒 | frames + vision.json + 配音提示词.txt |
| 视频配音 auto（Kokoro+字幕+封装）| ✅ | 41.1 秒 | video-0041-promptdub-*.mp4 |
| 流水线 video-dub | ✅ | 30.8 秒 | 产物路径正确（mp4）|
| 流水线 image-dub | ✅ | 21.2 秒 | video-0049-imgdub-*.mp4 |
| 流水线 video-sfx | ✅ | 14.7 秒 | sfx wav + mixed mp4 |
| 音效生成（AudioLDM2）| ✅ | 29.8 秒/8 秒音频 | sfx-*.wav |
| 字幕对齐 | ✅ | 约 1 秒 | .srt |

### 本轮修掉的 bug

| # | 问题 | 根因 | 修法 |
|---|---|---|---|
| 1 | 配音卡 600 秒超时 | `qwen3.5:9b` 默认思考 | `think:false` + `num_predict`（两个配音脚本 + 工作台 `_ollama_chat`）|
| 2 | 流水线执行到一半停住 | 我改产品解析时留下孤立 `elseif` | 改为 `if (-not $prod -and $step.output)` |
| 3 | 产物路径取错 | 中文标签在管道里被 GBK 解码成乱码 | 脚本额外打印 ASCII `RESULT=<路径>`，流水线优先解析 |
| 4 | 产物取到 SRT 而非成片 | 多条 RESULT 取最后一条 | 优先取 `.mp4/.mov` |
| 5 | 图像配音失败 | 重复 `-vf` + 中文字幕路径 ffmpeg 不认 | 合并单个 vf；字幕复制到 ASCII 临时路径再烧 |
| 6 | 音效无权重 | Stable Audio Open 是 gated(403) | 改 AudioLDM2（8.5 GB，diffusers 0.31 + transformers 4.44）|

### 仍未装成

- **F5-TTS**：未装（`f5_tts` 包缺依赖）；如需更自然中文 TTS 再单独装
- **AudioSep / RVC**：安装失败（AudioSep 需项目结构；RVC 与 Py3.12 兼容差）
- Stable Audio Open：HF gated，本地无 HF token，无法合法下载