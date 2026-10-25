# v0.3.4 — 修图工具箱 + 显存体检 + 会话模式（2026-10-25）

## 新增

- **`scripts/img-edit.ps1`** + `lib/imgops.py`：**确定性的图片小修小改**，纯 CPU 不占显存，单张 0.1~1 秒。
  20 多个 op：裁剪 / 缩放 / 调色 / 区域调色（`boxcolor`）/ 文字与水印 / 拼图 / 转格式 / EXIF。
- **修补类 op**（超分灰块、瑕疵、杂物）：
  `erase`（OpenCV inpaint）、**`blurfill`**（平滑区首选，实测痕迹最小）、
  `clone`（邻近克隆）、`heal`（谐波填充，实验性）。
- **`scripts/lib/imgerase.py`**：OpenCV 修补后端（可指定带 cv2 的 Python）。
- **`scripts/vram-check.ps1`**：显存体检 —— 谁占着、目标模型够不够、`-Kill` 强制释放。
  内置门槛：zimage 13.7 / moss 14.6 / seedvr2 14.6 / wan 15.6 / h3 20.5 / flashvsr 21.5 GB。
  **过滤 dwm/csrss 等系统进程的假数据**（WDDM 下会虚报十几到二十 GB）。
- **`scripts/session-start.ps1` / `session-end.ps1`**：会话模式 —— 批量出图只换入换出一次模型，
  避免每张都付"卸载 + 恢复"的一两分钟。

## 变更

- `config.sample.ps1` 新增 `PythonExe`（修图脚本用；留空自动探测）。
- `img-edit.ps1` 的 `erase` 会自动找带 cv2 的 Python，找不到只警告不崩。

## 文档

- skill（`skills/text-to-image`）扩到 25.7 KB：7 条调用规则 + 失败排查 + **显存不足三步法（含体检判定逻辑）**
  + **附录 A 修图与超分技术栈**（含 LaMa 弯路复盘、超分灰块处置流程）。
- 速查页新增「改图 / 编辑：先判断再动手」章节。

## 已知限制

- `heal`（谐波填充）实现不稳定，暂时优先用 `blurfill`。
- LaMa ONNX 曾跑通但填充质量不达标（剪影残留/边缘发脏），未纳入主线，代码留在本地备用。
- 超分单次放大 >2× 易在低纹理区产生方形灰块 → 已在流程里改为两步走（AI ~1.5× + Lanczos）。
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

## v0.6.4 — 2026-10-25

### 新增：多后端自动识别（Strata / Ollama / NInfer）

- `scripts/lib/backend.ps1`：读取 DSH 默认模型 → 判断当前后端类型（strata-local / ollama-local / ninfer-local）
- `scripts/status.ps1`：状态页列出**全部三个后端**并标出「← DSH 当前」
- `scripts/lib/strata-tray.cs`：托盘改为读通用状态（自动跟随 DSH 模型切换）
- Keeper 通用化：批末写 `backends-wanted.json`，watchdog 对每个被卸载的后端调 `Start-LocalBackend`
- `docs/12-multi-backend.md`

### 实测

| 场景 | 结果 |
|---|---|
| 自动识别 | `strata-local / qwen3.8-flash-next-iq3_s` → strata :8080 serving，variant=iq3s |
| 完整队列作业 | 卸载 27.1s + 出图 74.5s + 恢复 59.6s = **167.6 秒** |
| Keeper 拉回 Ollama | **3 秒**（`拉回本地后端 ollama（: 11434）`）|
| 托盘 | 出图中 → 恢复中 → 就绪，详情带模型名 |

### 说明

在 DSH 里切换模型（Strata / Ollama / NInfer），状态页、托盘、Keeper **自动跟随**，无需改配置。

## v0.6.3 — 2026-10-25

### 新增：画图任务结束后自动拉回 Strata

- `job-worker.ps1`：批末恢复后写标记 `.jobs\strata-wanted.json`；若 8080 仍未监听则**二次拉起**
- `win-watchdog.ps1`：新增 `Invoke-StrataKeeper`，每 30 秒检查
- **四条触发条件**：队列为空 + 标记 15 分钟内 + 8080 不在 + 启动脚本存在
- 实测：手动停掉 Strata → watchdog 检查 **39 秒内拉回**；有作业在跑时**绝不触发**（不抢显存）

