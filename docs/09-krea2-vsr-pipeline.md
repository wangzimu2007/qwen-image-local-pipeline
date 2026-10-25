# v0.5.0 新增：Krea 2 / RTX VSR / 流水线

本页记录 2026-10-25 新增的三块能力：**Krea 2 出图模型**、**英伟达 RTX VSR 硬件超分**、
**配方驱动的媒体流水线**。

---

## 一、Krea 2 Turbo（12B 稠密 DiT）

### 它是什么

| 项 | 内容 |
|---|---|
| 架构 | 12B 稠密 DiT + **Qwen-Image VAE** + **Qwen3-VL 4B 文本编码器**（多层级特征聚合）|
| 版本 | **Turbo**（8 步蒸馏）/ **RAW**（未蒸馏，供 LoRA 训练）|
| 许可 | `krea-2-community-license`（商用前必须看 LICENSE）|
| ComfyUI | ≥ 0.26 原生支持（`CLIPLoader type=krea2`）|

### 下载清单（Comfy-Org/Krea-2）

| 文件 | 体积 | 说明 |
|---|---|---|
| `krea2_turbo_nvfp4.safetensors` | 7.15 GB | Blackwell 最优量化 |
| `krea2_turbo_fp8_scaled` | 12.24 GB | fp8 备选 |
| `qwen3vl_4b_fp8_scaled.safetensors` | 4.88 GB | **文本编码器（必装）** |
| `qwen_image_vae.safetensors` | 0.24 GB | 与 Qwen-Image 共用 |
| 11 个风格 LoRA | 各 0.44 GB | 水彩/动漫/霓虹/雨窗/日落/暗刷/点阵/蜡笔/塔罗/风格参考/加速 |

### 实测（RTX 5090 Laptop 24 GB，1024²）

| 场景 | 耗时 | 显存峰值 |
|---|---|---|
| 冷启动（含加载 12B 权重 + 编码器）| 33.6 秒 | 17.8 GB |
| **热启动 8 步** | **3.1 秒** | 17.1 GB |
| 带 LoRA 首次（换 LoRA 有加载开销）| 12.1 秒 | 18.2 GB |

**采样参数**：8 步 / cfg 1.0 / `euler` + `simple`；负面用 `ConditioningZeroOut`。

### 定位

- ✅ 审美与风格广度：编辑级人像、动漫、水彩、霓虹、复古
- ❌ 中文理解弱（编码器只有 4B），**不要拿它画中文字**
- ⚠️ `qwen3vl_4b` 与 Qwen-2512 的 `qwen_2.5_vl_7b` **不通用**，两套都要留（多占 4.9 GB）

---

## 二、RTX VSR（英伟达硬件超分）

### 它是什么

驱动级 AI 超分（NGX VSR）的 ComfyUI 节点版本，可以放图片和视频帧批次。

| 项 | 内容 |
|---|---|
| 节点 | `RTXVideoSuperResolution`（`ComfyUI_Nvidia_VFX_Nodes`）|
| 依赖 | `pip install nvidia-vfx`（装进 ComfyUI 的 venv）|
| 放大 | 1×~4×，或指定目标尺寸（**吸附到 8 的倍数**）|
| 质量 | LOW / MEDIUM / HIGH / **ULTRA** |

### 实测（1024² → 2× / 4×）

| 场景 | 耗时 | 显存峰值 |
|---|---|---|
| 2× ULTRA（首次，含 SDK 初始化）| 14.6 秒 | 18.2 GB |
| **4× ULTRA（热启动）** | **2.85 秒** | 18.4 GB |

### 关键定位：插值器 ≠ 恢复器

同一张 1024 人像做 2× 三方对比（`qwen-0113-超分对比.png`）：

| 方案 | 观感 | 会不会补细节 | 耗时 |
|---|---|---|---|
| Lanczos | 发软 | ❌ | <1 秒 |
| **RTX VSR** | 干净、自然 | ❌ **不补毛孔/发丝**（忠实原图）| 3~15 秒 |
| SeedVR2 | 锐、细节多 | ✅ 会补 | 46.4 秒/张 |

### API 两个坑（走 `/prompt` 提交时）

| 坑 | 正确写法 |
|---|---|
| 动态下拉参数键名 | `"resize_type.scale": 2.0`（**不是嵌套对象**）|
| 像素编码枚举 | `"image_encoding": "8-bit RGB"`（写 `8-bit` 会校验失败）|

工作流：`workflows/rtx-vsr-image-upscale.json`、`workflows/rtx-vsr-video-upscale.json`

---

## 三、媒体流水线（配方 + 执行器）

把 40+ 个一次性脚本按 **JSON 配方**串起来跑，每步留日志、整任务留 manifest。

