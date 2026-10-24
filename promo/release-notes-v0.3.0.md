# v0.3.0 — 快速出图双路线 + 带音频视频 + 显存快照

## 新增

- **`scripts/t2i-zimage.ps1`** — Z-Image Turbo 文生图
  - 1024²/8 步 **约 4 秒**；支持风格 LoRA（`-Lora` / `-LoraStrength`）与图生图（`-Image` / `-Denoise`）
- **`scripts/t2i-moss.ps1`** — MOSS-Image 写实人像
  - 1024²/12 步 **10~16 秒**；风格 LoRA 必须排在 8 步加速 LoRA 之后
- **`scripts/ai-video-h3.ps1`** — MiniMax H3 文生视频，**一次出画面 + 32 kHz 立体声**
  - 960×540/124 帧约 113 秒；1344×768 约 324 秒
- **`scripts/lib/vram.ps1`** — 显存快照共享模块
  - 生成前快照并停止 Strata / Ollama，生成后自动恢复；自适应等待，状态文件独立
- **`docs/06-new-models-and-vram.md`** — 三模型参数与实测、降级策略、显存快照设计、三个必踩坑

## 变更

- 三个新脚本内置**失败自动降级**：关 LoRA → 降步数 → 降分辨率，日志与参数摘要都标明降了什么
- 提交阶段捕获 HTTP 4xx：模型/LoRA 名写错不再直接崩，而是进入降级
- `config.sample.ps1` 新增 Z-Image / MOSS / H3 模型键与显存快照配置项

## 实测（RTX 5090 Laptop 24GB）

| 任务 | 配置 | 耗时 | 显存峰值 |
|---|---|---|---|
| Z-Image 裸模型 | 1024²/8 步 | 4 秒 | ~14 GB |
| Z-Image + 风格 LoRA | 832×1216/8 步 | 5~6 秒 | ~14 GB |
| MOSS 写实人像 | 1024²/12 步 | 10~16 秒 | 14.4 GB |
| MOSS + 风格 LoRA | 1024²/12 步 | 12~22 秒 | 14.9 GB |
| H3 带音频 | 960×540/124 帧 | 113 秒 | 22.8 GB |
| H3 带音频 | 1344×768/124 帧 | 324 秒 | 20.8 GB |

## 已知限制

- 本地带音频视频最高 768p 短边（模型架构限制）
- **视频 VAE 必须用 fp16 版**；int8 量化版会解出全黑画面（音频正常，容易误判成功）
- 恢复快照是阻塞的：9B 约 1–2 分钟，27B 更久；`-KeepChatBackend` 可跳过
- 桌面版与自建版 ComfyUI 默认都用 8188，靠查 `/object_info/UNETLoader` 的模型列表判断引擎身份