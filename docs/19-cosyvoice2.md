# CosyVoice2 本地配音修复记录（2026-10-27）

## 结论

**Windows 原生已跑通**，不再依赖 WSL。

| 项 | 值 |
|---|---|
| 入口 | `D:\audio-tools\CosyVoice2配音.ps1`（Text / Out / Instruct / Reference / Speed）|
| 统一入口 | `音频模块.ps1 -Action tts-cosy -Params "Text=...;Instruct=...;Reference=..."` |
| 环境 | `D:\audio-tools\cosyvoice\venv2`（Python 3.13.12 + torch 2.12.1+cu130）|
| 模型 | `pretrained_models\CosyVoice2-0.5B`（llm.pt 1.93 GB + flow 430 MB + onnx 分词器）|
| 默认参考音色 | `cosyvoice\voices\default_16k.wav`（16k 单声道）|
| 实测 | 预热后 RTF **0.59**（7.68 秒音频 4.54 秒）；冷启动单次约 35 秒（含加载 5.5 秒）|

## 关键修复

| 问题 | 原因 | 修法 |
|---|---|---|
| `onnx==1.16.0` 装不上 | Python 3.13 无轮子，源码编译失败 | 放宽为 `onnx>=1.19` |
| 缺 whisper / lightning / pyparsing / dateutil 等 | 依赖没装全 | 循环“报缺什么装什么”，补 `python-dateutil` 等映射 |
| `torchcodec` DLL 加载失败 | torchcodec 0.17 与 torch 2.12 ABI 不匹配 | **不用 torchaudio.load**：用 soundfile 读取并 monkeypatch `torchaudio.load` |
| `wetext` 中文前端不可用 | modelscope 403 | 回退（数字/英文归一化可能不完美），中文正常合成 |
| venv2 继承 Comfy Desktop 的 torch/torchaudio | venv2 由 Desktop venv 派生 | 直接复用其 torch 栈，deps 装到 venv2 覆盖 |

## 用法

```powershell
# 直接
D:\audio-tools\CosyVoice2配音.ps1 -Text "夜色渐深，街灯次第亮起。" -Out D:\audio-tools\gen-out\a.wav -Instruct "沉稳的中年男声，语速稍慢"

# 克隆参考音色
D:\audio-tools\CosyVoice2配音.ps1 -Text "台词" -Out b.wav -Reference "C:\音频素材\原神\派蒙\xxx.wav"

# 统一入口
D:\audio-tools\音频模块.ps1 -Action tts-cosy -Params "Text=...;Instruct=..." -Json
```

## 验证产物

- `D:\audio-tools\gen-out\_cosy_smoke.wav`（8.04 秒，首跑 RTF 2.75）
- `D:\audio-tools\gen-out\_cosy_smoke2.wav`、`_cosy_smoke3.wav`（预热后 RTF 0.59）
- `D:\audio-tools\gen-out\audio-cosy-20261027-021552.wav`（走音频模块，7.2 秒，总 34.6 秒）

## 备注

- 与 Qwen3-TTS VoiceDesign 对比：CosyVoice2 快（RTF≈0.6 vs 2.9），但音色控制靠“指令 + 参考音”而非自然语言音色描述；
  两者都保留，按场景选。
- 并发调用每次都会重新加载模型（约 5.5 秒）；批量长文本建议后续做常驻服务。