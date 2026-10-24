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
