---
name: video-upscale
description: 视频超分skill（放大 / 提高清晰度 / 补帧）：按需求选 Lanczos 快速放大、SeedVR2 AI 超分（日常 720p / 1080p）、或 FlashVSR+（官方 triton 环境，可到 1664×896 高分辨率），再配合 FILM 插帧提高帧率，自动归位编号并抽帧预览。Use for 超分、放大视频、提高清晰度、变清晰、修复模糊、高分辨率超分、插帧、提高帧率 requests.
---

# 视频超分 / 放大 / 补帧

四条本地路线，**按"要多快 / 要多清楚"选**，全部不需要打开专业软件。

## 1. 四条路线对比（RTX 5090 Laptop 24GB 实测，121 帧 / 5 秒片）

| 路线 | 命令 | 输出 | 耗时 | 显存峰值 | 适用 |
|---|---|---|---|---|---|
| **① Lanczos 快速放大** | `后期处理.ps1 -Scale 1.5` | 1248×720 | **2.3 秒** | 低 | 草稿、预览、批量 |
| **② SeedVR2 AI 超分** | `AI超分.ps1 -Resolution 720` | 1248×720 | **103 秒** | 15.9 GB | **日常首选** |
| **③ FlashVSR+（官方环境）** | `AI超分FlashVSR.ps1` | **1664×896** | **76~164 秒** | **23.3 GB** | **要超 720p** |
| ④ SeedVR2 1080p | `AI超分.ps1 -Resolution 1080 -BatchSize 13` | 1920×1080 | 265 秒 | 11.6 GB | 要 1080p 时 |

**结论**：
- 只想"看起来更清楚" → ①（2.3 秒）
- 日常定稿 720p → ②（103 秒，稳、省显存）
- **要 1600 宽左右的高分辨率 → ③**（比 ② 多 65% 像素，耗时反而可能更短，但显存吃满 24GB）
- 1080p → ④（也可以 ③ 之后再 Lanczos）

## 2. 用户怎么一句话调用（话术 → 动作映射）

| 用户说 | 执行 |
|---|---|
| "放大 1.5 倍" / "先快速放大看看" | `后期处理.ps1 -Scale 1.5` |
| "**超分**到 720p" / "用 AI 让它变清晰" | `AI超分.ps1 -Resolution 720` |
| "超分到 1080p" | `AI超分.ps1 -Resolution 1080 -BatchSize 13` |
| "**要更高分辨率**" / "做到 1600 宽" / "比 720p 更清楚" | **`AI超分FlashVSR.ps1 -Video x.mp4`** |
| "超分 + 提帧率" / "要又清晰又流畅" | `视频.ps1 -Action upscale -Preset final` |
| 要高分辨率**又**要流畅 | `视频.ps1 -Action upscale -Method flashvsr -Interp 2` |
| "只要流畅，不要更大" | `后期处理.ps1 -Interp 2` |
| "批量超分这几条" | 逐条跑 ②；FlashVSR 一次只能跑一条（占满显存） |

## 3. SeedVR2（日常 720p / 1080p）

```powershell
powershell -File D:\qwen-image-2.1\AI超分.ps1 -Video "某.mp4" -Resolution 720 [-BatchSize 21] [-Color lab]
```

| 参数 | 说明 |
|---|---|
| `-Resolution` | **短边**目标（720 / 1080），保持长宽比 |
| `-BatchSize` | 必须 **4n+1**；720p 用 21，1080p 用 13，OOM 降 9→5 |
| `-Color` | `lab`（默认最忠实）/ `wavelet` / `adain` / `none` |

- 显存：720p/21 ≈ 16 GB；1080p/13 ≈ 11.6 GB（**1080p 必须开 VAE 分块，脚本自动加**）
- 速度：约 **帧数 × 0.6~0.8 秒**
- 走**独立 CLI**，不依赖 ComfyUI，跑前确认显存干净（Ollama/Strata 占着会 OOM）

## 4. FlashVSR+（高分辨率档，官方环境）

```powershell
powershell -File D:\qwen-image-2.1\AI超分FlashVSR.ps1 -Video "某.mp4"
powershell -File D:\qwen-image-2.1\AI超分FlashVSR.ps1 -Video "某.mp4" -Width 832 -Height 480 -Scale 2
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Width` / `-Height` | 832 / 480 | **处理分辨率**（不是输出）。显存由它主导，比帧数影响大得多 |
| `-Scale` | 2 | 放大倍数（1~4）。输出 ≈ 处理尺寸 × Scale（高度会被对齐到 64 的倍数） |
| `-PlusTemporal` | 4 | 每 latent 帧输入帧数；大运动改 2 或 1（更慢更稳） |
| `-KeepServer` | — | 保留 ComfyUI 进程（连续跑多条时用） |

