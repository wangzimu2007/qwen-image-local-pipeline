---
name: text-to-image
description: 文生图与修图skill（本地文生图/改图/指令编辑/风格化/裁剪缩放/调色/加字水印/转格式/拼图）：本地四套出图模型（Qwen-Image Turbo、Qwen-2512、Z-Image Turbo + KOOK 朦胧 LoRA、MOSS-Image）按需求自动选型，出图、图生图、指令编辑、图片超分 via the one-shot scripts in D:\qwen-image-2.1, which snapshot running local models, free VRAM, generate, then restore them. 硬规则：裁剪/缩放/调色/加字/水印/去水印/抹点这类「小修」，先跑 scripts\img-edit.ps1（0.2 秒），不要用 编辑.ps1；只有「换物体/换背景/改风格」才用 编辑.ps1。Use for 画图、出图、改图、编辑图片、换风格、朦胧、梦幻质感、写实人像、裁剪、缩放、调色、加水印、加文字、转格式、拼图 requests.
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

**判断在前**：不是无脑卸载 —— 先读可用显存，**只有 < 该任务门槛时才动手**（门槛见 §7.5 表：
zimage 13.7 / moss 14.6 / wan 15.6 / seedvr2 14.6 / h3 20.5 / flashvsr 21.5 GB）。
够就直接跑，省掉一次换入换出。

共用库 `D:\qwen-image-2.1\_vram.ps1`（6 个函数：`Get-ChatBackends` / `Get-FreeVramMiB` /
`Start-VramPrep` / `Restore-VramPrep` / `Test-ChatUnloaded` / `Get-VramHolders`）：

1. **判断**显存是否够；不够才进下一步
2. **快照**当前在服务的后端（Strata 8080 按模型 id 区分 IQ3_S/NVFP4；Ollama 11434 读 `/api/ps`），写状态文件
3. **释放**：Strata 走 `stop-*.cmd`；Ollama 用 `keep_alive: 0` 卸载
4. **验证真的卸掉了**（`Test-ChatUnloaded`，最多等 30 秒）；卸不掉就列出占用进程并提示杀进程
5. **自适应等待**显存（达到门槛即继续；连续 9 秒不再增长且 ≥9 GB 也继续，不傻等）
6. 出图 / 出视频
7. **恢复**：Strata 用 `start-*.cmd` 等最多 420 秒；Ollama 用 `keep_alive: 30m` 重新加载
8. 清理状态文件（成功 / 失败 / 异常三个路径都清，靠 `trap` 兜底）

| 开关 | 作用 |
|---|---|
| 默认 | 判断 → 快照 → 释放 → 生成 → 恢复 |
| `-KeepChatBackend` | 跳过快照与恢复（确认显存够用时；**显存不够时反而是陷阱**：不报错但慢 5~10 倍） |

**实测（2026-10-25，9B 已升到 128K 上下文 = 9.2 GB）**：

```
显存不足：12.4 GB 可用（需要 13.7 GB），自动快照并卸载本地模型…
检测到 Ollama 已加载模型（huihui_ai/qwen3.5-abliterated:9b），先卸载腾显存。
显存已就绪：22.6 GB 可用
生成完成，用时 23.8 秒           ← 640×896 / 8 步
恢复出图前的本地模型…
已重新加载 Ollama 模型：huihui_ai/qwen3.5-abliterated:9b
总耗时 53.6 秒；快照文件无残留；显存回到 12.8 GB（模型已回来）
```

**恢复是阻塞的，属于正常代价**：

| 被恢复的模型 | 重载耗时 |
|---|---|
| 9B（64K 上下文，7.6 GB） | 约 5~15 秒（模型在系统缓存里时） |
| **9B（128K 上下文，9.2 GB）** | **比 64K 多约 5 秒**（KV cache 更大） |
| 27B（96K，21.9 GB） | 1~3 分钟 |

