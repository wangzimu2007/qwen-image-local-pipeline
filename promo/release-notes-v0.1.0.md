# GitHub Release 正文（v0.1.0，复制粘贴用）

> 用法：GitHub → Releases → Draft a new release → Tag `v0.1.0` → 标题填下方「Release title」→
> 正文把下面 `---` 之间的内容整段粘进去 → 附件上传 `qwen-image-local-pipeline-v0.1.0.zip`。

## Release title

```
v0.1.0 — 本地「图 → 视频 → 超分」一条命令流水线 / Local image-to-video pipeline
```

## Release body

---

**中文**

把「文生图 → 图生视频 → AI 超分 → 插帧 / 续接 / 拼接」串成一条命令行流水线。
全部本地推理，不调云端 API。一条命令从一句话走到 720p/48fps 成片（24GB 卡实测 5.9 分钟）。

**English**

A command-line toolkit chaining text-to-image → image-to-video → AI upscaling → frame
interpolation / chaining / concatenation into one local pipeline. No cloud API.
One command: prompt → 720p/48fps clip (5.9 min on a 24 GB GPU, measured).

### ✨ 包含什么

- **13 个脚本**：`t2i` / `img2img` / `edit` / `i2v` / `extend` / `concat` / `trim` / `post` /
  `ai-upscale` / `img-upscale` / `restyle` / `organize` / 统一入口 `video.ps1`
- **5 篇文档 + 1 页速查**：含 **13 类踩坑清单**（BOM、中文路径、4n+1 帧、1080p 爆显存…）
- **4 张效果对比图**：视频超分前后 / 局部 ×3 / 一条命令三段流水线 / 图片 4K
- **配置文件**：`config.sample.ps1`，路径与模型名全参数化

### 📊 实测基准（RTX 5090 Laptop 24GB）

| 任务 | 规格 | 耗时 | 显存峰值 |
|---|---|---|---|
| 文生图 | 1024², 8 步 | 15 秒 | ~15 GB |
| 图生视频 | 736², 121 帧 | 185 秒 | ~16 GB |
| 视频超分 | →720p, 121 帧 | 103 秒 | 15.9 GB |
| 视频超分 | →1080p, 121 帧 | 265 秒 | 11.6 GB |
| 图片超分 | →4K | 102 秒 | — |
| 插帧 ×2 | 121 → 241 帧 | 15~25 秒 | 低 |
| **端到端** | 文字 → 720p/48fps | **5.9 分钟** | 16 GB |

核心结论：**草稿用 832×480 生成，满意后再超分** —— 比直接生成 720p 快 2.4 倍，且运动更顺。

### 🚀 快速开始

```powershell
Copy-Item config.sample.ps1 config.ps1     # 填路径
scripts\video.ps1 -Action t2v -Prompt "黄昏海岸的灯塔" -Seconds 5 -Preset draft
scripts\video.ps1 -Action upscale -Video out.mp4 -Preset final
```

依赖：stable-diffusion.cpp、ComfyUI(+GGUF)、SeedVR2 官方 CLI、Python(av+pillow)。
**模型需自行下载** —— 清单、体积、许可证见 `NOTICE.md`。

### ⚠️ 已知限制

1. **不含模型权重**（许可证只允许使用，不允许分发）
2. **不处理音轨**（Wan 产物无音）
3. **1080p 超分必须开 VAE 分块**（脚本自动开启，否则 24GB 卡解码崩）
4. **Windows PowerShell 5.1**：含中文的 `.ps1` 需 UTF-8 **带 BOM**
5. 单卡单任务（出图/视频/超分是三套权重，不能并发）

### 📜 许可证

脚本与文档 **MIT**；第三方模型与软件各自许可，详见 `NOTICE.md`。

### 🙏 致谢

stable-diffusion.cpp · ComfyUI · ComfyUI-SeedVR2_VideoUpscaler · Wan 2.2 · Qwen-Image

### 🗺️ Roadmap

MiniMax H3（带音频）接入 · Z-Image ControlNet 脚本化 · Linux/macOS 适配

---

## 附件清单

| 文件 | 说明 |
|---|---|
| `qwen-image-local-pipeline-v0.1.0.zip` | 552 KB，源码包（已排除 `.git` 与 `config.ps1`） |

> 也可以不传附件，GitHub 会自动生成 Source code (zip/tar.gz)。
