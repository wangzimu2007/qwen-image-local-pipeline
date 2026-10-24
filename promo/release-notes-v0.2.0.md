# GitHub Release 正文（v0.2.0，复制粘贴用）

> 用法：GitHub → Releases → v0.2.0 → Edit → 正文把下面的内容整段替换即可（当前已用 CHANGELOG 自动生成）。

## Release title

```
v0.2.0 — FlashVSR+ 高分辨率超分（1664×896）/ High-res video upscaling
```

## Release body

---

**中文**

新增一条**高分辨率超分路线**：FlashVSR+（Triton 稀疏注意力）。
832×480 处理 → **1664×896 输出**，121 帧 **76 秒**（24GB 卡实测，显存峰值 23.3 GB）。
比原有 SeedVR2 720p 方案**分辨率高 65%**、耗时更短。

**English**

New high-resolution upscaling path: FlashVSR+ with Triton sparse attention.
832×480 → **1664×896**, 121 frames in **76 s** on a 24 GB GPU (peak 23.3 GB).
65% more pixels than the existing SeedVR2 720p route — and faster.

### ✨ 新增

- **`scripts/ai-upscale-flashvsr.ps1`**：FlashVSR+ 超分脚本（配置驱动，自动启停 ComfyUI、归位编号、打印参数）
- **`scripts/video.ps1`**：新增 `-Method flashvsr` 与 `-Width/-Height`，可 `-Action upscale -Method flashvsr -Interp 2`
- **`config.sample.ps1`**：新增 5 个 FlashVSR 模型键 + `ComfyOutputDir`
- **`docs/03-upscale.md`**：新增整章——为什么必须用 plus + Triton、四步安装、参数、实测、5 条坑
- **`NOTICE.md`**：补 FlashVSR+ 模型清单与来源

### 🔧 变更

- `organize.ps1`：`flashvsr` 产物归为 `aiup`（此前会落到 `other`）

### 📊 四档超分实测（RTX 5090 Laptop 24GB，121 帧 / 5 秒片）

| 路线 | 输出 | 耗时 | 显存 |
|---|---|---|---|
| Lanczos 放大 | 1248×720 | 2.3 s | 低 |
| SeedVR2（720p） | 1248×720 | 103 s | 15.9 GB |
| **FlashVSR+** | **1664×896** | **76.5 s** | **23.3 GB** |
| SeedVR2（1080p） | 1920×1080 | 265 s | 11.6 GB |

### 🔍 「官方环境」为什么关键

| 配置 | 处理分辨率上限 | 输出 | 耗时 |
|---|---|---|---|
| 原版 v1.0 + sdpa 兜底 | ~512×288 | 1024×512 | 43 s |
| **plus 权重 + `flashvsr_attn`(Triton)** | **832×480** | **1664×896** | **76 s（热）** |

- 节点自带 Triton 内核：`pip install -e operators/flashvsr_attn --no-build-isolation --no-deps`
- 需要 `triton-windows` + MSVC，**不需要 CUDA Toolkit**
- 原版 v1.0/v1.1 走 `block_sparse_attn` C++ 扩展，编译它才需要 CUDA Toolkit —— 24GB 卡上只能到 512×288，**不推荐**

### ⚠️ 已知限制

1. 不含模型权重（plus 权重约 6.7 GB，需自行下载，见 `NOTICE.md`）
2. FlashVSR+ 会吃满 24GB 显存，**不能和其他 AI 任务并发**
3. 1280×720 处理档不可用（≈16 秒/帧，5 秒片要 30+ 分钟）
4. 输出高度对齐到 64 的倍数（832×480 → 1664×896，比例 1.73 → 1.86）
5. 不处理音轨

### 📦 安装摘要

```powershell
# 节点
git clone https://github.com/smthemex/ComfyUI_FlashVSR  ComfyUI/custom_nodes/ComfyUI_FlashVSR
pip install --no-deps loguru win32-setctime torchmetrics pytorch-lightning lightning-utilities pandas pytz tzdata opencv-python

# Triton 内核（节点自带）
cd ComfyUI/custom_nodes/ComfyUI_FlashVSR/operators/flashvsr_attn
pip install -e . --no-build-isolation --no-deps

# plus 权重 → models/FlashVSR/（turbodit / lq_proj / TCDecoder / posi_prompt）+ models/vae/wan_2.1_vae.safetensors
# 重启 ComfyUI（下拉列表在 import 时生成）
```

### 🙏 致谢

OpenImagingLab/FlashVSR（与 FlashVSR+）· smthemex/ComfyUI_FlashVSR · Comfy-Org · SeedVR2

---

## 附件清单

| 文件 | 说明 |
|---|---|
| `qwen-image-local-pipeline-v0.2.0.zip` | 838.9 KB，源码包（排除 `.git` 与 `config.ps1`） |
