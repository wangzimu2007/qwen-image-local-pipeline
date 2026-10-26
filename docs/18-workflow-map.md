# 三大工作流总览与打通方式（2026-10-27）

## 一句话

**图片/视频线**、**音频线**、以及**两者打通（先出片再补声）** 现在都有“本地模型前端 + 统一入口 + 流水线配方”；
游戏/网页角色语音走 `游戏语音采集` 采集台。

---

## 一、图片 / 视频工作流（本地模型在前）

```
[一句话要求]
   │  提示词扩写.ps1 -Kind image|video      ← 本地 qwen3.5:9b
   ▼
[扩写后的提示词]
   ├─ 出图：提交作业.ps1 / 画图.ps1 / Z画图.ps1 / MOSS画图.ps1 / PixelDiT / Krea2 / 编辑.ps1 -RefImage
   ├─ 修图：修图.ps1（裁剪/缩放/调色/水印 0.2 秒）、局部重绘.ps1（框选重绘）、图片超分 / PiD超分
   ├─ 换衣：编辑.ps1 -Image A -RefImage B（两图换衣，可双向互换）
   ├─ 换脸：换脸.ps1（图片 3 秒 / 视频 0.22 秒每帧）
   └─ 视频：图生视频.ps1（Wan 2.2）、文本生视频H3快照.ps1（带声音）、续接/拼接/后期/超分/插帧
```

**流水线配方**：`图片全链路`、`图生带字幕视频`、`H3出片加字幕`。

## 二、音频工作流（本地模型在前）

```
[一句话要求]
   │  提示词扩写.ps1 -Kind audio|sfx|voice    ← 本地 qwen3.5:9b
   ▼
[声音设计提示词]
   ├─ 音效/BGM：音频模块.ps1 -Action sfx     ← AudioLDM2（8.5 GB，RTF≈0.4）
   ├─ 配音：音频模块.ps1 -Action voicedesign ← Qwen3-TTS VoiceDesign（RTF≈2.9，ASR 字错率 3.1%）
   │        音频模块.ps1 -Action tts         ← Kokoro（快，草稿用）
   │        声音克隆.ps1 / SeedVC变声.ps1 / CosyVoice2配音.ps1
   ├─ 处理：分离音频 / 降噪DFN / 降噪增强 / 音频超分 / 母带匹配 / 字幕对齐 / 说话人分离 / 录音转字幕 / 音频转MIDI
   └─ 口型：口型同步.ps1（MuseTalk）
```

**流水线配方**：`音频处理链`、`声音设计补音效`（扩写→音效→混入视频）。

## 三、视频 ↔ 音频打通

### 方式 A：先出视频，再补旁白（推荐）

```powershell
# 一步到位：本地模型写运动提示词 → 图生视频 → 视觉理解 → 旁白 → 配音 → 字幕 → 封装
流水线.ps1 -Recipe 图生视频配旁白 -Set "Image=图.png;Text=让木船慢慢漂;Seconds=4;Engine=kokoro"
```

### 方式 B：已有视频，按画面补旁白

```powershell
视频配音提示词.ps1 -Video x.mp4 -Prompt "低沉男声，纪录片旁白" -Mode auto -Engine qwen -BurnSubtitles
```

### 方式 C：已有视频，补环境音/配乐

```powershell
流水线.ps1 -Recipe 声音设计补音效 -Set "Video=x.mp4;Text=雨夜街道环境音;Seconds=6;Volume=0.6"
```

### 方式 D：配音后对口型

```powershell
口型同步.ps1 -Video 视频.mp4 -Audio 配音.wav
```

> “用返回的视频继续要求加什么音频”：把上一步产物路径给方式 B/C 即可；流水线里用 `{{out.<步骤>}}` 自动串。

## 四、游戏 / 网页角色语音采集

正式入口：`D:\audio-tools\游戏语音采集\游戏语音采集.ps1`（短路径 `D:\audio-tools\游戏语音采集.ps1` 也可）

```powershell
# 看工具与归档状态
游戏语音采集.ps1 status

# 公开网页视频抓音频（yt-dlp，已装于 gen-venv）
游戏语音采集.ps1 web -Url "https://..." -Character "角色名"

# 游戏资源拆包（需对应工具；HoYo/Wwise 用 anime，UE 用 fmodel，Unity 用 assetripper）
游戏语音采集.ps1 scan -Source "E:\原神"
游戏语音采集.ps1 anime -Pck "...\5003.pck" -Filter paimon -Character 派蒙

# OBS 实录（便携 OBS 已就位）
游戏语音采集.ps1 obs
```

归档结构：`C:\音频素材\<游戏>\<角色>\`（已有：崩坏星穹铁道 346 段、测试角色若干）。

**采集后接合成**：
```powershell
音频模块.ps1 -Action split   -Input 角色.wav          # 分离人声
音频模块.ps1 -Action denoise -Input 人声.wav          # 降噪
声音克隆.ps1 -Reference 人声.wav -Text "台词"         # Chatterbox 克隆
音频模块.ps1 -Action align   -Input 新配音.wav -Params "Text=台词"   # 字幕
```

**已知限制**：星穹铁道 4.6 的 Pck 映射与 bank ID 对不上（AnimeWwise 返回 0 条），需等工具更新或 OBS 实录；FModel/AssetRipper 需要游戏本体资源目录。

## 五、入口速查

| 目的 | 命令 |
|---|---|
| 一句话 → 提示词 | `提示词扩写.ps1 -Text ... -Kind image/video/audio/sfx/voice` |
| 一句话 → 图 | `提交作业.ps1 -Task zimage -Prompt ... -Wait` |
| 一句话 → 视频（无声）| `图生视频.ps1 -Image ... -Prompt ...` |
| 一句话 → 视频（带声）| `文本生视频H3快照.ps1 -Prompt ...` |
| 视频 → 旁白 | `视频配音提示词.ps1 -Video ... -Mode auto -Engine qwen` |
| 一句话 → 音效 | `音频模块.ps1 -Action sfx -Params "Prompt=..."` |
| 一句话 → 配音 | `语音设计.ps1 -Text ... -Instruct ...` |
| 串起来 | `流水线.ps1 -Recipe <配方>` |

## 六、当前已知缺口

| 项 | 状态 | 备注 |
|---|---|---|
| 秋叶 ComfyUI 首次启动 | 慢（2~3 分钟）| 会拉取 ComfyRegistry/模型清单，raw.githubusercontent 被墙会重试；起来后正常 |
| Stable Audio Open | 不可用 | HF gated，无授权 token；已用 AudioLDM2 替代 |
| F5-TTS / RVC | 未装 | 需要时再装（F5 要 Python 3.11 环境）|
| 视频换衣 | 不成熟 | 建议逐帧换衣+去闪，或绿幕合成 |
| Qwen3-TTS 速度 | RTF≈2.9 | 长文本建议分段；0.6B 版更快（未装）|
| 星穹铁道资源拆包 | 受限 | 等 AnimeWwise 映射更新，或 OBS 实录 |
