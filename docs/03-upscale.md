# 03 · AI 超分：视频 / 图片（SeedVR2）

## 为什么不用 ComfyUI 里的 SeedVR2 工作流

ComfyUI 官方模板里的 `seedvr2` 是**前端子图（subgraph）**：
`object_info` 里查不到它的输入定义，**无法通过 `/prompt` API 提交**。
想让超分进入自动化流水线，必须用**官方后端版**：

- 仓库：`numz/ComfyUI-SeedVR2_VideoUpscaler`（ByteDance Seed 官方合作实现）
- 它同时提供 **4 个后端节点** + **独立 CLI** `inference_cli.py`
- 本项目调用它的 CLI，不依赖 ComfyUI 界面

## 安装

```powershell
# 1) 拿代码（GitHub 直连慢时用 codeload，实测最快）
curl.exe -L -o seedvr2.zip https://codeload.github.com/numz/ComfyUI-SeedVR2_VideoUpscaler/zip/refs/heads/main
Expand-Archive seedvr2.zip -DestinationPath D:\seedvr2

# 2) 装依赖（重点：--no-deps，否则会把 torch 升掉）
& $py -m pip install --no-deps -i https://pypi.tuna.tsinghua.edu.cn/simple `
    omegaconf diffusers peft rotary_embedding_torch opencv-python matplotlib accelerate

# 3) 下模型（它自带的下载器写死了 huggingface.co，国内会失败 → 手动下）
#    seedvr2_ema_3b_fp8_e4m3fn.safetensors  3.16 GB
#    ema_vae_fp16.safetensors               0.47 GB
#    放到 <repo>\models\SEEDVR2\
```

`config.ps1` 里对应填：

```powershell
SeedVR2Root   = 'D:\seedvr2\ComfyUI-SeedVR2_VideoUpscaler-main'
SeedVR2Python = '你的 python.exe'     # 需要 torch + av + cv2 + diffusers
SeedVR2Models = 'D:\seedvr2\ComfyUI-SeedVR2_VideoUpscaler-main\models\SEEDVR2'
SeedVR2Dit    = 'seedvr2_ema_3b_fp8_e4m3fn.safetensors'
```

## 视频超分 —— `scripts\ai-upscale.ps1`

```powershell
scripts\ai-upscale.ps1 -Video x.mp4 -Resolution 720
scripts\ai-upscale.ps1 -Video x.mp4 -Resolution 1080 -BatchSize 13
```

| 参数 | 说明 |
|---|---|
| `-Resolution` | **短边**目标：720 / 1080（自动保持长宽比） |
| `-BatchSize` | 必须 **4n+1**。720p 用 21；1080p 降到 13；显存紧就 9 或 5 |
| `-Color` | 色彩对齐：`lab`（默认，最忠实）/ `wavelet` / `adain` / `none` |

### 实测基准（121 帧 / 5 秒片）

| 目标 | batch | VAE 分块 | 耗时 | 显存峰值 |
|---|---|---|---|---|
| 832×480 → 1248×720 | 21 | 不需要 | **103 秒** | 15.9 GB |
| 1280×720 → 1920×1080 | 13 | **必须开** | **265 秒** | 11.6 GB |

### 1080p 必须开 VAE 分块

不开分块时，解码阶段显存会飙到 **25 GB+**（24 GB 卡直接崩，
日志是 `c10_cuda ... warn_or_error_on_sync` 加一堆堆栈）。
脚本在 `-Resolution >= 900` 时**自动加**：

```
--vae_encode_tiled --vae_encode_tile_size 768 --vae_encode_tile_overlap 96
--vae_decode_tiled --vae_decode_tile_size 768 --vae_decode_tile_overlap 96
```

## 图片超分 —— `scripts\img-upscale.ps1`

```powershell
scripts\img-upscale.ps1 -Image x.png -Resolution 1440    # 2K
scripts\img-upscale.ps1 -Image x.png -Resolution 2160    # 4K
```

实测：1280×768 → **3600×2160（4K）**，102 秒，画质明显优于普通插值放大。

## 三种"放大"的区别（别混）

| 方式 | 原理 | 5 秒片耗时 | 质量 | 何时用 |
|---|---|---|---|---|
| Lanczos（`post.ps1 -Scale`） | 插值，无 AI | 2~3 秒 | ★★ 只提分辨率 | 预览、批量、草稿 |
| **SeedVR2 AI 超分** | 扩散重建，带时序 | 103 秒 | ★★★★ 真加细节 | **日常首选** |
| 商业软件（Topaz 等） | 专有生成式模型 | — | ★★★★★ | 预算充足、定稿 |

**判断口径**：说「放大」= Lanczos；说「超分 / 变清晰 / 修复模糊」= SeedVR2。

## 坑

1. **中文路径必崩**：CLI 内部用 OpenCV 读文件，`Cannot open image file: .../Qwen 图片/...`。
   脚本已自动复制到英文临时目录再处理。
2. **`--model_dir` 默认是相对当前目录**的 `./models/SEEDVR2`，一定要传绝对路径。
3. **emoji 崩控制台**：CLI 会打印 emoji，GBK 控制台下直接 `UnicodeEncodeError`。
   脚本已设 `PYTHONIOENCODING=utf-8` / `PYTHONUTF8=1`。
4. **加速库可选**：装 `sageattention` / `flash-attn` / `triton` 能再快 20~40%，
   但容易和 ComfyUI 环境冲突，本项目默认不装。
5. **别指望放大 4 倍**：SeedVR2 适合 1.5~2 倍；再高建议分两次或换 7B 模型。
---

# 4. FlashVSR+（高分辨率档，官方 triton 环境）

当 720p 不够、想要 **1600 宽左右**时用这条。它不是 SeedVR2 的替代，而是上限更高的补充。

## 为什么必须用 FlashVSR+ 而不是原版

| 版本 | 注意力后端 | 24GB 卡能做到 | 说明 |
|---|---|---|---|
| FlashVSR v1.0 / v1.1 | `block_sparse_attn`（CUDA 扩展） | 处理分辨率仅 ~512×288 | 需装 CUDA Toolkit 编译，本机没装时只能用慢速 sdpa 兜底 |
| **FlashVSR+（plus）** | **`flashvsr_attn`（Triton 稀疏）** | **832×480 处理 → 1664×896 输出** | 节点自带该内核源码，**triton 已装即可编译，不需要 CUDA Toolkit** |

> 关键：节点 `operators/flashvsr_attn` 里的 Triton 内核**只服务 plus 模式**；
> 原版权重走的是另一套 C++ 扩展。所以"装官方环境"= 装 Triton 内核 + 换 plus 权重。

## 安装（四步）

```powershell
# 1) 节点（ComfyUI custom_nodes）
#    git clone https://github.com/smthemex/ComfyUI_FlashVSR
#    装依赖时务必 --no-deps，否则会升级 torch
pip install --no-deps loguru win32-setctime torchmetrics pytorch-lightning lightning-utilities pandas pytz tzdata opencv-python

