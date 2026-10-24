# 本机环境参考（脱敏版）

这份文档把"在什么机器上、装了什么、怎么排布、踩过哪些坑"整理成可复现的说明。
**所有路径都是占位形式**，实际位置按你的机器来改 `config.ps1`。

## 1. 基线硬件

| 项 | 本项目实测环境 |
|---|---|
| GPU | RTX 5090 Laptop，**24 GB** 显存（sm_120 / Blackwell） |
| 内存 | 64 GB（32×2） |
| 系统 | Windows 11，**非管理员** shell |
| Shell | Windows PowerShell **5.1**（不是 PowerShell 7） |
| 磁盘 | 模型与项目分盘放置（模型盘常年 100 GB+） |

> PowerShell 5.1 有两个必须知道的行为：**中文脚本必须 UTF-8 带 BOM**；
> `$x.Count` 在单元素时返回 `$null`，集合计数一律写 `@($x).Count`。

## 2. 显存预算（24 GB 卡的分配）

| 任务 | 峰值显存 | 与谁互斥 |
|---|---|---|
| Qwen-Image 2.1 Turbo（sd.cpp 出图） | ~15 GB | 本地聊天模型 |
| Qwen-Image-Edit-2511（指令编辑） | ~18 GB | 本地聊天模型 |
| Qwen-Image-2512（ComfyUI 文生图） | ~14 GB | 同上 |
| Z-Image Turbo（+LoRA） | ~14 GB | 同上 |
| MOSS-Image | ~15 GB | 同上 |
| Wan 2.2 5B 图生/文生视频 | ~16 GB | 同上 |
| **MiniMax H3（带音频视频）** | **20~23 GB** | **几乎所有东西** |
| SeedVR2 720p 超分 | ~16 GB | — |
| SeedVR2 1080p 超分（开 VAE 分块） | ~12 GB | — |
| **FlashVSR+ 高分辨率超分** | **~23 GB** | **几乎所有东西** |
| 本地聊天模型（27B Q4） | ~20 GB | 全部出图/视频任务 |

**结论**：24 GB 上「生成」和「聊天」不可能同时跑。所以脚本都内置**显存快照**：
生成前停掉聊天模型，生成后按快照恢复（见 `docs/06-new-models-and-vram.md`）。

## 3. 引擎与端口

| 引擎 | 端口 | 用途 |
|---|---|---|
| stable-diffusion.cpp（`sd-cli`） | 无 HTTP 端口（进程式） | Qwen 系出图 / 改图 / 指令编辑 |
| ComfyUI A（桌面版） | **8188** | Z-Image |
| ComfyUI B（自建版） | **8188** | MOSS-Image |
| ComfyUI C（整合包/秋叶版） | **8189** | Wan 2.2 / H3 / FILM / FlashVSR |
| SeedVR2 官方 CLI | 无（进程式） | 视频/图片超分 |

### 三条硬规则

1. **A 和 B 抢同一个端口** —— 同一时间只能开一个。切换前必须停掉另一个。
2. **C（8189）与 A/B 互斥** —— 都吃满显存。
3. **判断"端口上是谁"不能只看端口开着** —— 要查引擎身份：

```powershell
# 各自引擎里是否有自己需要的模型
Invoke-RestMethod "http://127.0.0.1:8188/object_info/UNETLoader" |
  Select-Object -ExpandProperty UNETLoader |
  Select-Object -ExpandProperty input |
  Select-Object -ExpandProperty required |
  Select-Object -ExpandProperty unet_name | Select-Object -First 1
```

看返回列表里有没有 `z_image*`（桌面版）或 `moss_image*`（自建版）。
只看端口会把请求发给错误的引擎，报 `value_not_in_list`。

## 4. 模型清单（按能力分类）

> 全部不随仓库分发；体积来自官方仓库，放哪个盘都行，改 `config.ps1` 即可。

### 出图

| 模型 | 体积 | 说明 |
|---|---|---|
| Qwen-Image 2.1 Turbo GGUF（+ 独立文本编码器 + VAE） | ~9 GB + 7 GB | sd.cpp 用，中文理解好 |
| Qwen-Image-2512 GGUF | ~9.3 GB | ComfyUI 文生图 |
| Qwen-Image-Edit-2511 GGUF + Qwen2.5-VL 编码器 + VAE | ~18 GB | 指令编辑 |
| Qwen2.5-VL fp8 编码器（ComfyUI 专用） | ~8.7 GB | **ComfyUI 里不能用 GGUF 版编码器** |
| Z-Image Turbo（nvfp4 去重器 + Qwen3-4B + ae VAE） | ~12 GB | 4 秒出图 |
| MOSS-Image（int8 去重器 + Qwen3.5-9B w4a8 + flux2 VAE） | ~12 GB | 写实人像 |
| 风格 LoRA（各 130~150 MB） | — | 按底座配对，**不能跨模型** |

### 视频