### 修复

| bug | 现象 | 修复 |
|---|---|---|
| **成品标签不统一** | `编辑.ps1` 打印「编辑完成：」，而守护只认「成品：」→ 图已生成却判 failed | 放宽为 `成品/编辑完成/超分完成/视频完成/输出文件` |
| **任务参数不匹配** | `-Task krea2 -Image x` → Krea2 无此参数 → 白跑 63 秒卸载+恢复 | **提交前校验参数**：0.28 秒拒绝并给替代方案（改图用 `-Task edit`）|
| **脚本自己又卸载/恢复一遍** | 重复恢复多花 ~45 秒 | 守护调用脚本时传 `-KeepChatBackend` |
| **守护缺失时模型自行兜底** | 模型用 `Start-Process` 直接出图 → 卸载自己 → TRANSPORT | skill 三条禁令 + 提示用户点「守护 - 全部启动」 |

### 实测

| 场景 | 数据 |
|---|---|
| 队列作业（zimage） | 卸载 23.1s + 出图 62.6s + 恢复 44.7s = **136 秒**，8080 自动回来 |
| Strata 又被停 → keeper | **39 秒**拉回 |
| Krea2 出图（水彩 LoRA） | 37 秒 |
| 参数错误 | **0.28 秒**拒绝，不占用队列/显存 |

## v0.6.2 — 2026-10-25

### 新增：关思考代理（本地模型提速 2~3 倍）

- `scripts/think-off-proxy.py` + `docs/11-think-off-proxy.md`
- 根因：Strata 上的 Qwen3.8-Flash-Next 默认思考模式，实测 600 token 预算会被推理吃光、
  **正文 0 字**，上层收不到回复而重试 → 表现为"一直在思考"
- 代理在 8081 注入 `enable_thinking=false` 后转发 8080：工具调用场景 **7.39 → 3.28 秒（2.25×）**
- watchdog 增加**端口型守护**：8081 掉了自动拉起（实测 1 秒内）

### 修复（v0.6.0 之后又发现）

| bug | 现象 | 修复 |
|---|---|---|
| 作业 ID 撞车 | 同秒提交多个作业 → 同名覆盖，丢作业 | ID 加毫秒 + 随机后缀 + 冲突检测 |
| 内存/页面文件不可见 | 不知道卸载是否真的释放内存 | 批前/卸载后/恢复后各打一次内存与页面文件 |
| 恢复"假就绪" | 端口通了但模型没加载完 | 恢复后发一次 `max_tokens=1` 推理探针，失败重试 1 次 |

### 实测汇总

| 场景 | 数据 |
|---|---|
| Strata 资源画像 | 显存 21.4 GB；卸载后释放物理内存 50 GB、页面文件 92→19 GB；模型文件 78~128 GB |
| 3 作业一批 | 卸载 18.1s + 出图 63.2/78.5/78.6s + 恢复 40.6s = **284 秒** |
| 关思考（工具调用） | 7.39 → **3.28 秒** |
| 关思考（问答） | 0.66~0.79 → **0.29 秒** |

## v0.6.0 — 2026-10-25

### 新增：作业队列（本地聊天模型安全出图）

**问题**：本地聊天模型（Strata/Ollama）占 15~22 GB 显存，出图脚本为腾显存会把**正在服务你的模型**
卸载 → 对话断线（`TRANSPORT Connection error`），且恢复步骤无人执行。

**方案**：把卸载交给独立守护进程，聊天模型只提交作业。

| 文件 | 作用 |
|---|---|
| `scripts/submit-job.ps1` | 聊天模型入口：显存够→同步出图（`-KeepChatBackend`）；不够→写队列立即返回 |
| `scripts/job-worker.ps1` | 守护进程：快照→卸载→出图→关引擎→恢复→写结果 |
| `docs/10-job-queue.md` | 架构、任务表、实测、参数兼容坑、运维 |

**硬防护**：`_vram.ps1` 新增 `Get-DshActiveModel` / `Test-IsDshActiveBackend`，
要卸载"DSH 当前默认模型"时**直接拒绝**（除非 `PIPE_ALLOW_SELF_UNLOAD=1`，只有守护进程设置）。
本地模型误调出图脚本只会得到中文报错，**不会断线**。

