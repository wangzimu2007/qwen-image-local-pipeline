# v0.7.1 — 本地模型自动续跑（2026-10-26）

## 解决什么

以前本地模型会话提交出图作业后必须**结束本轮**，等用户再发一句话才能继续——
因为作业批会把聊天模型卸载，模型无法发起下一轮推理（`TRANSPORT Connection error`）。

现在：`提交作业.ps1 ... -Wait` 会**原地阻塞**，直到「作业完成 + 守护锁释放 + 批末标记出现 + 聊天后端能应答」
四个条件全部满足才返回。返回时模型已经能推理，同一轮可以直接继续，**不需要用户再说话**。

适用于所有 `role=chat` 的后端（Strata / Ollama / NInfer 及以后新接入的模型），
因为"等哪个后端"由 `Get-LocalBackends -Role chat` 动态判断。

## 实现

| 文件 | 改动 |
|---|---|
| `scripts/job-worker.ps1` | 批末恢复完成后写 `.jobs/last-batch.json`（`by=guardian`、`batchFinishedAt`、`jobs[]`、`restored[]`），写在锁释放之前 |
| `scripts/submit-job.ps1` | `-Wait` 改为轮询四个条件；每 15 秒打印进度；返回时打印「聊天后端已就绪：<kind> <port>」；云端会话自动跳过"等后端"；`-TimeoutSec` 默认 600 |
| `skills/text-to-image/SKILL.md` | 规则 0 更新：本地会话用 `-Wait`（≤2 张/批），拆批连续调用即可全自动续跑 |

## 使用

```powershell
# 1~2 张：一次阻塞到底，返回后直接继续
提交作业.ps1 -Task zimage -Prompt "..." -Wait

# 3 张以上：2 张一批，连续调用（每批之间后端都会恢复，会话不断）
提交作业.ps1 -Task zimage -Prompt "..." -Count 2 -Seeds "11,22" -Wait
提交作业.ps1 -Task zimage -Prompt "..." -Count 1 -Seeds "33" -Wait
```

前提：本地模型会话关闭「自动审查」。

## 验证（2026-10-26 18:00 实测，RTX 5090 Laptop 24 GB + Ollama qwen3.8:27b-abliterated 常驻）

前置：先让本地聊天模型常驻（显存 23.5 GB），迫使提交走队列/卸载路径（真实会话场景）。

| 测试 | 内容 | 结果 | 总耗时 | 关键证据 |
|---|---|---|---|---|
| A | 单张 + `-Wait` | 通过 | 53.5 s | 队列模式；打印「聊天后端已就绪」；`last-batch.json` 已写 |
| B | 一次 2 张 + `-Wait` | 通过 | 79.0 s | 守护日志「本批 2 个作业」，2 张 product 齐全，只恢复一次（6.3 s）|
| C | 两条命令**同时**提交 | 通过 | 64.3 s | 两条被合并成「本批 2 个作业」，均 done |
| D | 批次运行中再追加 1 张 | 通过 | 144.6 s | 批大小 [1,1]：追加的进下一批，不打断，最终 pending=0 |
| E | 同步互斥（显存充足时并发） | 通过 | — | 进程1 `同步执行` 直接出图；进程2 自动改为 `已排队`，随后由守护跑完 |

补充实测（同次会话）：

- 单张出图 23.2 s；批末恢复 6.3 s（Ollama 模型真加载 20.6 GB）
- 并发提交 + 批中追加三条同时到达时，守护合并成「本批 3 个作业」，全部 done
- 全程 Strata 保持"手动停止"状态，未被拉起

## 验证中发现并修掉的两个真实 bug

| 现象 | 根因 | 修法 |
|---|---|---|
| `-Count 2` 只出 1 张 | 同步路径只跑一次，忽略了 `-Count` | `-Count > 1` 一律走队列（可合并批次） |
| 两条命令同时提交时互相抢 ComfyUI | 同步路径没有互斥 | 增加 `.jobs/sync.lock` 文件独占锁；拿不到锁自动改走队列 |
| 修复前的日志症状 | 运行中的守护是旧进程（文件改了但没重启） | 守护启动日志增加「加载版本：mtime / 字节数」，一眼看出新旧 |
# v0.3.0 — 快速出图双路线 + 带音频视频 + 显存快照（2026-10-24）

## 新增

- **`scripts/t2i-zimage.ps1`**：Z-Image Turbo 文生图。1024²/8 步 **约 4 秒**；
  支持风格 LoRA（`-Lora` / `-LoraStrength`）与图生图（`-Image` / `-Denoise`）。
- **`scripts/t2i-moss.ps1`**：MOSS-Image 写实人像。1024²/12 步 **10~16 秒**；
  支持叠加风格 LoRA（必须排在 8 步加速 LoRA 之后）。
- **`scripts/ai-video-h3.ps1`**：MiniMax H3 文生视频，**一次出画面 + 32 kHz 立体声**。
  960×540/124 帧约 113 秒，1344×768 约 324 秒。