**覆盖范围（13 个脚本，都走同一套库）**：
`Z画图` `MOSS画图` `画图` `改图` `编辑` `图生视频` `续接视频` `后期处理` `AI超分FlashVSR`
`文本生视频H3快照` `会话-开始` `会话-结束`（+ 库 `_vram.ps1` 本身）。

**卸载失败的处置**：`llama-server` 有时卡在 99% GPU、`keep_alive:0` 排在正在生成的任务后面 → 表现为
"卸不掉"。脚本会提示并列出占用进程；可靠手段是 `Stop-Process -Name llama-server -Force`
（或双击桌面「模型卡死 - 一键停止」）。
### 规则 6：改图 / 编辑请求 → 先判断「要不要动画面内容」

用户说"改一下 / 修一下 / 编辑这张图"时，**不要直接开 AI 编辑（190 秒）**。先过三个问题：

**Q1：要改变画面内容吗？**（换物体、换背景、换风格、加/去元素、改表情 = 是）
- **不是** → `修图.ps1`（确定性操作，**0.1~1 秒**，纯 CPU 不占显存）
- **是** → 进 Q2

**Q2：局部精准，还是整体重绘？**
- 局部精准（"把杯子换成碗，其他不动"）→ `编辑.ps1`（Qwen-Edit-2511，**~190 秒**）
- 整体重绘但保留构图（"改成油画/水彩"）→ `改图.ps1`（~20~40 秒）
- 只换氛围/光线/天气 → `Z画图.ps1 -Image ... -Denoise 0.45~0.55`（**5~10 秒，最快**）

**Q3：只是要更清楚 / 更大？** → `图片超分.ps1`（SeedVR2，~100 秒）

#### 关键词 → 路线对照

| 用户的话 | 路线 | 耗时 |
|---|---|---|
| 裁一下 / 切掉边 / 改成正方形 | 修图 `crop` / `cropc` | 0.2 秒 |
| 缩小 / 放到 1280 宽 / 放大 2 倍（不增细节） | 修图 `resize` / `thumb` | 0.2 秒 |
| 转 png / 转 webp / 压小一点 | 修图 `format` / `quality` | 0.15 秒 |
| 调亮 / 加对比 / 饱和一点 / 锐化 / 黑白 | 修图 `color` / `gray` | 0.3 秒 |
| 加水印 / 加签名 / 图上一行字 | 修图 `wtext` / `text` | 0.7 秒 |
| 加边框 / 圆角 / 拼两张 / 拼九宫格 | 修图 `border` / `radius` / `montage` | 0.8 秒 |
| 去掉水印 / 抹掉杂物 / 擦掉小东西 | 修图 `erase=x1,y1,x2,y2` | 0.3~0.9 秒 |
| 只把天空调蓝 / 只提亮人脸 | 修图 `boxcolor`（区域调色） | 0.3 秒 |
| 把 A 换成 B / 换背景 / 去掉某物 / 加顶帽子 | `编辑.ps1`（语义编辑） | 190 秒 |
| 改成油画 / 水彩 / 赛博朋克风 | `改图.ps1` 或 `Z画图.ps1 -Image` | 10~40 秒 |
| 换成黄昏 / 起雾 / 顺光改逆光 | `Z画图.ps1 -Image -Denoise 0.5` | 5~10 秒 |
| 修清晰 / 放大变清楚 / 修复模糊 | `图片超分.ps1` | 100 秒 |
| 只改尺寸、别动内容 / 保持原图像素 | **只能修图**（AI 一定重绘） | 0.2 秒 |

#### 硬规则

1. 用户说"**不要动其他部分 / 保持原样 / 只改这里**" → 禁止整体重绘；走 `编辑.ps1`，或干脆 `修图.ps1`
2. 用户说"**像素级一致 / 别重绘**" → 只能 `修图.ps1`（AI 路线必然重绘整张）
3. 语义改完还要尺寸/水印 → **先 AI 改，再用 `修图.ps1` 收尾**，不要用 AI 做第二遍
4. 判断不确定：按"是否改变内容"二分；仍不确定就选 AI 编辑，但**先说明要 190 秒**
5. 回复里必须用一句话交代：**走了哪条路线 + 为什么**，让用户能当场纠正
6. 抹除面积**超过画面约 1/6** 时会糊成一片 → 改用 AI 重绘（`Z画图 -Image -Denoise 0.6` 或 `编辑.ps1`），并说明原因