### 实测

| 项 | 结果 |
|---|---|
| 提交时可用显存 | 0.9 GB（Strata 占 22.5 GB）|
| 判定 | 不足 13.7 GB → 排队，聊天模型未动 |
| 守护执行 | 卸载 → Z-Image 8 步出图 → 关引擎 → 恢复 Strata |
| 总耗时 | **144.9 秒**（恢复 Strata 约 60 秒）|
| 恢复校验 | 8080 恢复 ✅ / 8188 已关 ✅ |

### 附带

- Krea 2 LoRA 调度：16 个 LoRA 分四类（风格/人物/编辑/加速），`krea2-t2i.ps1` 支持
  `-Lora "aoi_haru:0.9,softwatercolor:0.7"` 多 LoRA 串联 + 人物触发词自动补
- `docs/09-krea2-vsr-pipeline.md` 补齐 LoRA 组合规则与身份编辑参数表

### 工作流与上下文

- 新增工作流：`krea2-identity-edit`（身份编辑，需 comfyui-krea2edit 节点）
- AGENTS.md 从 79 KB 精简到 ~15 KB（历史实测移入 `docs/local-env-archive.md`），
  每轮固定开销从 ~29k token 降到 ~16k

## v0.5.0 — 2026-10-25

### 新增：Krea 2 + RTX VSR + 媒体流水线

- `scripts/krea2-t2i.ps1` — Krea 2 Turbo 出图（12B DiT，11 个风格 LoRA）
- `scripts/pid-upscale.ps1` — PiD 4× 超分（1024→4096，非商业）
- `scripts/pixeldit-t2i.ps1` — PixelDiT 1.3B 像素空间出图
- `scripts/inpaint.ps1` — Z-Image 局部重绘/去物
- `scripts/close-comfyui.ps1` — 一键关闭所有 ComfyUI 引擎
- `scripts/pipeline.ps1` + `pipeline-interactive.ps1` + `recipes/` — 配方驱动流水线
- `scripts/lib/mksrt.py` / `pngmeta.py` / `meta.ps1` — 字幕生成与元数据溯源
- `docs/09-krea2-vsr-pipeline.md`、`skills/media-pipeline`

### 实测

| 场景 | 耗时 | 显存 |
|---|---|---|
| Krea 2 热启动 8 步 | **3.1 秒** | 17.1 GB |
| RTX VSR 4× 热启动 | **2.85 秒** | 18.4 GB |
| SeedVR2 2× 单图 | 46.4 秒 | 15.9 GB |
| PiD 4×（1024→4096）| 12~37 秒 | 19.9 GB |
| 流水线音频链（2 步）| 10.6 秒 | — |

### 关键结论

- **RTX VSR 是插值器不是恢复器**：干净自然但**不补细节**；要补细节仍用 SeedVR2
- **Krea 2 中文弱**：画中文字仍用 Qwen-2512；编码器（qwen3vl_4b）与 Qwen 的 7B 不通用
- **无声视频配字幕**要靠文案（`mksrt.py`），不能指望转录

## v0.4.0 — 2026-10-25

### 新增：音频处理七件套

- `scripts/audio/` 下 7 个脚本：分离 / 克隆 / 转录 / 分人 / 降噪 / 超分 / MIDI
- `docs/08-audio.md`：工具选型、实测速度、四个必踩的坑
- `skills/audio-processing/SKILL.md`：给 AI 助手用的音频技能包

### 关键修复（实测踩坑）

| 坑 | 现象 | 修复 |
|---|---|---|
| ctranslate2 是 CUDA 12 构建 | `cublas64_12.dll is not found` | 借用 cu12 的 `torch\lib` 进 PATH |
| hf-mirror 不支持 Xet CAS | 下载 401 | `HF_HUB_DISABLE_XET=1` |
| faster-whisper 解码与 PyAV 版本冲突 | `metadata_errors` TypeError | 自己用 `av.AudioResampler` 解码成数组 |

### 实测

| 任务 | 输入 | 耗时 |
|---|---|---|
| 转录 large-v3-turbo | 10 秒中文 | **2.6 秒** |
| 人声分离 Demucs v4 | 10 秒 | **7.0 秒** |

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
