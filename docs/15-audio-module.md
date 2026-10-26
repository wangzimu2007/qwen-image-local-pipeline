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