| 模型 | 体积 | 说明 |
|---|---|---|
| Wan 2.2 TI2V 5B（+ umt5 编码器 + VAE） | ~10 + 6.3 + 1.3 GB | 图生/文生视频，无音频 |
| MiniMax H3（int8 去重器 + Qwen3-VL nvfp4 + 视频/音频 VAE + Turbo LoRA） | ~19.5 + 14.6 + 5.4 GB | **带音频**，768p 上限 |
| FILM 插帧 | 66 MB | 24→48fps |
| SeedVR2 3B（nvfp4 + VAE） | 1.9 + 0.5 GB | 超分 |
| FlashVSR+（turbo DiT + proj + TCDecoder + posi_prompt） | ~6.8 GB | 高分辨率超分（1664×896） |

### 省的技巧：硬链接复用

同一块盘上用**硬链接**把模型接进多个引擎的 `models\`，不重复占空间：

```powershell
New-Item -ItemType HardLink -Path "D:\ComfyA\models\diffusion_models\z.safetensors" `
  -Target "D:\models\z_image_turbo_nvfp4.safetensors"
```

## 5. 磁盘规划建议

| 内容 | 建议位置 |
|---|---|
| 模型权重 | 单独的大容量盘（100 GB+） |
| 推理引擎 / 项目代码 | 系统盘或工具盘 |
| 输出图片/视频 | 桌面或独立媒体目录 |
| 临时文件 | `%TEMP%`，用完即删 |

本项目所有脚本都通过 `config.ps1` 的键指向路径，不写死盘符。

## 6. 依赖与版本

| 组件 | 注意点 |
|---|---|
| Python | ComfyUI 各引擎用自己的 venv；**不要把它们的包混装到系统 Python** |
| PyTorch | Blackwell（sm_120）需要 **CUDA 12.8 / 13.0** 对应轮子；PyPI 默认是 CPU 版 |
| 装包策略 | 补依赖时用 `--no-deps`，否则会把 torch 升掉（实测会把引擎搞坏） |
| Python 库（媒体） | `av`（PyAV，抽帧/合成）、`pillow`、`opencv-python` |
| Node/其它 | 无关 |

## 7. 时间预算（实测，24 GB 卡）

| 任务 | 耗时 |
|---|---|
| Z-Image 1024²/8 步 | 4 秒 |
| Z-Image 832×1216 + LoRA | 5~6 秒 |
| MOSS 1024²/12 步 | 10~16 秒 |
| Qwen-Image Turbo 出图 | ~15 秒 |
| Qwen-Image-Edit 指令编辑 | ~190 秒 |
| Wan 2.2 480p/5 秒 | 125 秒 |
| Wan 2.2 720p/5 秒 | 362 秒 |
| **H3 960×540/5 秒（带音频）** | 113 秒 |
| **H3 1344×768/5 秒（带音频）** | 324 秒 |
| SeedVR2 →720p/121 帧 | 103 秒 |
| SeedVR2 →1080p/121 帧 | 265 秒 |
| FlashVSR+ →1664×896/121 帧 | 76 秒 |
| FILM 插帧 ×2 | 15~25 秒 |
| 拼接 / 裁剪 / Lanczos 放大 | 1~3 秒 |
| **本地聊天模型恢复**（9B / 27B） | 1~2 分钟 / 3 分钟级 |

## 8. 复现检查清单

跑之前按这个顺序过一遍，能省掉大部分报错：

1. **模型齐不齐**：按 `NOTICE.md` 清单对；缺一个就报"missing model"
2. **端口空不空**：`Test-NetConnection 127.0.0.1 -Port 8188`，以及 8189
3. **显存够不够**：`nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits`，
   出图要 ≥12 GB、H3/FlashVSR 要 ≥20 GB
4. **配置对不对**：`config.ps1` 里的模型名必须是 **ComfyUI 下拉框里显示的名字**（不是文件名路径）
5. **脚本编码**：中文 `.ps1` 必须是 UTF-8 带 BOM，否则 PS 5.1 按 GBK 读会报一堆语法错误
6. **语法先过**：
   `[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$null,[ref]$errs)`

## 9. 出问题先看哪

| 症状 | 先看 |
|---|---|
| `value_not_in_list` | 模型名/ LoRA 名不在下拉框里；或端口上是错误的引擎 |
| 画面全黑 / 全灰 | 解码坏了（视频 VAE 用错量化版）；抽帧算亮度方差确认 |
| `CUDA out of memory` | 显存不够；先停聊天模型、降分辨率或降批大小 |
| 中文脚本报语法错误但内容正常 | 缺 UTF-8 BOM |
| `missing_node_type` | 自定义节点没装上或 import 失败（看引擎日志） |
| 出图很慢但显存没满 | 引擎在 CPU offload；确认 CUDA 可用、torch 是 CUDA 版 |

更多细节见 [docs/05-pitfalls.md](05-pitfalls.md)，各模块专属坑见对应文档。