| 文件 | 作用 |
|---|---|
| `scripts/pipeline.ps1` | 执行器：读配方 → 逐步调用 → 记录 manifest |
| `scripts/pipeline-interactive.ps1` | 交互入口（列配方、填参数、DryRun）|
| `scripts/lib/mksrt.py` | 按文案 + 视频时长生成 srt（无语音的视频用它配字幕）|
| `recipes/*.json` | 4 个配方 |

### 4 个配方

| 配方 | 链路 | 适用 |
|---|---|---|
| `image-caption-video` | 图生视频 → 按文案生成 srt → ffmpeg 烧字幕 | 一张图 + 一段文案 → 带字幕短片 |
| `h3-captions` | H3 出片（带音频）→ 转录 → 烧字幕 | 要音画同步 + 字幕 |
| `image-fullchain` | Z-Image 出图 → PiD 4× → 图生视频 → AI 超分 720p | 从一句话到成片 |
| `audio-chain` | 分离 → 降噪 → 转录 → 转 MIDI | 处理歌曲/录音 |

### 用法

```powershell
# 真跑
pipeline.ps1 -Recipe image-caption-video -Set "Image=C:\a.png;Text=第一句。第二句。"

# 只看命令
pipeline.ps1 -Recipe image-caption-video -Set "Image=..." -DryRun

# 只跑部分步骤 / 断点续跑
pipeline.ps1 -Recipe audio-chain -Set "Audio=x.wav" -Only "denoise,subtitle"
pipeline.ps1 -Recipe audio-chain -Set "Audio=x.wav" -Out my-task -Resume
```

### 实测

| 场景 | 结果 |
|---|---|
| 音频链（denoise + subtitle 两步）| **10.6 秒**（降噪 7.0 + 转录 3.2）|
| Resume 跳过已完成步骤 | ✅ 正确跳过 |
| DryRun 打印全部命令 | ✅ |

### 三个设计要点

1. **无声视频不能"转录出字幕"** —— Wan 图生视频是无声的，字幕必须来自文案（`mksrt.py`）
2. **shell 步骤写成临时 `run.ps1` 再 `-File` 执行** —— 直接拼 `-Command` 会因引号嵌套崩
3. **`-Set` 用分号分隔的单个字符串** —— `-Set a -Set b` 会报 "parameter specified more than once"

**烧字幕依赖 ffmpeg**（本机 `D:\tools\ffmpeg\bin`，9.0.2，已加进用户 PATH）。

---

## 四、附带的两个工具

| 文件 | 作用 |
|---|---|
| `scripts/lib/pngmeta.py` | 给 PNG 写/读文本元数据（模型、提示词、参数、许可）|
| `scripts/lib/meta.ps1` | `Write-MediaMeta` 封装，脚本里一行调用即可 |

**每张图自带溯源元数据**：`Model` / `Prompt` / `Steps` / `Cfg` / `Seed` / `Size` / `Ops` / `License` / `GeneratedBy` / `GeneratedAt`。
PixelDiT、PiD 这类有许可限制的模型会额外写 `License` 字段。
### Krea LoRA 调度（16 个，四类）

| 类 | 名称 | 建议权重 | 用法 |
|---|---|---|---|
| 风格（10） | softwatercolor / retroanime / neondrip / rainywindow / sunsetblur / darkbrush / dotmatrix / kidsdrawing / vintagetarot / style_reference | 0.7~0.9 | `-Lora softwatercolor` |
| 人物（3） | aikasawaguchi / aoiharu / ayakamiyoshi | 0.85~0.95 | `-Lora aoiharu`（触发词自动补） |
| 编辑（2） | identity_edit_v2_r64 / general_edit_v2_r64 | 1.0 | 工作流 `Krea2-身份编辑.json` |
| 加速（1） | turbo_lora_rank_64_bf16 | 1.0 | 一般不用 |

**组合规则**：

1. 人物 + 风格可叠加，但要降权：人物 0.85~0.95 + 风格 0.6~0.75（合计 ≤ 1.7）
2. 两个风格 LoRA 不要同时开（互相打架、画面变糊）
3. identity_edit 与 general_edit 不能都上 1.0（同源谱系，会变纯重着色）；一次任务只用一个

**身份编辑参数**（Turbo 8 步 / cfg 1.0）：

| 任务 | ref_boost | grounding_px | Placement |
|---|---|---|---|
| 换场景（单参考） | 2 | 768 | beside / aligned |
| 场景 + 加人（场景=图1、人=图2） | 人 2~3、场景 1 | 768 | 场景 aligned |
| 锁脸人像 | 1~2 | 768 | aligned |

提示词要点：写清露多少身体、具体服装、明确"去掉什么"。

**触发词**：`aikasawaguchi → aika_sawaguchi`、`aoiharu → aoi_haru`、`ayakamiyoshi → ayaka_miyoshi`（脚本自动补，别手写）。