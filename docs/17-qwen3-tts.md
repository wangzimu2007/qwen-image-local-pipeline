# Qwen3-TTS-12Hz-1.7B-VoiceDesign 评估与集成（2026-10-27）

## 结论

**方案合适，已装好并接进工作流。** 用于“文字 → 带声音设计的旁白”明显强于现有 Kokoro；
代价是生成慢（RTF≈2.9，不是实时），适合短旁白（5~20 秒）或对音质要求高的成片。

| 维度 | Qwen3-TTS VoiceDesign | 现有 Kokoro |
|---|---|---|
| 中文准确率（ASR 回读字错率，同文案）| **3.1%** | 78% |
| 采样率 | 24 kHz | 24 kHz |
| 生成速度（12 秒音频）| 约 41 秒（RTF 2.9）| 约 2.5 秒 |
| 音色控制 | **自然语言描述**（音色/情绪/语速/风格）| 固定音色表 |
| 显存 | 约 4.4 GB | < 1 GB |
| 许可 | Apache-2.0（非 gated）| — |

## 模型与环境

| 项 | 值 |
|---|---|
| 模型 | `Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign`（含 speech_tokenizer）|
| 权重 | 4.3 GB（`D:\audio-tools\qwen3-tts\voicedesign`）|
| 环境 | `D:\audio-tools\tts-venv`（Python 3.12 + torch 2.11.0+cu128 + qwen-tts 0.1.1）|
| 关键约束 | `transformers==4.57.3`（与其他环境隔离，避免破坏 AudioLDM2）|

## 用法

```powershell
# 桌面脚本
D:\audio-tools\语音设计.ps1 -Text "旁白内容" -Instruct "低沉磁性的中年男声，语速偏慢，纪录片旁白"

# 统一入口
D:\audio-tools\音频模块.ps1 -Action voicedesign -Params "Text=...;Instruct=..." -Out D:\audio-tools\gen-out\a.wav

# 视频配音里选 Qwen 引擎
D:\audio-tools\视频配音提示词.ps1 -Video x.mp4 -Prompt "低沉男声，纪录片风格" -Mode auto -Engine qwen -BurnSubtitles
```

## 视频配音实测（中性 5 秒片）

| 引擎 | 总耗时 | 结果 |
|---|---|---|
| Kokoro | 约 41 秒 | video-0041/0047 |
| Qwen3-TTS | **53.8 秒** | video-0053（旁白 22 字、自动加速 1.71×、成片正常）|

## 踩坑记录

1. **语言参数**：视频配音传 `zh`，Qwen3-TTS 只认 `Chinese` → 已加 `zh→Chinese` 映射
2. **长文案**：qwen3.5 会无视“每秒 4-5 字”，生成 20 秒旁白配 5 秒视频 → 加代码级硬截断（按句子边界）
3. **Windows `strftime` 不支持 `%f`** → 临时文件名改用时间戳+微秒
4. **控制台 GBK** 打印含替换字符的日志会崩 → 三个助手统一 `sys.stdout.reconfigure(utf-8)`
5. **参数里的分号/引号**会把 `-Params` 拆坏 → 文案与声音描述改为写临时文件传递
6. `flash-attn` 在 Windows 不可用，用 `sdpa`；速度因此偏慢（官方声称有 flash-attn 时更快）

## 可选的更快/更强版本（未装）

| 模型 | 用途 | 预期 |
|---|---|---|
| `Qwen3-TTS-12Hz-0.6B-CustomVoice/Base` | 长文本、要速度 | 约 3 倍快，音色为固定 speaker |
| `Qwen3-TTS-12Hz-1.7B-CustomVoice` | 固定音色+指令 | 与 VoiceDesign 同尺寸 |
| `Qwen3-TTS-12Hz-1.7B-Base` | 声音克隆（参考音频）| 零样本克隆 |