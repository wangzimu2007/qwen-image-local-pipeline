---
name: text-to-image
description: 文生图skill（本地文生图/改图/指令编辑/风格化）：本地四套出图模型（Qwen-Image Turbo、Qwen-2512、Z-Image Turbo + KOOK 朦胧 LoRA、MOSS-Image）按需求自动选型，出图、图生图、指令编辑、图片超分 via the one-shot scripts in D:\qwen-image-2.1, which snapshot running local models, free VRAM, generate, then restore them. Use for 画图、出图、改图、编辑图片、换风格、朦胧、梦幻质感、写实人像 requests.
---

# 本地出图：先选模型，再调脚本

**核心原则：先判断走哪条路线（见第 1 节路由表），再调对应脚本。不要自己推导模型参数或显存快照逻辑** ——
每个脚本都已实现「快照 → 停本地模型 → 出图 → 自动恢复」。显存是硬约束：24 GB，出图栈吃 14~18 GB，
与 Strata（约 22 GB）、Ollama 大模型互斥。

## 0. 调用协议（每次出图前先按这三条判断）

### 规则 1：用户点名了模型 → 强制用它，不改道

| 用户可能说 | 锁定用 |
|---|---|
| Z-Image / Z图 / 朦胧 / 梦幻 / 雾感 | Z-Image Turbo（+ KOOK 朦胧 LoRA） |
| MOSS / 莫斯 / 观澜 / 写实人像 / 时尚写真 | MOSS-Image（+ KOOK 观澜 LoRA） |
| Qwen / 千问 / Qwen-Image | `画图.ps1` |
| 编辑 / Edit / 2511 / 指令编辑 | `编辑.ps1` |
| H3 / MiniMax / 带声音的视频 | `文本生视频H3.ps1` |
| Wan / 万相 / 图生视频 | `图生视频.ps1` / `视频.ps1` |
| SeedVR2 / FlashVSR / 超分 / 超高清 | 对应的超分脚本 |

- 点名后**不要**因为风格词命中别的模型而改道；只在该模型内部调参数。
- 若点名模型**干不了**这件事（例如让 Z-Image 做指令编辑、让 Wan 出声音）→
  明确说「该模型不支持 X」，给出替代命令，**不要静默换模型**。

### 规则 2：没点名 → 按「速查页」路由检索

顺序：① 有没有输入图？② 风格词命中哪个模型？③ 中文长句/要文字？④ 都没命中 → Z-Image 先出 4 秒样图。
完整表格见第 1 节（与桌面速查页同源，改一处要同步另一处）。

### 规则 3：提示词处理 —— 挂在「选完模型之后、调脚本之前」

| 情况 | 做法 |
|---|---|
| 用户描述已经清楚 | **直接跑，不扩写**（省时间，扩写对短提示词无增益） |
| 只有很短一句（<15 字，无风格/场景） | 脚本内做**轻量补全**到 60~140 字（结构见下），**不要**加载长扩写 skill |
| 用户明说「扩写 / 详细提示词 / 帮我写提示词」 | 调 `fisher-moss-prompt-expander`（产出 1500~2500 字），再**压缩成 200~400 字**喂模型 |
| 视频（Wan / H3） | **不扩写画面**，只补「运动 + 声音」词 |
| 图生图（`-Image`） | **不扩写场景**，只写氛围/风格，否则会覆盖原构图 |

轻量补全的结构（**按模型定制，不能通用一套**）：

- **Z-Image**：主体 + 氛围光线 + 风格词（朦胧/胶片/低饱和）+ 介质
- **MOSS**：主体 + 摄影术语（85mm f1.8 / 自然光 / 皮肤纹理 / film grain）
- **Qwen**：一整句中文（时间 / 地点 / 天气 / 材质 / 镜头）
- **H3**：画面 + 声音（海浪声 / 鸟鸣 / 风声 / 脚步）+ 镜头运动
- **视频运动**：只写怎么动（推进 / 摇镜 / 风吹），不重复画面内容

