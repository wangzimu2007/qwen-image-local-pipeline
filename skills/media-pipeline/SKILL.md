---
name: media-pipeline
description: 媒体流水线skill（把多个本地工具串成一条命令）：按 JSON 配方自动跑「出图→超分→图生视频→超分定稿」「图生视频→字幕→烧字幕」「H3出片→转录→烧字幕」「音频分离→降噪→转录→MIDI」等多步流程，每步留日志与 manifest，支持 DryRun / Resume / 只跑部分步骤。Use for 流水线、一键串起来、批量跑一遍流程、出片带字幕、生成后自动后期、自动化流程 requests.
---

# 媒体流水线（配方 + 执行器）

把 40+ 个一次性脚本按 **JSON 配方**串起来跑，不用每次手敲多条命令。

- 执行器：`D:\qwen-image-2.1\流水线.ps1`
- 交互入口：`D:\qwen-image-2.1\流水线交互.ps1`（桌面快捷方式「流水线 - 运行」）
- 配方目录：`D:\qwen-image-2.1\recipes\*.json`
- 任务目录：`桌面\流水线\<配方名>-<时间戳>\`
- 每步留 `log.txt`，整任务留 `manifest.json`（参数/耗时/产物）

## 1. 现成配方

| 配方 | 步骤 | 适合 |
|---|---|---|
| **图生带字幕视频** | i2v → mksrt（按文案生成 srt）→ 烧字幕 | 一张图 + 一段文案 → 带字幕短片（**无声视频，字幕来自文案**）|
| **H3出片加字幕** | H3 文生视频 → 转录 → 烧字幕 | 要「有声音 + 字幕」的片子 |
| **图片全链路** | Z-Image 出图 → PiD 4× → 图生视频 → AI 超分 720p | 从一句话到 720p 成片 |
| **音频处理链** | 分离 → 降噪 → 转录 → 转 MIDI | 处理一首歌/一段录音 |

## 2. 命令

```powershell
# 直接跑（会真执行，耗时按配方）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\qwen-image-2.1\流水线.ps1 `
  -Recipe "图生带字幕视频" `
  -Set "Image=C:\path\a.png;Text=第一句。第二句。;Seconds=5"

# 先看会执行什么（不跑）
... -Recipe "图生带字幕视频" -Set "Image=..." -DryRun

# 只跑其中几步
... -Recipe "音频处理链" -Set "Audio=x.wav" -Only "denoise,subtitle"

# 断点续跑（跳过 manifest 里已完成的步骤）
... -Recipe "音频处理链" -Set "Audio=x.wav" -Out my-task -Resume
```

参数说明：

| 参数 | 说明 |
|---|---|
| `-Recipe` | 配方名（不含 .json）或完整路径 |
| `-Set` | `key=value` 覆盖配方变量，**多条用分号**；支持 `{{变量}}` 占位 |
| `-Only` | 逗号分隔的步骤 id，只跑这些 |
| `-Out` | 任务目录名（默认 配方名-时间戳）|
| `-DryRun` | 只打印每步命令 |
| `-Resume` | 跳过已完成步骤 |

## 3. 变量与产物引用

配方里用 `{{VarName}}` 引用变量，用 `{{out.<步骤id>}}` 引用**上一步产物路径**（执行器从脚本输出的「成品：路径」里抓）。

```json
{ "id": "up4x", "tool": "img-pid", "params": { "Image": "{{out.t2i}}" } }
```

## 4. 可用工具名（配方的 tool 字段）

图片：`img-t2i`（Qwen Turbo）、`img-zimage`、`img-moss`、`img-pixeldit`、`img-ops`（修图）、`img-inpaint`（局部重绘）、`img-upscale`（SeedVR2）、`img-pid`（PiD 4×）
视频：`video-i2v`、`video-h3`、`video-extend`、`video-join`、`video-post`、`video-upscale`（SeedVR2）、`video-flashvsr`
音频：`audio-split`、`audio-clone`、`audio-denoise`、`audio-sr`、`audio-diarize`、`audio-midi`、`audio-subtitle`

另支持 `shell` 步骤（写 PowerShell 片段），用于 ffmpeg 之类的原生命令。

## 5. 写新配方

在 `recipes\` 放一个 JSON：

```json
{
  "name": "我的配方",
  "description": "说明",
  "vars": { "Prompt": "默认提示词", "Seconds": 5 },
  "steps": [
    { "id": "t2i", "tool": "img-zimage", "params": { "Prompt": "{{Prompt}}", "Width": 832, "Height": 1216, "Steps": 8 } },
    { "id": "i2v", "tool": "video-i2v", "params": { "Image": "{{out.t2i}}", "Seconds": "{{Seconds}}" } }
  ]
}
```

要点：
- 参数值写字符串，布尔开关写成 `"true"` 或直接省略
- `shell` 步骤会被写成临时 `run.ps1` 再执行（**不要**直接拼 `-Command`，引号会崩）
- 需要新工具时，在 `流水线.ps1` 顶部的 `$tools` 注册表加一行

## 6. 关键约束（实测）

| 约束 | 说明 |
|---|---|
| **脚本必须打印「成品：路径」** | 执行器靠这行抓产物；没有就传 `output` 字段兜底 |
| **Wan 图生视频是无声的** | 想给它配字幕要用「文案生成 srt」（`_mksrt.py`），不能靠转录 |
| **H3 是唯一能出声的视频路线** | 要音画同步 → `H3出片加字幕` |
| **烧字幕要 ffmpeg** | 已装 `D:\tools\ffmpeg\bin`（9.0.2）并加入用户 PATH |
| **显存互斥由各脚本自己处理** | 每个子脚本都带显存快照，流水线不重复做 |

## 7. 实测

| 流程 | 耗时 |
|---|---|
| 音频处理链（只跑 denoise + subtitle） | **10.6 秒**（降噪 7.0 + 转录 3.2）|
| Resume 跳过已完成步骤 | ✅ 正确跳过 |
| DryRun 打印全部命令 | ✅ |

## 8. 相关

- 单步工具：`text-to-image` / `image-to-video` / `text-to-video-h3` / `video-edit` / `video-upscale` / `audio-processing`
- 显存会话模式：`会话-开始.ps1` / `会话-结束.ps1`（批量跑时减少换入换出）