> 修图是纯 CPU 操作，**不占显存**，可以和 `sd-cli` / ComfyUI 出图同时跑。
### 规则 7：超分别一步到位（>2× 会出现灰块）

`图片超分.ps1` 已内置保护：放大倍数 > `-MaxScale`（默认 2.0）时**自动两步走** ——
先 AI 超分到约 1.5×，再用 Lanczos 补齐到目标尺寸；`-NoTwoStep` 可强制单步。

实测（2026-10-25，832×1216 → 2160，SeedVR2 3B）：

| 方式 | 结果 |
|---|---|
| 单步 ×2.60 | 胸前皮肤出现 **64×85 的灰色方块**（不报错，只是难看） |
| 两步（AI ×1.5 + Lanczos ×1.73） | **干净无灰块**，46 秒 |

**灰块为什么是方的**：超分模型按固定 tile 处理，低纹理区（皮肤/天空/墙面）没有细节可重建，
某个 tile 输出成中性灰 → 一块方正灰斑。

**已出现灰块时**：
1. 定位：把成图和**源图**同位置放大对比 —— 源图干净就是超分引入的；源图也有就是源图自身的。
2. 修（按区域选）：平滑区用 `修图.ps1 -Ops "blurfill=x1,y1,x2,y2,22"`（推荐，痕迹最小）；
   有纹理用 `erase=x1,y1,x2,y2`；要借旁边一块用 `clone=源x,源y,目标x,目标y,宽,高,羽化`。
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

# 指令编辑（语义修改，~190 秒）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\qwen-image-2.1\编辑.ps1 `
  -Image "C:\Users\wangzimu\Desktop\Qwen 图片\xxx.png" -Prompt "把天空换成晚霞" -NoAsk -NoPause -NoOpen

# 修图（确定性小修，0.1~1 秒，纯 CPU）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\qwen-image-2.1\修图.ps1 `
  -Image "某图.png" -Ops "cropc=1024,1024;color=1.05,1.03;wtext:©王梓木:br:26:0.6:white" -NoOpen

# 修图支持的 op（分号串联，按顺序执行）
#   crop=l,t,r,b   cropc=W,H   resize=0.5 或 WxH   thumb=W,H   rotate=90   flip=h|v
#   color=亮度,对比,饱和,锐化   gray   autocontrast=1   border=px,color   radius=px
#   text:内容:字号:x:y:颜色:背景     wtext:内容:tl|tr|bl|br|center:字号:不透明度:颜色
#   wimg:位置:缩放:不透明度:水印图路径   montage:列数:格子:间距:背景:清单txt
#   erase=x1,y1,x2,y2（抹掉一块）   erase=掩码.png（按黑白掩码抹）
#   boxcolor:亮度,对比,饱和,锐化:x1,y1,x2,y2:羽化（只调某个区域）
#   format=png|jpg|webp   quality=90   exif=fix
# 路径含空格/冒号时：把 op 串写进 txt，用 -OpsFile 传入
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
| **`显存仍不足（398 MiB），停止出图。`** | **脚本主动拦截**（不是崩溃）：本地聊天模型没卸干净，或你自己在用 sd-cli/ComfyUI。处置见下方「显存不足三步法」 |
| `CUDA out of memory` | 先停 Strata / Ollama（27B 占 21.9 GB）；脚本已有显存告警（<15 GB 提示） |
| Z-Image/MOSS 报 `missing_node_type` 或模型不可见 | 用了错误的 ComfyUI：Z-Image 只在桌面版，MOSS 只在自建版 |
| LoRA 挂了但没效果 | 文件名错 / 权重 ≤0 / 插错位置（必须夹在 UNETLoader 与 ModelSamplingAuraFlow 之间） |
| 分辨率报错 | Z-Image/MOSS 必须 16 的倍数；Qwen 系 8 的倍数 |
| 画面全黑或全灰 | VAE/模型配错；对输出跑亮度/对比度检查，`std < 1` 即失败 |
| `CUDA error: unknown error`（sd.cpp） | 引擎侧故障，先重启 Windows 清 GPU 状态；仍崩改走 ComfyUI 路线 |

