# 新模型与显存管理（v0.3.0）

本版新增三类模型路线，并把「显存快照」抽成共享模块。三个模块都可以独立调用，也可以作为模板抄到你自己的脚本里。

---

## 1. 为什么需要显存快照

本机 24 GB 显卡上，出图和视频要 14~23 GB。而本地聊天模型（Strata / Ollama）常年占着 16~22 GB。
两套同时跑必然 OOM。

所以流水线在生成之前会：

1. **快照**当前在服务的后端（Strata 按 8080 的模型 id 区分变体；Ollama 读 `/api/ps`）
2. **停掉 / 卸载**它们
3. 等显存真正释放（自适应，见下）
4. 生成
5. **恢复**（Strata 等最多 420 秒；Ollama 用 `keep_alive` 重新加载）

状态文件在 `<repo>\.state\chat-backend.json`，与其它工具的状态文件分开，避免互相覆盖。

### 自适应等待（实测调过）

固定等 150 秒很浪费：浏览器 / 系统常年占用 15 GB，永远达不到阈值，却早就释放完了。
现在的规则：

| 条件 | 行为 |
|---|---|
| 达到 `-NeedMB` | 立即继续 |
| 连续 9 秒不再增长且 ≥9000 MB | 也继续（说明已释放干净） |
| 低于 9000 MB | 告警，让降级逻辑接手 |

---

## 2. 失败自动降级

每个模块内置一组"尝试计划"，失败就换更省的配置重试，并在日志里明确说降了什么：

| 模块 | 降级顺序 |
|---|---|
| `t2i-zimage.ps1` | 原配置 → 关闭风格 LoRA → 分辨率 ×0.75 → 两者都降 |
| `t2i-moss.ps1` | 原配置 → 步数 12→8 → 步数 8 + 分辨率 ×0.8 → 关闭风格 LoRA |
| `ai-video-h3.ps1` | 原尺寸 → ×0.78 → ×0.6（对齐 32，最小 512） |

- 每次尝试都会打印「尝试：xxx」和失败原因
- 成功但降过级会打印「已自动降级：xxx」，输出的参数摘要里也带 `降级` 字段
- 想"宁可失败也不降级"：加 `-NoFallback`

> **提交阶段的 4xx 也会被捕获**。ComfyUI 对"LoRA 名不在列表"这类问题是直接返回 400，
> 如果脚本不 try/catch，会直接崩掉而不是进入降级。

---

## 3. 三个新模块

### `scripts/t2i-zimage.ps1` — Z-Image Turbo

| 项 | 值 |
|---|---|
| 分辨率 | 16 的倍数；常用 1024×1024 / 832×1216 / 1216×832 |
| 步数 | 8（12 也行，**别用 16**） |
| 采样 | cfg 1.0 / res_multistep / simple / shift 3.0 |
| 风格 LoRA | `-Lora` + `-LoraStrength`（0.6 轻、0.8 标准、1.0 浓） |
| 图生图 | `-Image` + `-Denoise`（0.45~0.55 保留构图改氛围） |
| 实测 | 1024²/8 步 **约 4 秒**；832×1216 + LoRA 约 5 秒 |

**风格 LoRA 的锐度下降是设计意图**（雾化效果），不要当成缺陷去加步数。

### `scripts/t2i-moss.ps1` — MOSS-Image

| 项 | 值 |
|---|---|
| 分辨率 | 16 的倍数；1024² 或 1328×752 |
| 步数 | **12**（8 步会磨皮、发丝糊） |
| 采样 | cfg 1.0 / er_sde / simple |
| 风格 LoRA | `-Lora`（叠加在 8 步加速 LoRA 之后） |
| 实测 | 1024²/12 步 **10~16 秒** |

**叠加顺序必须是：UNETLoader → 加速 LoRA → 风格 LoRA → 采样**。反了步数蒸馏会失效。

### `scripts/ai-video-h3.ps1` — MiniMax H3（带音频）

