---
name: text-to-video-h3
description: H3文生视频skill（文本直接生成「画面+声音」的视频）：用 MiniMax H3 本地模型一次出带 32kHz 立体声的视频，脚本 D:\qwen-image-2.1\文本生视频H3.ps1 自动启停 ComfyUI、归位编号、打印参数。Use for 带声音的视频、音画同步、H3、加音效、生成有声视频、文本生视频（带音频）requests. 硬规则：唯一能出声的本地路线，用户要「有声音/音画同步」就用本 skill；只要画面且想更快更省显存，用 image-to-video（Wan）。
---

# MiniMax H3：文本 → 视频（含音频）

**这是唯一能"一次出画面 + 声音"的本地路线**。其他模型（Wan 2.2 / LTX）只出画面。

## 1. 什么时候用它

| 需求 | 用它 |
|---|---|
| 要**环境音 / 音效 / 对白** | ✅ H3（本 skill） |
| 只要画面、要快 | ❌ 用 `image-to-video` skill（Wan 2.2，5 秒 2 分钟） |
| 要 720p 以上分辨率 | ⚠️ H3 本地最高 768p 短边；更高用 H3 出片后接 `video-upscale` skill |

## 1.5 两个脚本怎么选

> 默认用 **文本生视频H3快照.ps1**；旧版仅在需要沿用秋叶脚本自己的快照时使用。

| 脚本 | 显存快照 | 适用 |
|---|---|---|
| `文本生视频H3.ps1`（**旧版**） | 靠秋叶启动脚本自己的快照（状态文件在 `D:\ComfyUI-aki-v3.2\`） | 日常，简单直接 |
| **`文本生视频H3快照.ps1`（新）** | **显式用 `_vram.ps1` 管理**，让秋叶脚本 `-KeepChatBackend` 不再自己快照、`-NoRestore` 不自己恢复 | 需要**明确看到**"卸载了什么/恢复了什么"，或多脚本混用时避免两套状态文件打架 |

两者都支持：
- `-KeepChatBackend`：跳过快照与恢复
- 尺寸自动降级（按比例：原尺寸 → ×0.78 → ×0.6，最小 512×512，32 的倍数）

**实测（2026-10-24，Ollama 里装着 qwen3.5:9b）**：
`文本生视频H3快照.ps1 -Width 512 -Height 512 -Seconds 4` → 检测到 Ollama → 卸载 → 自适应等显存 →
启动秋叶 ComfyUI（63 秒）→ 生成 64.3 秒 / 显存峰值 22.7 GB → 停引擎（-NoRestore）→ 重新加载 Ollama。
**总耗时 203.8 秒**，两个状态文件都无残留。
## 2. 一句话调用

```powershell
powershell -File D:\qwen-image-2.1\文本生视频H3.ps1 -Prompt "海边灯塔，黄昏，海浪拍礁石，海鸟鸣叫" -Seconds 5
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Prompt` | 必填 | **画面 + 声音一起描述**（「海浪拍岸」「鸟鸣」「脚步声」都写进去） |
| `-Width` / `-Height` | 960 / 540 | 640×360 草稿 / 960×540 日常 / **1344×768 全画布** |
| `-Seconds` | 5 | 自动换算成 **17k+5 帧**（124 帧 = 5.2 秒；训练范围约 124~362） |
| `-Steps` | 8 | Turbo LoRA 用 8；`-NoLora` 时用 20 |
| `-Seed` | 0 | 0 = 随机 |

## 3. 实测（RTX 5090 Laptop 24GB，124 帧 ≈5.2 秒，Turbo 8 步）

| 分辨率 | 耗时 | 显存峰值 | 用途 |
|---|---|---|---|
| 640×360 | **43 秒** | 20.7 GB | 快速试提示词 |
| 960×540 | **113 秒（1.9 分钟）** | 22.8 GB | 日常 |
| 1344×768（全画布） | **324 秒（5.4 分钟）** | 20.8 GB | 定稿 |

输出：h264 + **aac 32 kHz 立体声**，24 fps。

## 4. 关键前提（缺一不可）

| 项 | 要求 |
|---|---|
| 模型 | `D:\minimax-h3\models`（44 GB），已硬链接进秋叶版 ComfyUI |
| 视频 VAE | **必须 fp16 版**：`minimax_h3_video_vae_fp16.safetensors` |
| 音频 VAE | `minimax_h3_audio_vae_fp32.safetensors` |
| 文本编码器 | `qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors`（14.6 GB；别用 int8 的 25 GB） |
| 扩散模型 | `minimax_h3_fl2va_pruned_int8_convrot.safetensors`（19.5 GB） |
| Turbo LoRA | `minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors`（1.8 GB） |
| 后端 | 秋叶版 ComfyUI，端口 8189（脚本自动启停 + 显存快照/恢复） |

## 5. 致命坑（实测踩过）

1. **`minimax_h3_video_vae_int8_convrot` 会解出纯黑画面**，音频却正常。
   → 换 fp16 VAE 立刻恢复。**永远不要用 int8 视频 VAE**。
2. 排查黑屏方法：抽帧算亮度/对比度 —— 全 0 就是解码坏了（本 skill 的验收步骤）。
3. **帧数必须 17k+5**（124/141/158/175…362），脚本已自动算，手工调用要注意。
4. 显存吃到 20~23 GB，**不能和其他 AI 任务并发**（出图/其他视频/聊天模型都要先停）。
5. **本地最高 768p 短边**，2K 只有云端；要更高分辨率接 `video-upscale`。
6. 官方 `video_minimax_h3_t2v.json` 是**前端子图**，API 提交不了 —— 脚本已手工扁平化成 API 图
   （`UNETLoader` → `LoraLoaderModelOnly` → `BasicGuider`；`CLIPLoader(type=minimax)` + fp16 `VAELoader`
   → `MiniMaxH3ImageToVideo` → `BasicScheduler`(res_multistep) → `SamplerCustomAdvanced`
   → `VAEDecode` + `VAEDecodeAudio` → `CreateVideo`(24fps) → `SaveVideo`）。

## 6. 提示词写法

H3 是**音画联合**模型，提示词要同时交代"看到什么"和"听到什么"：

> 海边灯塔，黄昏，海浪拍打礁石，海鸟鸣叫，远处风声，电影感，缓慢推进

- 声音词：`海浪声` `鸟鸣` `风声` `脚步声` `引擎轰鸣` `雨声` `人群嘈杂`
- 画面词：主体 + 光线 + 时间 + 镜头运动
- 一次写清，别堆砌形容词

## 7. 跑完必须做

1. **验黑屏**：抽 3 帧看亮度/对比度（全 0 = 失败，检查是不是用了 int8 VAE）
2. `present` 交付 **mp4 + 2~3 张预览帧**
3. 报告：分辨率 / 帧数 / 时长 / 帧率 / **音轨（aac 32kHz）** / 耗时 / 显存峰值
4. 说明"这是本地 H3，最高 768p"，避免用户误以为能出 2K

## 8. 相关 skill

- `text-to-image`：出图
- `image-to-video`：Wan 2.2 图生视频（更快、无音频）
- `video-upscale`：把 H3 的 768p 再超分到 1664×896
- `video-edit`：拼接 / 裁剪 / 插帧