# 2) Triton 内核（节点自带，无需 CUDA Toolkit；需要 triton-windows + MSVC）
cd ComfyUI\custom_nodes\ComfyUI_FlashVSR\operators\flashvsr_attn
pip install -e . --no-build-isolation --no-deps

# 3) plus 权重（ruchangyao/FlashVSR_plus，约 6.7 GB）
#    turbo/dit.safetensors        → models\FlashVSR\turbo_dit_plus.safetensors
#    turbo/lq_proj_in.safetensors → models\FlashVSR\lq_proj_in_plus_turbo.safetensors
#    TCDecoder.ckpt               → models\FlashVSR\TCDecoder_plus.ckpt
#    posi_prompt.pth（OpenImagingLab/FlashVSR_Plus 的 prompt_tensor）→ models\FlashVSR\posi_prompt_plus.pth
#    另外需要 Wan2.1 VAE： models\vae\wan_2.1_vae.safetensors（242 MB）

# 4) 重启 ComfyUI（下拉列表在 import 时生成，新增模型文件后必须重启）
```

依赖里最容易被忽略的是 `loguru`+`win32-setctime`：缺了节点会 **静默加载失败**
（ComfyUI 日志 `IMPORT FAILED`，API 报 `missing_node_type`），界面上看不到任何报错。

## 用法

```powershell
scripts\ai-upscale-flashvsr.ps1 -Video x.mp4                          # 832×480 → 1664×896
scripts\ai-upscale-flashvsr.ps1 -Video x.mp4 -Width 512 -Height 288   # 省显存 → 1024×512
scripts\video.ps1 -Action upscale -Video x.mp4 -Method flashvsr -Interp 2   # 超分 + 插帧
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Width` / `-Height` | 832 / 480 | **处理分辨率**（不是输出）。显存由它主导，几乎不受帧数影响 |
| `-Scale` | 2 | 放大倍数 1~4；输出高度会被对齐到 64 的倍数 |
| `-PlusTemporal` | 4 | 每 latent 帧输入帧数；大运动改 2 或 1（更慢更稳） |

## 实测（RTX 5090 Laptop 24GB，121 帧 / 5.04 秒片）

| 设置 | 输出 | 耗时 | 显存峰值 |
|---|---|---|---|
| 832×480 ×2（默认） | **1664×896** | **76.5 秒**（首次含 Triton JIT 约 164 秒） | 23.3 GB |
| 512×288 ×2 | 1024×512 | 31 秒 | 19.8 GB |
| 1280×720 ×2 | 2560×1440 | 49 帧 >13 分钟（≈16 秒/帧） | 22.8 GB |
| **对照：SeedVR2 3B** | 1248×720 | 103 秒 | 15.9 GB |

**结论**：FlashVSR+ 默认档比 SeedVR2 **更快、分辨率高 65%**，代价是显存几乎吃满 24GB；
1280×720 处理档慢到不可用（5 秒片要 30+ 分钟）。

## 与 SeedVR2 怎么选

| 需求 | 选 |
|---|---|
| 日常 720p、显存紧张（16GB 卡） | SeedVR2 |
| 要 1600 宽以上、有 24GB | FlashVSR+ |
| 1080p 定稿 | SeedVR2 `-Resolution 1080` |
| 批量很多条 | SeedVR2（FlashVSR 一次占满显存，无法并发） |

## 坑

1. **必须重启 ComfyUI** 才能看到新模型。
2. **显存不足就降处理分辨率**，不要试图靠减帧数省显存（实测帧数影响极小）。
3. **输出长宽比会轻微变化**（高度对齐 64）：介意就显式给 `-Height`（如 512）。
4. `plus_attn` 必须选 `triton_block_sparse`，否则退回 sdpa，显存和速度都会明显变差。
5. 该模型权重许可证以模型卡为准，商用前自行确认。