- **`scripts/lib/vram.ps1`**：显存快照共享模块 —— 生成前快照并停止 Strata / Ollama，
  生成后自动恢复。自适应等待（达标即走、连续 9 秒不增长也走），状态文件独立。
- **`docs/06-new-models-and-vram.md`**：三个新模型的参数与实测、降级策略、显存快照设计、三个必踩坑。

## 变更

- 三个新脚本都内置**失败自动降级**（关 LoRA → 降步数 → 降分辨率），并在日志与参数摘要里标明降了什么。
- 提交阶段捕获 HTTP 4xx：模型名或 LoRA 名写错不再直接崩，而是进入降级。
- `config.sample.ps1` 新增 Z-Image / MOSS / H3 模型键与显存快照配置项。

## 已知限制

- 带音频视频本地最高 768p 短边（模型架构限制，2K 只有云端）。
- 视频 VAE 必须用 fp16 版；int8 量化版会解出全黑画面（音频正常，容易误判成功）。
- 恢复快照是阻塞的：9B 模型约 1~2 分钟，27B 更久；`-KeepChatBackend` 可跳过。
# v0.2.0 — FlashVSR+ 高分辨率超分（2026-10-24）

## 新增

- **`scripts/ai-upscale-flashvsr.ps1`**：FlashVSR+（Triton 稀疏注意力）视频超分脚本。
  832×480 处理 → **1664×896 输出**，121 帧 76 秒；显存峰值 23.3 GB（24GB 卡）。
- `scripts/video.ps1` 新增 `-Method flashvsr` 与 `-Width/-Height` 参数，
  可直接 `-Action upscale -Method flashvsr -Interp 2`（超分 + 插帧）。
- `config.sample.ps1` 新增 FlashVSR+ 模型键（`FlashVSRDit` / `FlashVSRProj` / `FlashVSREmb` / `FlashVSRTcd` / `FlashVSRVersion`）。
- `docs/03-upscale.md` 新增「FlashVSR+ 高分辨率档」章节：为什么必须用 plus + Triton、
  四步安装、参数、实测表、与 SeedVR2 的分工、5 条坑。
- `NOTICE.md` 补充 FlashVSR+ 模型清单与来源。

## 变更

- `organize.ps1` 归类规则把 `flashvsr` 归入 `aiup`（此前会落到 `other`）。

## 实测基线（RTX 5090 Laptop 24GB，121 帧 / 5 秒片）

| 路线 | 输出 | 耗时 | 显存 |
|---|---|---|---|
| Lanczos 1.5× | 1248×720 | 2.3 s | 低 |
| SeedVR2 3B（720p） | 1248×720 | 103 s | 15.9 GB |
| **FlashVSR+（默认档）** | **1664×896** | **76.5 s** | **23.3 GB** |
| SeedVR2 3B（1080p） | 1920×1080 | 265 s | 11.6 GB |

## 兼容性

- 需要 ComfyUI + `ComfyUI_FlashVSR` 节点 + FlashVSR+ 权重 + `flashvsr_attn` Triton 内核。
- `triton-windows` 与 MSVC 即可编译内核，**不需要 CUDA Toolkit**。
- 原版 FlashVSR v1.0/v1.1 走 `block_sparse_attn` C++ 扩展（需 CUDA Toolkit），在 24GB 卡上
  处理分辨率仅约 512×288，**不推荐**；请直接用 plus。

---
# v0.1.0 — 首个公开版本 / First public release

**中文**

把「文生图 → 图生视频 → AI 超分 → 插帧 / 续接 / 拼接」串成一条命令行流水线的工具集。
全部本地推理，不调云端 API。一条命令从一句话走到 720p/48fps 成片（24GB 卡实测 5.9 分钟）。

**English**

A command-line toolkit that chains text-to-image → image-to-video → AI upscaling → frame
interpolation / chaining / concatenation into one local pipeline. No cloud API. One command takes
you from a prompt to a 720p/48fps clip (5.9 min on a 24 GB GPU, measured).

---

## 包含内容 / What's inside

### 13 个脚本

| 脚本 | 作用 |
|---|---|
| `video.ps1` | 统一入口（`-Action t2v/i2v/extend/join/trim/upscale/restyle` + `-Preset draft/fast/final`） |
| `t2i.ps1` | 文生图（Qwen-Image 2.1 Turbo，1024² / 15 秒） |
| `img2img.ps1` | 图生图（强度可控，20~25 秒） |
| `edit.ps1` | 指令编辑（Qwen-Image-Edit-2511，只改指定区域） |
| `i2v.ps1` | 图生视频（Wan 2.2 TI2V-5B，5 秒约 2 分钟） |
| `extend.ps1` | 续接拼长片（取末帧 → 再生成 → 拼接） |
| `concat.ps1` | 多段拼接（自动统一分辨率/帧率） |
| `trim.ps1` | 按秒裁剪 |
| `post.ps1` | Lanczos 放大 + FILM 插帧 |
| `ai-upscale.ps1` | **视频 AI 超分**（SeedVR2 官方 CLI，1080p 自动开 VAE 分块） |
| `img-upscale.ps1` | **图片 AI 超分**（2K / 4K） |
| `restyle.ps1` | 视频改风格（关键帧重绘 + 插帧回填） |
| `organize.ps1` | 输出归位 + 自增编号 + 参数摘要 |