## 7.5 显存不足三步法（含体检判定逻辑）

各任务真实需求（RTX 5090 Laptop 24GB）：

| 任务 | 需要显存 |
|---|---|
| Z-Image / MOSS 出图 | 14~15 GB |
| Qwen-Image-Edit-2511 指令编辑 | **18.2 GB**（DiT 12.6 + 编码器 5.7 + VAE 0.2） |
| Wan 2.2 视频 | 16 GB |
| MiniMax H3 视频 | 21~23 GB |
| 本地聊天模型 27B | 占 21.9 GB（**和上面任何一项都不能共存**） |

处置顺序：

```powershell
D:\qwen-image-2.1\显存体检.ps1 -Model zimage   # ① 看谁占着（或 moss/h3/wan/seedvr2/flashvsr）
D:\qwen-image-2.1\显存体检.ps1 -Kill           # ② 强制释放
D:\qwen-image-2.1\会话-开始.ps1                # ③ 批量任务：只换入换出一次
#   … 连续出图，每张加 -KeepChatBackend -KeepServer …
D:\qwen-image-2.1\会话-结束.ps1
Stop-Process -Name llama-server -Force         # 手工兜底
```

### 显存体检的判定逻辑（6 步）

1. `nvidia-smi` 读总量 / 已用 / 可用 / GPU 占用率
2. 按进程列占用（性能计数器 `GPU Process Memory\Dedicated Usage`）
   —— **已过滤 `dwm`/`csrss` 等系统进程的虚报**（WDDM 下会假报十几到二十 GB），
   非计算进程单进程 > 6 GB 直接忽略
3. 对照内置门槛：`zimage` 13.7 / `moss` 14.6 / `seedvr2` 14.6 / `wan` 15.6 / `h3` 20.5 / `flashvsr` 21.5 GB
4. 三档判定：
   - 可用 ≥ 门槛 → 正常速度
   - 可用 < 门槛但 > 8 GB → **不报错但慢 5~10 倍**（驱动把权重挪到系统内存）← 最坑的一档
   - 可用 < 8 GB → 先关程序，硬跑大概率失败
5. 显示 Ollama 驻留模型及各占多少 GB
6. 可选 `-Kill`：强杀 `llama-server` 后复报可用显存

桌面快捷方式：`显存体检 - 一次性`（默认 zimage 档 + `-KeepOpen`）、`显存释放 - 一次性`（带 `-Kill`）。

**关键提醒**：`llama-server` 有时卡在 99% GPU 占用、`keep_alive:0` 卸不掉 —— 只能杀进程；只调 API 会一直等超时。

### 编辑输入尺寸（2026-10-25 修复）

`编辑.ps1` 自动化模式（`-NoPause`/`-NoAsk`）以前会把任意输入压成 1024×1024 方图；
现在改为**按底图比例缩到约 1.0 MP**（8 的倍数）：2160×3158 → 848×1240，宽高比不变。
## 附录 A：修图与超分技术栈（2026-10-25 定稿）

### A1. 工具矩阵

| 层 | 工具 | 依赖 | 速度 |
|---|---|---|---|
| 脚本入口 | `修图.ps1`（`-Ops` 串联 op） | PowerShell 5.1 | 0.1~7 秒 |
| 图像引擎 | `修图.py`（Pillow + numpy） | workspace python（Pillow 12.3） | 同上 |
| 修补引擎 | `修图_erase.py`（OpenCV inpaint） | 秋叶 python（cv2） | 0.3~1 秒 |
| 备用 | `修图_lama.py`（LaMa ONNX 198 MB） | onnxruntime | 6 秒 |

### A2. 20 个 op 分类