**为什么扩写挂在这里而不是更早/更晚**：早于选型 → 不知道按哪套结构写；晚于提交 → 提示词已经进图了。
所以流程固定为：**路由 → 按模型补全提示词 → 调脚本**。
### 规则 4：失败自动降级（脚本内置，不用你操心）

| 脚本 | 降级顺序 | 实测 |
|---|---|---|
| `Z画图.ps1` | 原配置 → **关闭风格 LoRA** → 分辨率 ×0.75 → 两者都降 | LoRA 名写错 → 自动关 LoRA 后 7.3 秒出图 |
| `MOSS画图.ps1` | 原配置 → 步数 12→8 → 步数 8 + 分辨率 ×0.8 → 关闭风格 LoRA | 同上机制 |
| `文本生视频H3.ps1` | 原尺寸 → 960×540 → 640×360 | 同上机制 |

- 每个尝试都会打印「尝试：xxx」和失败原因；成功但降过级会打印 **「已自动降级：xxx」**，参数摘要里也带 `降级` 字段。
- 想要"宁可失败也不要降级"：加 `-NoFallback`。
- 提交阶段的 4xx（如 LoRA 名不在列表）也会被捕获并进入降级，不会直接崩。
### 规则 5：显存快照（画图前停本地模型，画完自动恢复）

> 新写脚本要接入这套机制时，看 `D:\qwen-image-2.1\_新脚本接入显存快照.md`（含 4 行模板、三种引擎样板、三个必踩坑、验收清单）。

`Z画图.ps1` 与 `MOSS画图.ps1` 会共用 `D:\qwen-image-2.1\_vram.ps1`：

1. **快照**当前在服务的本地后端（Strata 8080 按模型 id 区分 IQ3_S/NVFP4；Ollama 11434 读 `/api/ps`）
2. **释放**：Strata 走 `stop-*.cmd`；Ollama 用 `keep_alive: 0` 卸载
3. **自适应等待**显存（达标即继续；连续 9 秒不再增长且 ≥9 GB 也继续，不傻等）
4. 出图
5. **恢复**：Strata 用 `start-*.cmd` 等最多 420 秒；Ollama 用 `keep_alive: 30m` 重新加载
6. 清理快照文件（成功/失败/异常三个路径都清）

| 开关 | 作用 |
|---|---|
| 默认 | 自动快照 → 释放 → 恢复 |
| `-KeepChatBackend` | 跳过快照与恢复（确认显存够用时） |

**实测（2026-10-24）**：Ollama 里装着 `qwen3.5:9b`（7.6 GB）时跑 Z-Image 832×1216 ——
自动卸载 → 3.6 秒出图 → 自动重新加载 9B 模型；快照文件无残留。
**注意**：恢复是阻塞的，重载大模型要时间（7.6 GB 约 1~2 分钟，27B 更久），这是正常代价。
若显存低于 8 GB 会告警（通常是浏览器/系统占用），此时降级机制会接手。
## 1. 模型路由表（用户说一句话，按这个选）