| 项 | 值 |
|---|---|
| 分辨率 | 960×540 日常 / 1344×768 定稿（本地最高 768p 短边） |
| 帧数 | 自动算 **17k+5**（124 帧 ≈ 5.2 秒） |
| 步数 | 8（配 Turbo LoRA） |
| 输出 | h264 + **aac 32 kHz 立体声** |
| 实测 | 640×360 43 秒 / 960×540 113 秒 / 1344×768 324 秒 |

**提示词要同时写画面和声音**（"海浪声""鸟鸣""风声""脚步"）——这是它和 Wan 最大的不同。

---

## 4. 配置项

在 `config.ps1` 里补这些（都有合理默认值，不填也能跑）：

```powershell
# ---------- Z-Image Turbo ----------
ZImagePort = 8188
ZImageUnet = 'z_image_turbo_nvfp4.safetensors'
ZImageClip = 'qwen_3_4b.safetensors'
ZImageVae  = 'ae.safetensors'

# ---------- MOSS-Image ----------
MossPort = 8188
MossUnet = 'moss_image_sft_int8_convrot.safetensors'
MossClip = 'qwen3.5_9b_w4a8_gptq.safetensors'
MossVae  = 'flux2-vae.safetensors'
MossAccelLora = 'moss_image_sft_8steps_dmd.safetensors'

# ---------- MiniMax H3 ----------
H3Port = 8189
H3Unet     = 'minimax_h3_fl2va_pruned_int8_convrot.safetensors'
H3Clip     = 'qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors'
H3VideoVae = 'minimax_h3_video_vae_fp16.safetensors'
H3AudioVae = 'minimax_h3_audio_vae_fp32.safetensors'
H3TurboLora = 'minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors'

# ---------- 显存快照 ----------
VramStateDir     = ''        # 留空 = <repo>\.state
StrataUrl        = 'http://127.0.0.1:8080'
OllamaUrl        = 'http://127.0.0.1:11434'
StrataActionsDir = ''        # 留空 = %LOCALAPPDATA%\Strata\actions
```

---

## 5. 三个必踩的坑（都是实测踩出来的）

### 坑 1：LoRA / 模型名写错 → HTTP 400 直接崩

ComfyUI 对下拉框里不存在的名字返回 400（`value_not_in_list`）。
**提交必须包 try/catch**，把 4xx 当成"这次失败"继续降级，否则脚本会死在第一次尝试。

### 坑 2：视频 VAE 用 int8 量化版 → 画面全黑

`minimax_h3_video_vae_int8_convrot` 能加载、能跑完、音频也正常，但**画面是全黑的**
（亮度 / 对比度都是 0）。必须用 **fp16 版** `minimax_h3_video_vae_fp16.safetensors`。
验收方法：抽一帧算亮度方差，`std < 1` 就是解码坏了。

### 坑 3：同一端口两套引擎

自建版和桌面版 ComfyUI 默认都监听 8188。如果只看"端口开着"就提交，请求会发给错误的引擎
（模型不在列表里，报 `value_not_in_list`）。
判断方法是查 `/object_info/UNETLoader` 的输出列表里有没有自己的模型，而不是查端口。

---

## 6. 耗时汇总（RTX 5090 Laptop 24GB）

| 任务 | 配置 | 耗时 | 显存峰值 |
|---|---|---|---|
| Z-Image 裸模型 | 1024²/8 步 | 4 秒 | ~14 GB |
| Z-Image + 风格 LoRA | 832×1216/8 步/0.8 | 5 秒 | ~14 GB |
| MOSS 写实人像 | 1024²/12 步 | 10~16 秒 | 14.4 GB |
| MOSS + 风格 LoRA | 1024²/12 步/0.8 | 12~22 秒 | 14.9 GB |
| H3 带音频 | 960×540/124 帧 | 113 秒 | 22.8 GB |
| H3 带音频 | 1344×768/124 帧 | 324 秒 | 20.8 GB |

> 恢复快照是**阻塞**的：9B 约 1~2 分钟、27B 更久。赶时间加 `-KeepChatBackend`。