| 类别 | op |
|---|---|
| 几何 | `crop` `cropc` `resize` `thumb` `rotate` `flip` `radius` |
| 色彩 | `color`（亮度/对比/饱和/锐化）`gray` `autocontrast` `boxcolor`（**只调区域**） |
| 合成 | `text` `wtext` `wimg` `border` `montage` |
| 修补 | `erase` `blurfill` `clone` `heal`（实验性） |
| 输出 | `format` `quality` `exif` |

### A3. 修补选型（实测对比）

同一块灰斑（4K 图 64×85 px，皮肤上）四种修法：

| 方法 | 结果 | 结论 |
|---|---|---|
| `erase`（OpenCV Telea） | 灰块没了，但留下**放射状条纹** | 大块不适用 |
| `clone`（邻近克隆） | 灰度对，但**色调偏差大**（131 vs 221） | 需要选对供体 |
| `heal`（谐波填充） | 几乎无变化（实现有问题） | 暂不用 |
| **`blurfill`（大半径模糊覆盖）** | **干净，痕迹不可见** | ✅ 平滑区首选 |

**选型规则**：
- 皮肤 / 天空 / 墙面等**平滑区** → `blurfill=x1,y1,x2,y2,22`
- 有纹理（地面、织物、树叶）→ `erase=x1,y1,x2,y2`
- 需要具体纹理（补砖墙、补发丝）→ `clone=源x,源y,目标x,目标y,宽,高,羽化`
- 面积超过画面 1/6 → 都别用，改 AI 重绘

### A4. 超分灰块的完整处置流程

```
成图出现灰块
 ├─ 把成图和【源图】同位置放大对比
 │   ├─ 源图干净 → 超分引入（本文档 A5）
 │   └─ 源图也有 → 源图自身问题，回去修源图
 ├─ 灰块是【规则方形】→ 分块(tile)重建失败，典型于 >2× 放大
 │   └─ 修：blurfill（皮肤）/ erase（纹理）
 └─ 预防：图片超分.ps1 已自动两步走（>2× 时 AI 到 ~1.5× 再 Lanczos）
```

### A5. 超分为什么会出现灰方块

- SeedVR2 按固定 tile 处理图像；低纹理区没有细节可重建，某 tile 输出中性灰 → 方正灰斑
- 放大倍数越大越容易：实测 832×1216 → 2160（×2.60）必现；两步走（×1.5 + Lanczos ×1.73）不出现
- **不报错**，只能靠肉眼或"灰像素统计"发现

### A6. 走过的弯路（不要重复）

- **LaMa ONNX**（`Carve/LaMa-ONNX`，198 MB）：下载、推理、预处理都跑通了
  （正确口径：图像 0~1、mask 0/1、输出 0~255），但**填充质量不达标**——
  人物剪影残留、边缘发脏，两个导出变体都一样。已弃用，文件保留在
  `D:\lama\models\`，`修图_lama.py` 也在，需要时可再试。
- **结论**：小面积用 OpenCV 更快更稳；大面积直接上 AI 重绘，别指望传统 inpaint。

### A7. 相关脚本

| 脚本 | 作用 |
|---|---|
| `D:\qwen-image-2.1\修图.ps1` | 修图入口（`-List` 看全部 op） |
| `D:\qwen-image-2.1\修图.py` | op 实现（几何/色彩/合成/修补调度） |
| `D:\qwen-image-2.1\修图_erase.py` | OpenCV 修补 |
| `D:\qwen-image-2.1\修图_lama.py` | LaMa ONNX（备用，质量未达标） |
| `D:\qwen-image-2.1\图片超分.ps1` | SeedVR2 单图超分（内置两步走） |
| `D:\qwen-image-2.1\显存体检.ps1` | 谁占显存、够不够、`-Kill` 一键释放 |
| `D:\qwen-image-2.1\会话-开始.ps1` / `会话-结束.ps1` | 批量出图时只换入换出一次 |
| `D:\qwen-image-2.1\编辑.ps1` | Qwen-Image-Edit-2511 指令编辑 |

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