### 5 篇文档 + 1 页速查

- `docs/01-image.md` 文生图 / 图生图 / 指令编辑（含 Turbo sigma 陷阱、强度阈值表）
- `docs/02-video.md` 图生视频 / 文生视频 / 续接（含 **4n+1 帧约束**）
- `docs/03-upscale.md` SeedVR2 安装与超分（含 **1080p 为什么会爆显存**）
- `docs/04-video-edit.md` 拼接 / 裁剪 / 放大 / 插帧
- `docs/05-pitfalls.md` **13 类踩坑清单**
- `assets/cheatsheet.html` 一页速查（可打印）

### 示例与对比图

- `assets/samples/compare-video-upscale.jpg` 视频超分前后 + 局部 ×3 放大
- `assets/samples/compare-pipeline.jpg` 一条命令的三段流水线
- `assets/samples/compare-image-upscale.jpg` 图片 2K → 4K
- `assets/samples/sample-t2i.jpg` 文生图样张

---

## 实测基准 / Benchmarks（RTX 5090 Laptop 24GB）

| 任务 | 规格 | 耗时 | 显存峰值 |
|---|---|---|---|
| 文生图 | 1024², 8 步 | 15 秒 | ~15 GB |
| 图生视频 | 736², 121 帧 | 185 秒 | ~16 GB |
| 文生视频 | 832×480, 5 秒 | 125 秒 | ~16 GB |
| 文生视频 | 1280×720, 5 秒 | 362 秒 | ~20 GB |
| 视频超分 | →720p, 121 帧 | 103 秒 | 15.9 GB |
| 视频超分 | →1080p, 121 帧 | 265 秒 | 11.6 GB |
| 图片超分 | →4K | 102 秒 | — |
| 插帧 ×2 | 121 → 241 帧 | 15~25 秒 | 低 |
| 拼接两段 | 7 秒成片 | 2.5 秒 | CPU |
| **端到端** | 文字 → 720p/48fps | **5.9 分钟** | 16 GB |

核心结论：**草稿用 832×480 生成，满意后超分**——比直接生成 720p 快 2.4 倍，且多了插帧后运动更顺。

---

## 快速开始 / Quick start

```powershell
# 依赖：stable-diffusion.cpp、ComfyUI(+GGUF)、SeedVR2 CLI、Python(av+pillow)
# 模型下载清单与许可证：NOTICE.md

Copy-Item config.sample.ps1 config.ps1     # 填入你的路径

scripts\video.ps1 -Action t2v -Prompt "黄昏海岸的灯塔" -Seconds 5 -Preset draft
scripts\video.ps1 -Action upscale -Video out.mp4 -Preset final
scripts\img-upscale.ps1 -Image still.png -Resolution 2160
```

---

## 已知限制 / Known limitations

1. **不含模型权重**：许可证只允许使用、不允许分发。缺文件时脚本会报错并指向 `NOTICE.md`。
2. **只处理画面，不处理音轨**：Wan 产物本身无音；拼接/裁剪也不保留原音频。
3. **AI 超分 1080p 必须开 VAE 分块**（脚本在 `-Resolution >= 900` 时自动开），否则 24GB 卡解码阶段会崩。
4. **Windows PowerShell 5.1 环境**：含中文的 `.ps1` 必须 UTF-8 **带 BOM**，否则会按 GBK 解析出错。
5. **单卡单任务**：出图 / 视频 / 超分是三套权重，24GB 卡不能并发跑。
6. FILM 帧插值模型的商用许可需自行确认。

---

## 许可证 / Licence

- 本仓库脚本与文档：**MIT**
- 第三方模型与软件：各自许可证，见 `NOTICE.md`（本项目不授予任何模型权重权利）

---

## 致谢 / Credits

- [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp) — 图生文/图生图推理
- [ComfyUI](https://github.com/comfyanonymous/ComfyUI) — 视频生成与插帧后端
- [ComfyUI-SeedVR2_VideoUpscaler](https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler) — 超分核心与 CLI
- [Wan 2.2](https://huggingface.co/Comfy-Org/Wan-2.2) / [Qwen-Image](https://huggingface.co/Qwen) 模型方

---

## 下一步 / Roadmap

- [ ] MiniMax H3（带音频的视频）接入
- [ ] Z-Image ControlNet 构图控制脚本化
- [ ] 英文文档补全（scripts 注释）
- [ ] Linux / macOS 适配（去除 PowerShell 依赖的替代实现）

**完整变更**：`git log --oneline`