| 用户表达里的特征 | 用哪个 | 脚本 | 耗时 | 引擎 |
|---|---|---|---|---|
| 「**朦胧 / 梦幻 / 胶片 / 雾感 / 质感 / 柔光**」 | **Z-Image + KOOK 朦胧 LoRA** | `Z画图.ps1 -Lora Kook_Zimage_ruhmeng...` | **4~6 秒** | 桌面版 8188 |
| 「**写实人像 / 电影感 / 摄影级 / 皮肤质感**」 | **MOSS-Image** | `MOSS画图.ps1` | 10~14 秒 | 自建版 8188 |
| 「**写实人像 + 时尚/棚拍调性**」（要亮、要质感） | **MOSS + KOOK-MOSS LoRA** | `MOSS画图.ps1 -Lora KOOK-MOSS-SFT-guanlan... -LoraStrength 0.8` | 12~22 秒 | 自建版 8188 |
| 「**中文长描述 / 要画中文字 / 封面排版**」 | **Qwen-Image 2.1 Turbo** | `画图.ps1` | 约 15 秒 | sd.cpp |
| 「**最快看一眼构图**」（没说风格） | **Z-Image Turbo（裸模型）** | `Z画图.ps1` | **4 秒** | 桌面版 8188 |
| 「**把这张图改成 XX 风格**」（保留构图） | Z-Image 图生图 | `Z画图.ps1 -Image x -Denoise 0.5` | 5~22 秒 | 桌面版 8188 |
| 「**重绘这张图**」（重绘幅度大） | Qwen 改图 | `改图.ps1 -Strength 0.85` | 约 20 秒 | sd.cpp |
| 「**把 X 换成 Y**」（指令级局部修改） | **Qwen-Image-Edit-2511** | `编辑.ps1` | 约 190 秒 | sd.cpp |
| 「**放大 / 变清晰 / 2K / 4K**」 | SeedVR2 | `图片超分.ps1` | 100 秒+ | 独立 CLI |
| 「**按线稿/姿势/深度图构图**」 | Z-Image ControlNet | ComfyUI 工作流 | 6~10 秒 | 桌面版 8188 |

**判定规则**

1. 有图 + 明确"换成/去掉/改成某个东西"→ 指令编辑（`编辑.ps1`）
2. 有图 + "整体变个风格/氛围"→ Z-Image 图生图（`-Denoise 0.5`），要重绘幅度大再换 `改图.ps1`
3. 无图 + 风格词命中「朦胧/梦幻/雾」→ Z-Image + KOOK LoRA
4. 无图 + 命中「写实/人像/电影感」→ MOSS
5. 无图 + 中文长句/要文字 → Qwen Turbo
6. 都没有命中 → **默认 Z-Image 裸模型**（4 秒先出个样），产出后问一句"要不要换风格/换模型"
7. **两类关键词冲突**（如"写实 + 朦胧"）→ 先按更具体的那个跑，报告里说明选了谁，并给出另一条命令供重跑

## 2. 调用方式（统一无交互）

```powershell
# Z-Image + KOOK 朦胧 LoRA（4~6 秒）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\qwen-image-2.1\Z画图.ps1 `
  -Prompt "森林雾气中的白裙女孩，清晨逆光" -Width 832 -Height 1216 -Steps 8 `
  -Lora Kook_Zimage_ruhmeng.safetensors -LoraStrength 0.8 -NoOpen

# Z-Image 图生图（保留构图改氛围）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\qwen-image-2.1\Z画图.ps1 `
  -Prompt "misty dreamy atmosphere, soft haze" -Image "某图.png" -Denoise 0.5 `
  -Lora Kook_Zimage_ruhmeng.safetensors -LoraStrength 0.8 -NoOpen

# MOSS-Image 写实人像（10~14 秒）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\qwen-image-2.1\MOSS画图.ps1 `
  -Prompt "Editorial portrait, soft window light, 85mm, natural skin texture" -NoOpen

# Qwen Turbo 通用 / 中文
powershell -NoProfile -ExecutionPolicy Bypass -File D:\qwen-image-2.1\画图.ps1 `
  -Prompt "清晨江南水乡，薄雾，写实电影感" -Width 1024 -Height 1024 -NoAsk -NoPause -NoOpen

# 指令编辑
powershell -NoProfile -ExecutionPolicy Bypass -File D:\qwen-image-2.1\编辑.ps1 `
  -Image "C:\Users\wangzimu\Desktop\Qwen 图片\xxx.png" -Prompt "把天空换成晚霞" -NoAsk -NoPause -NoOpen