- **必须走秋叶版 ComfyUI（8189）**：脚本会自动启停并处理显存快照/恢复
- 模型：FlashVSR+ turbo（`turbo_dit_plus.safetensors` 5.4 GB 等，在 `D:\flashvsr\models\plus`，硬链接进 ComfyUI）
- 加速：`flashvsr_attn`（triton 稀疏注意力）**已编译安装**，`plus_attn=triton_block_sparse`
- 实测：832×480 → **1664×896**，121 帧 **76 秒（热）/ 164 秒（首次含 JIT）**，显存峰值 **23.3 GB**
- **1280×720 处理档不可用**：≈16 秒/帧，5 秒片要 30+ 分钟
- 注意：**输出高度会对齐到 64 的倍数**，长宽比可能轻微变化（832×480 → 1664×896，1.73→1.86）

## 5. 一键整合入口（推荐日常用这个）

```powershell
# 高质量定稿：SeedVR2 720p + 插帧 ×2
powershell -File D:\qwen-image-2.1\视频.ps1 -Action upscale -Video "某.mp4" -Preset final

# 高分辨率定稿：FlashVSR+（1664×896）+ 插帧 ×2
powershell -File D:\qwen-image-2.1\视频.ps1 -Action upscale -Video "某.mp4" -Method flashvsr -Interp 2

# 快速定稿：Lanczos 1.5× + 插帧 ×2（30 秒）
... -Action upscale -Video "某.mp4" -Preset fast

# 只超分 / 只插帧
... -Action upscale -Video "某.mp4" -Resolution 1080 -Interp 1
... -Action upscale -Video "某.mp4" -Method lanczos -Scale 1 -Interp 2
```

## 6. 跑完必须做

1. `present` 交付 **mp4 + 2~3 张预览帧**
2. 告诉用户去 `C:\Users\wangzimu\Desktop\视频\` 双击播放
3. 报告：源分辨率/帧率 → 目标分辨率/帧率、耗时、显存峰值
4. **说清路线**（Lanczos / SeedVR2 / FlashVSR+），避免用户误以为都是同一种"AI 超分"

## 7. 注意事项

- **三条 AI 路线互斥**：都吃满显存，不能并发；FlashVSR 跑时不要同时开别的 ComfyUI
- **Lanczos 放大不要超过 2×**：再大就糊
- **AI 超分不改变帧率**，要更高帧率再跑 `-Interp`
- **音频**：这些流程只处理画面，音轨不保留（Wan 产物本来就没音轨）
- Topaz Video AI（$59/月）质量更高但只能订阅；本 skill 全是本地方案

## 8. 失败排查

| 现象 | 处理 |
|---|---|
| SeedVR2 `UnicodeEncodeError` | 脚本已设 `PYTHONIOENCODING=utf-8` |
| SeedVR2 `CUDA out of memory` | 降 `-BatchSize`（9→5）或 `-Resolution`（720→540） |
| FlashVSR `missing_node_type` | ComfyUI 没加载节点：查 `user\comfyui_8189.log` 里的 `IMPORT FAILED`（缺 loguru 等） |
| FlashVSR `exceed allowed memory` | 降 `-Width/-Height`（832×480 → 640×368 → 512×288），不要靠减帧数 |
| FlashVSR 节点列表里没有 plus 模型 | 新增模型文件后必须重启 ComfyUI（下拉列表在 import 时生成） |
| 超分后色调变了 | SeedVR2 换 `-Color lab`；FlashVSR 保持 `color_fix=True` |

## 9. 相关 skill

- `video-edit`：拼接 / 延长 / 裁剪
- `image-to-video`：生成视频
- `video-to-video`：改风格

## 交付时必须报告参数（脚本已自动打印）

每次生成/处理后，脚本结尾会打印一段「输出参数」：
分辨率 / 帧率 / 时长 / 帧数 / 编码 / 码率 / 音轨 / 体积 / 比例。
**汇报时直接抄这段**，并额外补充：
1. 用的模型（Lanczos / SeedVR2 3B / FlashVSR+ turbo）
2. 耗时（脚本里有「用时 X 秒」）
3. 一句画质评价
4. 文件在哪（`Desktop\视频\`），提醒双击打开
## 显存快照（2026-10-24 接入）

> 接入模板见 `D:\qwen-image-2.1\_新脚本接入显存快照.md`。

`AI超分FlashVSR.ps1` 已接入 `_vram.ps1`（生成前快照/释放、结束自动恢复，秋叶脚本 `-KeepChatBackend`/`-NoRestore`）。
SeedVR2 CLI 与 `后期处理.ps1` 的 Lanczos/插帧路径同理。`-KeepChatBackend` 可跳过。