```

超时设置：Z-Image/MOSS ≥ 300000 ms，Qwen 画图/改图 ≥ 600000 ms，编辑 ≥ 900000 ms。

## 3. 参数速查

| 脚本 | 关键参数 |
|---|---|
| `Z画图.ps1` | `-Prompt`（必填）/`-Width 1024`/`-Height 1024`/`-Steps 8`/`-Cfg 1.0`/`-Sampler res_multistep`/`-Shift 3.0`/`-Seed 0`/`-Lora ''`/`-LoraStrength 0.8`/`-Image ''`/`-Denoise 0.5`/`-NoOpen`/`-KeepServer` |
| `MOSS画图.ps1` | `-Prompt`（必填）/`-Width 1024`/`-Height 1024`/`-Steps 12`/`-Cfg 1.0`/`-Sampler er_sde`/`-Seed 0`/`-NoLora`/`-NoOpen` |
| `画图.ps1` | `-Prompt`/`-Width`/`-Height`（8 的倍数，256~2048）/`-KeepChatBackend`/`-NoAsk`/`-NoPause`/`-NoOpen` |
| `改图.ps1` | `-Image`/`-Prompt`/`-Strength 0.85`（0.55~0.7 微调、0.85 重绘、0.9+ 脱离原图） |
| `编辑.ps1` | `-Image`/`-Prompt`/`-Steps 20`/`-CfgScale 2.5`/`-FlowShift 3.0`/`-Seed`/`-OffloadCpu` |
| `图片超分.ps1` | `-Image`/`-Resolution`（1080=1K、1440=2K、2160=4K） |

分辨率规则：**Z-Image/MOSS 必须 16 的倍数**（832×1216 / 1024×1024 / 1216×832）；Qwen 系 8 的倍数。

## 4. 各模型实测档位

**Z-Image Turbo + KOOK 朦胧 LoRA**（832×1216，同种子）

| 步数 | 权重 0.6 | 权重 0.8 | 权重 1.0 |
|---|---|---|---|
| 8 | 锐度 260 / 4.1 秒 | 121 / 4.1 秒 | 92 / 4.1 秒 |
| 12 | 265 / 5.1 秒 | 127 / 4.9 秒 | 97 / 5.1 秒 |
| 16 | 187 / 6.5 秒 | 124 / 6.5 秒 | 65 / 6.5 秒 |

- 权重越大越朦胧（锐度单调下降，**这是设计意图**）；**甜点 8 步 / 0.6~0.8**；16 步反而更糊，别用
- 图生图 denoise：0.3~0.4 微调 / **0.45~0.55 保留构图改氛围** / 0.6~0.75 大改 / 1.0 等于重生成

**MOSS-Image**（写实人像，1024²）

| 配置 | 耗时 | 锐度 | 观感 |
|---|---|---|---|
| 8 步 + DMD LoRA | 4 秒 | 77 | 皮肤偏塑料、发丝糊（**别用**） |
| **12 步 + DMD LoRA（默认）** | 16 秒 | **98** | 雀斑/毛孔/纹理都在 |
| 16 步 + LoRA | 20 秒 | 85 | 更细腻 |
| 25 步 无 LoRA | 62 秒 | 83 | 真实但偏粗粝胶片 |

- **加速 LoRA 在 8 步会抹掉高频细节 → 默认 12 步**；16~25 步要真毛孔/胶片颗粒

### 已装的两个风格 LoRA

| LoRA 文件 | 底座 | 作用 | 建议权重 |
|---|---|---|---|
| `Kook_Zimage_ruhmeng.safetensors`（151.5 MB） | Z-Image | 朦胧/梦幻/雾感，**锐度下降是设计意图** | 0.6~0.8 |
| `KOOK-MOSS-SFT-guanlan.safetensors`（138.4 MB） | MOSS-Image | 时尚写真调性、更亮更透，**锐度几乎不变** | **0.8**（棚拍感用 1.0） |

叠加顺序（脚本已内置）：`UNETLoader → LoraLoaderModelOnly(加速) → LoraLoaderModelOnly(风格) → 采样`。
**加速 LoRA 必须在风格 LoRA 之前。**

## 5. 引擎与互斥（必须知道）

| 模型 | 走哪个 ComfyUI / 引擎 | 端口 |
|---|---|---|
| Z-Image Turbo + LoRA | **官方桌面版**（模型只装在这里） | 8188 |
| MOSS-Image | 自建版 `D:\ComfyUI` | 8188 |
| Qwen 系（画图/改图/编辑） | sd.cpp（sd-cli，无需 ComfyUI） | — |
| SeedVR2 超分 | 独立 CLI | — |

**桌面版和自建版都占 8188，脚本会自动起/停；它们和秋叶版（8189，跑 H3/Wan/FlashVSR）互斥，同一时间只能开一个。**

**脚本会校验"引擎身份"，不只看端口是否打开**（2026-10-24 实测踩坑：端口开着但引擎不对时，
Z-Image 请求被发给没有 z_image 模型的自建引擎，直接失败）。现在 `Z画图.ps1` / `MOSS画图.ps1`
都会查 `/object_info/UNETLoader` 里有没有对应模型；不匹配就自动停掉另一个引擎再启动自己的。
若端口被未知服务占用则报错退出，不会静默失败。

## 6. 跑完之后（必须做）

1. `read_image` 自查（确认不是黑图/糊图；批量时抽查）
2. **必须用 `present` 交付**：
   ```
   present({ files: [{ path: "C:\\Users\\wangzimu\\Desktop\\Qwen 图片\\xxx.png", description: "..." }] })
   ```
   Markdown 图片语法在这个 GUI **渲染不出来**，只显示 alt 文本。
3. 报告：分辨率 / **用了哪个模型（含 LoRA 与权重）** / 耗时 / 一句评价 / 文件位置
4. 用户要接着改：把上一张路径传给 `-Image`（Z-Image 图生图）或 `编辑.ps1`

## 7. 失败排查

| 现象 | 处理 |
|---|---|
| `CUDA out of memory` | 先停 Strata / Ollama（27B 占 19.5 GB）；脚本已有显存告警（<15 GB 提示） |
| Z-Image/MOSS 报 `missing_node_type` 或模型不可见 | 用了错误的 ComfyUI：Z-Image 只在桌面版，MOSS 只在自建版 |
| LoRA 挂了但没效果 | 文件名错 / 权重 ≤0 / 插错位置（必须夹在 UNETLoader 与 ModelSamplingAuraFlow 之间） |
| 分辨率报错 | Z-Image/MOSS 必须 16 的倍数；Qwen 系 8 的倍数 |
| 画面全黑或全灰 | VAE/模型配错；对输出跑亮度/对比度检查，`std < 1` 即失败 |
| `CUDA error: unknown error`（sd.cpp） | 引擎侧故障，先重启 Windows 清 GPU 状态；仍崩改走 ComfyUI 路线 |

## 8. 相关 skill

- `image-to-video`：图 → 视频（Wan 2.2）+ 放大/插帧/续接
- `text-to-video-h3`：文本 → 带音频视频（MiniMax H3）
- `video-upscale`：视频超分（SeedVR2 / FlashVSR+）
- `video-edit` / `video-to-video`：拼接裁剪 / 视频重绘
- `fisher-moss-prompt-expander`：把一句话扩写成 1500~2500 字详细提示词（先扩写再出图更稳）

## 9. 改这个 skill 的注意事项

- `SKILL.md` 必须**无 BOM UTF-8**，frontmatter 首行正好三个 `---`
- **不要用编辑工具改**（实测会把 `---` 写成 `\---`、中文双重编码 → skill 从 catalog 消失）
- 要改就整文件重写，然后 `Get-Content -TotalCount 5` 校验前三行与中文
