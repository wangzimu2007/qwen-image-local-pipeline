---
name: text-to-image
description: 文生图与修图skill（本地出图 / 改图 / 修图 / 超分）：本地五套出图模型（Qwen-Image Turbo、Qwen-2512+LoRA、Krea 2+LoRA、Z-Image+KOOK、MOSS、PixelDiT）按需求自动选型，出图前后自动做显存快照与恢复。硬规则 1：裁剪/缩放/调色/加水印/抹点这类「小修」用 scripts\img-edit.ps1（0.2 秒），不要用 编辑.ps1。硬规则 2：**本地模型会话出图必须先跑 D:\qwen-image-2.1\提交作业.ps1**；直接跑 Z画图/编辑/出视频脚本会卸载正在服务你的聊天模型，导致对话断线。Use for 画图、出图、改图、编辑图片、换风格、朦胧、写实人像、Krea、裁剪、缩放、调色、加水印、加文字、转格式、拼图 requests.
---

# 本地出图：先选模型，再调脚本

**核心原则：先判断走哪条路线（见第 1 节路由表），再调对应脚本。不要自己推导模型参数或显存快照逻辑** ——
每个脚本都已实现「快照 → 停本地模型 → 出图 → 自动恢复」——**这是脚本内部行为，你不要手工停任何模型**（本地会话里手工停 = 自杀，见规则 0）。显存是硬约束：24 GB，出图栈吃 14~18 GB，
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
### 规则 0（最高优先）：本地模型会话 → 必须走「作业队列」

**如果你正跑在本地聊天模型上（Strata 8080 / Ollama 11434），绝对不要直接调出图/视频脚本。**

原因：那些脚本为腾显存会把**正在服务你的聊天模型**卸载掉 → 对话立刻断线
（DSH 报 `TRANSPORT Connection error`），而且后续"恢复模型"那一步没人执行。

**正确做法：调 `提交作业.ps1`**

```powershell
# 显存够 → 它同步出图（加 -KeepChatBackend，不卸载你），直接返回成品
# 显存不够 → 它写进队列立刻返回，由独立守护进程卸载聊天模型→出图→恢复你
D:\qwen-image-2.1\提交作业.ps1 -Task zimage -Prompt "海边灯塔，黄昏"
D:\qwen-image-2.1\提交作业.ps1 -Task edit -Image x.png -Prompt "把外套换成红色"
D:\qwen-image-2.1\提交作业.ps1 -Task krea2 -Prompt "..." -Extra "Lora=aoi_haru:0.9"
D:\qwen-image-2.1\提交作业.ps1 -Task zimage -Prompt "..." -Wait      # 排队后等结果
D:\qwen-image-2.1\提交作业.ps1 -Task zimage -Prompt "..." -Extra "OutDir=C:\Users\wangzimu\Desktop\Qwen 图片\测试" -Wait   # 测试图 → 测试夹
D:\qwen-image-2.1\提交作业.ps1 -List                                  # 任务清单与显存需求
D:\qwen-image-2.1\提交作业.ps1 -Status                                # 队列状态
```

可用 Task：`zimage` `moss` `t2i` `krea2` `pixeldit` `edit` `inpaint` `pid` `upscale` `h3` `i2v`

| 情况 | 提交作业的行为 | 你的对话 |
|---|---|---|
| 空闲显存 ≥ 任务需求 | **同步跑**（约 5~30 秒出图） | 不断线 ✅ |
| 空闲显存 < 需求 | **排队**，立即返回作业号 | 不断线 ✅ |
| 守护进程没开 | 提示你「请先双击 作业守护 - 启动」 | 不断线 ✅ |

**四条禁令（本地模型会话，2026-10-25 实测踩坑）**：

0. **禁止停止自己的后端**：不要调用 `stop-iq3s.cmd` / 「Strata IQ3_S - 停止」/「会话-开始.ps1」
   / `watchdog.ps1 -Once` / 任何会停掉聊天后端的命令。实测后果：
   - Strata 被停 → 你当场断线（TRANSPORT）
   - 随后 Keeper 每 30 秒尝试拉起，而 `start-iq3s.cmd` 开头会 `launch --stop` →
     **反复打断正在加载的实例**，托盘在黄/红之间横跳，Strata 永远起不来
   - 正确做法：**什么都不做**，告诉用户"本地后端被我停了，请双击「Strata IQ3_S - 启动」"

1. **不要尝试自己启动守护进程**。WMI（`Invoke-CimMethod Win32_Process`）和
   `schtasks` 在"工作区内修改"沙箱里会被拒绝（`0x80041003 拒绝访问`）。
   守护没在跑时，**只做一件事**：告诉用户双击桌面「**守护 - 全部启动**」。
2. **绝对不要用 `Start-Process` 直接跑出图脚本"兜底"** —— 它会为了腾显存卸载正在服务你的
   Strata，导致本轮 `TRANSPORT Connection error`，而且恢复步骤没人执行。
   宁可什么都不做，也比自杀好。
3. **不要自己调 `会话-开始.ps1` / `_vram.ps1` 的卸载函数**。它们有防自杀闸门，会让你报错；
   正确的路只有 `提交作业.ps1`。

**本地会话提交作业：用 `-Wait` 一次阻塞到底（2026-10-26 优化，自动续跑）**

```powershell
# 1~2 张：提交并原地等结果，返回时聊天模型已恢复 → 同一轮可以继续下一步
D:\qwen-image-2.1\提交作业.ps1 -Task zimage -Prompt "..." -Wait

# 3 张以上：拆成 2 张一批、连续调多次 -Wait（每批结束模型都已被拉回来，会话不会断）
D:\qwen-image-2.1\提交作业.ps1 -Task zimage -Prompt "..." -Count 2 -Seeds "11,22" -Wait
D:\qwen-image-2.1\提交作业.ps1 -Task zimage -Prompt "..." -Count 1 -Seeds "33" -Wait
```

`-Wait` 会一直等四个条件全部满足才返回（不是只等作业 done）：

| 条件 | 含义 |
|---|---|
| 作业 done 文件 | 脚本真的跑完了 |
| `guardian.lock` 消失 | 守护不再处于"批量中" |
| `last-batch.json` 比提交时间新 | 守护已经做完批末恢复 |
| 本地聊天后端 `/v1/models` 有模型 | 你现在用的模型真的能应答了 |

返回时会打印 `✓ 聊天后端已就绪：ollama 11434`，此时**直接继续下一步即可，不需要用户再发消息**。

**批量上限**：一次 `-Wait` 建议不超过 2 张（3 张实测约 322 秒，可能撞上工具调用超时）；
超过就按上面拆批，每批之间后端都已被恢复，不会断线。

**仍然必须做的**：本地模型会话关闭「自动审查」（审查也走同一个本地后端，卸载期间会失败）。

**（已由上面的 `-Wait` 流程取代，保留供排查）提交排队作业后立即结束本轮（2026-10-25 实测）**：

- 守护进程一旦开始执行，就会**卸载聊天后端**（Strata）。之后本轮再调任何工具，
  都可能因为「自动审查 / 工具审批」需要调用模型而失败：
  `Auto review of tool "pwsh" failed: reviewer ended with error TRANSPORT`。
- 所以：**提交作业成功后，立刻把结果告诉用户并结束本轮**，不要在同一轮继续
  `read` / `grep` / 再调 `pwsh`，也不要用 `-Wait`（轮询本身就是工具调用）。
- 本地模型会话**建议关闭「自动审查」**（composer 里切换）：审查模型和聊天模型是同一个，
  后端被卸载时审查必然失败，工具体不会执行。

**排队作业的执行顺序（守护进程做）**：
`快照聊天后端 → 卸载 → 等显存 → 跑脚本 → 关引擎 → 恢复聊天后端 → 写结果`

**结果在哪**：`D:\qwen-image-2.1\.jobs\done\<作业号>.json`（含 `product` 成品路径、`seconds` 耗时）；
日志 `D:\qwen-image-2.1\.jobs\守护.log`；单次脚本输出 `<作业号>.log`。

**守卫**：`_vram.ps1` 现在有一道闸门——任何脚本想卸载"DSH 当前默认模型"时会**直接报错拒绝**
（除非守护进程设了 `PIPE_ALLOW_SELF_UNLOAD=1`）。所以本地模型即使误调出图脚本，也只会失败、不会断线。

### 规则 5：显存快照机制（⚠ 脚本内部自动完成，模型禁止手工执行）

> **⚠ 阅读者注意（模型）：本节以下提到的 `start-iq3s.cmd` / `stop-iq3s.cmd` / `会话-开始.ps1` /
> `Start-VramPrep` / `快速腾显存` 等，**全部是脚本和守护进程的内部机制**，不是让你执行的指令。
> **你出图只能走规则 0 的 `提交作业.ps1`**；任何"我先停掉模型腾显存"的念头都是错的 —
> 你正跑在这个模型上，停它就是停你自己（2026-10-25 实测：连续两次这样干，整轮 TRANSPORT 失败，
> 还触发 Keeper 死循环让后端 10 分钟起不来）。

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
### 规则 6：改图 / 编辑请求 → 三条路径（按"改动范围 + 是否要给区域"选）

| 需求 | 走哪条 | 脚本 | 实测 |
|---|---|---|---|
| **裁剪/缩放/调色/加水印/抹小点**（确定性，不动内容） | 修图 | `修图.ps1 -Ops` | 0.1~1 秒 / 纯 CPU |
| **"这块去掉 / 这块换个东西"**（用户指了区域，要保留其余） | **局部重绘** | `局部重绘.ps1 -Rect x1,y1,x2,y2` | **约 10 秒** / 14 GB |
| **"把 X 换成 Y"**（语义级，不指定区域） | 指令编辑 | `编辑.ps1` | 约 190 秒 / 18 GB |

局部重绘要点（2026-10-25 实测）：
- **denoise 默认 0.85**；实测 1.0 会把区域画成完全无关的内容（比如石墙变成怪植物）
- 提示词要描述**这块区域应该长什么样**（含光影/材质），不是描述"去掉什么"
- 边界用 `-Feather 16` 过渡自然；小范围杂点仍优先用 `修图.ps1` 的 `blurfill`（更稳）

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
### 规则 7：超分有两条路线（>2× 会出现灰块）

| 路线 | 脚本 | 实测 | 许可 |
|---|---|---|---|
| **SeedVR2**（通用，任意尺寸） | `图片超分.ps1` | 832→2160 两步 46 秒 / 720p→1080p 265 秒 | 无限制 |
| **PiD 4×**（Qwen-Image latent，1024→4096） | `PiD超分.ps1` | 1024²→4096² **37 秒**；640×896→2560×3584 **12 秒** | **NSCLv1 仅非商业** |

PiD 更快，但**只能用在非商业**、且输入先缩到 1024 再放大（模型训练于 1024→4096）。
商业项目一律走 SeedVR2。

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
| 「**要审美/编辑感/风格化（摄影·动漫·水彩·霓虹·复古）**」 | **Krea 2 Turbo**（风格 LoRA） | `Krea2画图.ps1 -Lora 风格名` | **3~12 秒** | 桌面版 8188 |
| 「**同一个角色出多张**」（人物一致性） | **Krea 2 + 人物 LoRA** | `Krea2画图.ps1 -Lora "aoi_haru:0.9,风格:0.7"` | 3~12 秒 | 桌面版 8188 |
| 「**按参考图换场景/换装**」（身份保持） | **Krea 2 身份编辑** | 工作流 `Krea2-身份编辑.json` | 约 10 秒 | 桌面版 8188 |
| 「**写实人像 + 时尚/棚拍调性**」（要亮、要质感） | **MOSS + KOOK-MOSS LoRA** | `MOSS画图.ps1 -Lora KOOK-MOSS-SFT-guanlan... -LoraStrength 0.8` | 12~22 秒 | 自建版 8188 |
| 「**中文长描述 / 要画中文字 / 封面排版**」 | **Qwen-Image 2.1 Turbo**（官方蒸馏 8 步） | `画图.ps1` | 约 15 秒 | sd.cpp |
| 「**要 Qwen 最高画质 / 中文海报**」 | **Qwen-Image-2512 + Wuli 2-Step LoRA**（4 步） | ComfyUI 工作流 | **26.8 秒** | 桌面版 8188 |
| 「**最快看一眼构图**」（没说风格） | **Z-Image Turbo（裸模型）** | `Z画图.ps1` | **4 秒** | 桌面版 8188 |
| 「**把这张图改成 XX 风格**」（保留构图） | Z-Image 图生图 | `Z画图.ps1 -Image x -Denoise 0.5` | 5~22 秒 | 桌面版 8188 |
| 「**重绘这张图**」（重绘幅度大） | Qwen 改图 | `改图.ps1 -Strength 0.85` | 约 20 秒 | sd.cpp |
| 「**把 X 换成 Y**」（指令级局部修改） | **Qwen-Image-Edit-2511** | `编辑.ps1` | 约 190 秒 | sd.cpp |
| 「**把这块去掉 / 这块换个东西**」（给了区域） | **Z-Image 局部重绘** | `局部重绘.ps1 -Rect` | **10 秒** | 桌面版 8188 |
| 「**放大 / 变清晰 / 2K / 4K**」 | SeedVR2（通用） | `图片超分.ps1` | 100 秒+ | 独立 CLI |
| 「**放大到 4K、要快、非商业**」 | **PiD 4×**（像素扩散解码） | `PiD超分.ps1` | **12~37 秒** | 桌面版 8188 |
| 「**只想变大变干净、别给我瞎编**」 | **RTX VSR**（英伟达硬件插值） | ComfyUI 节点 `RTXVideoSuperResolution` | **3~15 秒** | 桌面版 8188 |
| 「**按线稿/姿势/深度图构图**」 | Z-Image ControlNet | ComfyUI 工作流 | 6~10 秒 | 桌面版 8188 |
| 「**建筑/风景/大场面、要像素级锐利**」（且**非商业**） | **PixelDiT 1.3B**（像素空间扩散） | `PixelDiT画图.ps1` | **12 秒** | 桌面版 8188 |

**判定规则**

1. 有图 + 明确"换成/去掉/改成某个东西"→ 指令编辑（`编辑.ps1`）
2. 有图 + "整体变个风格/氛围"→ Z-Image 图生图（`-Denoise 0.5`），要重绘幅度大再换 `改图.ps1`
3. 无图 + 风格词命中「朦胧/梦幻/雾」→ Z-Image + KOOK LoRA
4. 无图 + 命中「写实/人像/电影感」→ MOSS
5. 无图 + 中文长句/要文字 → Qwen Turbo
6. 都没有命中 → **默认 Z-Image 裸模型**（4 秒先出个样），产出后问一句"要不要换风格/换模型"
7. **两类关键词冲突**（如"写实 + 朦胧"）→ 先按更具体的那个跑，报告里说明选了谁，并给出另一条命令供重跑
8. **PixelDiT 只在「非商业用途」时用**，且必须主动告知许可限制（NSCLv1：仅研究/评估，输出同样受限）；
   商业项目一律用 Z-Image / MOSS / Qwen，**不要**主动推荐 PixelDiT

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

# PixelDiT 像素空间文生图（12 秒，NSCLv1 仅限非商业）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\qwen-image-2.1\PixelDiT画图.ps1 `
  -Prompt "misty mountain village at dawn, stone path, lanterns" -Steps 30 -NoOpen -NoPause

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

**Krea 2 Turbo**（12B DiT，2026-10-25 实测）

| 场景 | 耗时 | 显存峰值 |
|---|---|---|
| 冷启动（加载 12B 权重 + 编码器） | 33.6 秒 | 17.8 GB |
| **热启动 8 步 1024²** | **3.1 秒** | 17.1 GB |
| 带 LoRA 首次（换 LoRA 有加载开销） | 12.1 秒 | 18.2 GB |

- 架构：12B 稠密 DiT + `qwen_image_vae` + `qwen3vl_4b` 编码器（`CLIPLoader type=krea2`）
- 采样：8 步 / cfg 1.0 / `euler`+`simple`，负面用 `ConditioningZeroOut`
- 定位：**审美与风格广度**（编辑级人像、动漫、水彩、霓虹、复古）；**中文弱**，别拿它画中文字
- 许可：**Krea 2 Community License**，商用前必须确认条款

**Krea LoRA 调度（16 个，分四类）**

| 类 | 数量 | 名称 | 建议权重 | 用法 |
|---|---|---|---|---|
| **风格** | 10 | softwatercolor / retroanime / neondrip / rainywindow / sunsetblur / darkbrush / dotmatrix / kidsdrawing / vintagetarot / style_reference | 0.7~0.9 | `-Lora softwatercolor` |
| **人物** | 3 | aikasawaguchi / aoiharu / ayakamiyoshi | 0.85~0.95 | `-Lora aoiharu`，**脚本自动补触发词** |
| **编辑** | 2 | identity_edit_v2_r64 / general_edit_v2_r64 | 1.0 | **必须走工作流** `Krea2-身份编辑.json`（要参考图 + comfyui-krea2edit 节点）|
| 加速 | 1 | turbo_lora_rank_64_bf16 | 1.0 | 8 步已够，一般不用 |

**三条组合规则（重要）**：

1. **人物 + 风格可以叠，但要降权**：人物 0.85~0.95 + 风格 0.6~0.75（两者合计 ≤ 1.7）；
   写法 `-Lora "aoi_haru:0.9,softwatercolor:0.7"`
2. **两个风格 LoRA 不要同时开**（会互相打架、画面变糊）
3. **identity_edit 与 general_edit 不能都上 1.0** —— 官方 README 明确：同源谱系，同时满载会变成"纯重新着色"；
   **一次任务只用其中一个**

**身份编辑参数表**（官方 README，Turbo 8 步 / cfg 1.0）：

| 任务 | ref_boost | grounding_px | Placement |
|---|---|---|---|
| 把一个人换到新场景（单参考） | 2 | 768 | beside / aligned |
| 往场景里加一个人（场景=图1、人=图2） | 人 2~3、场景 1 | 768 | 场景 aligned |
| 锁脸人像（保持原构图） | 1~2 | 768 | aligned |

提示词技巧（README 强调"提示词比参数重要"）：**写清露多少身体**（"full body / in muddy boots" 比 "standing on a ridge" 有效）、
**具体写服装**、**明确写要去掉什么**（"remove her coat"）。

**人物 LoRA 触发词**（脚本自动补，别重复手写）：
`aikasawaguchi → aika_sawaguchi`；`aoiharu → aoi_haru`；`ayakamiyoshi → ayaka_miyoshi`

**11 个风格 LoRA**（`-Lora` 参数，0.8~0.9 效果明显）：

| 名称 | 风格 | 名称 | 风格 |
|---|---|---|---|
| `softwatercolor` | 水彩 | `retroanime` | 复古动漫 |
| `neondrip` | 霓虹 | `rainywindow` | 隔着雨窗 |
| `sunsetblur` | 日落虚化 | `darkbrush` | 暗调笔刷 |
| `dotmatrix` | 点阵 | `kidsdrawing` | 儿童蜡笔 |
| `vintagetarot` | 复古塔罗 | `style_reference` | 风格参考 |
| `turbo_lora_rank_64_bf16` | 加速 | | |

**注意**：`qwen3vl_4b` 编码器与 Qwen-2512 的 `qwen_2.5_vl_7b` **不通用**，两套都要留（多占 4.9 GB）。

**Qwen-Image「Turbo」到底是什么（2026-10-25 厘清）**

"Turbo" 在本机有**两条完全不同的加速路线**，别混用：

| 路线 | 是什么 | 脚本/入口 | 步数 | 实测 1024² |
|---|---|---|---|---|
| **Qwen-Image 2.1 Turbo** | 阿里官方**蒸馏版模型**（AD = 蒸馏；另有 Uncensored Q8_0 版） | `画图.ps1`（sd.cpp） | 8 | **约 15 秒** |
| **Qwen-Image-2512 + Turbo LoRA** | 完整 2512 模型 + Wuli-art **2 步蒸馏 LoRA**（LoRA 加速，不是换模型） | ComfyUI 工作流 | **2~4** | **20.6 / 26.8 秒** |

选择：顺手出图/中文短句 → 官方 Turbo（15 秒）；要画质/复杂中文排版 → 2512 + LoRA（4 步 27 秒）。

**2512 量化档位实测（同一提示词/种子，4 步 cfg1.0）**

| 量化 | 体积 | 耗时 | 显存峰值 | 结论 |
|---|---|---|---|---|
| ~~Q3_K_M~~（已删除 2026-10-25） | ~~9.25 GB~~ | 43.2 秒* | 19.4 GB | 显存最省但画质一般，已删以腾空间 |
| **Q4_K_M（新默认）** | **12.34 GB** | **26.8~37.1 秒** | 22.2 GB | **甜点：同速、精度更高** |
| Q5_K_S（可选） | 13.32 GB | 39.1 秒 | 22.2 GB | 画质略好一点，占盘多 1 GB |

\*Q3 那次含首次加载 12 GB 权重，去掉加载约 27 秒。三档画质肉眼差别小，但 Q4/Q5 细节更实。

> **量化选择现状**：只剩 Q4_K_M（12.34 GB，默认）和 Q5_K_S（13.32 GB，可选）。
> Q3_K_M 已于 2026-10-25 删除（画质一般、省下的 9.25 GB 用不上）；
> 真需要更省显存时优先换 Z-Image（4.2 GB / 14 GB 峰值）而不是降这个的量化。**步数实测（Q4_K_M + Wuli LoRA，cfg 1.0）**：2 步 **20.6 秒**（细节偏软）/ **4 步 26.8 秒（默认，推荐）** /
8 步 53.7 秒（提升不多）/ 4 步 cfg 2.0 53.6 秒（无意义，别加 cfg）。
**RTX VSR（英伟达硬件超分，2026-10-25 实测）**

| 场景 | 耗时 | 显存峰值 |
|---|---|---|
| 2× ULTRA（首次，含 SDK 初始化） | 14.6 秒 | 18.2 GB |
| **4× ULTRA（热启动）** | **2.85 秒** | 18.4 GB |

**定位——它是"插值器"，不是"恢复器"**（同一张 1024 人像做 2× 三方对比）：

| 方案 | 观感 | 会不会补细节 |
|---|---|---|
| Lanczos | 发软 | ❌ |
| **RTX VSR** | **干净、自然** | ❌ **不补毛孔/发丝**（忠实原图）|
| SeedVR2 | 锐、细节多 | ✅ 会补（46.4 秒/张）|

用法（ComfyUI 节点，桌面版 8188）：
```
LoadImage → RTXVideoSuperResolution → SaveImage
节点参数：resize_type=scale by multiplier / resize_type.scale=2.0
          quality=ULTRA / strength=1.0 / image_encoding=8-bit RGB
```
**走 API 提交时注意**：动态下拉参数的键名是 `resize_type.scale`（不是嵌套），
`image_encoding` 必须写 `8-bit RGB`（写 `8-bit` 会校验失败）。
工作流文件：`RTX-VSR-图片超分.json` / `RTX-VSR-视频超分.json`（已放进界面）。
依赖：`nvidia-vfx`（pip 包，装进 ComfyUI 的 venv）。

**选型口诀**：怕 AI 乱编 / 只要干净变大 → VSR；要救糊图细节 → SeedVR2；4K 印刷且非商业 → PiD。

**PiD 4× 超分**（2026-10-25 实测）

| 输入 | 输出 | 耗时 | 显存峰值 |
|---|---|---|---|
| 1024×1024 | 4096×4096 | **37.3 秒** | **19.9 GB** |
| 640×896 | 2560×3584 | **12.1 秒** | ~20 GB（含加载） |

- 链路：`LoadImage` → `VAEEncode`(qwen_image_vae) → `PiDConditioning`(latent_format=**qwenimage**,
  degrade_sigma=0) → `SamplerCustom`(lcm / simple / **4 步** / cfg 1.0) → `VAEDecode`(**pixel_space**)
- 峰值显存 ~20 GB，出图前必须快照卸载（脚本已内置 21000 MB 门槛）
- 和 SeedVR2 比：**快 2.7~8 倍**，但显存吃紧、非商业许可、输入超 1024 会先缩
**PixelDiT 1.3B**（像素空间扩散，2026-10-25 实测）

| 配置 | 耗时 | 显存 | 说明 |
|---|---|---|---|
| 1024² / **30 步 / cfg 4**（官方参数） | **9.2~12.1 秒** | ~10 GB | 默认，质量最好 |
| 1024² / 8 步 / cfg 2 | 8.0 秒 | 9.1 GB | 只快 1~4 秒，质量下降，不划算 |

- 采样器固定 `er_sde` + `simple`；VAE 用特殊值 **`pixel_space`**（无需 VAE 文件）
- 文本编码器 `gemma_2_2b_it_elm_bf16`（CLIPLoader `type=pixeldit`），这是它和其他四套最大的区别
- 擅长：建筑 / 风景 / 大场面结构（像素空间直接生成，边缘更硬）
- 短板：**中文理解弱**（中文或画面中文字用 Qwen）；**NSCLv1 许可仅限非商业**
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

## 5.5 本地模型的上下文怎么设（Ollama）

Qwen3.5 / Qwen3-VL 系列**原生支持 262144（256K）**上下文，但默认被压到 65536。
原因是一个全局变量 —— 而且它的行为很坑：

> **`OLLAMA_CONTEXT_LENGTH` 是「强制覆盖」，不是「上限」。**
> 设 65536 时，模型里自带的 `num_ctx 131072` 会被**压回** 65536；
> 设 131072 时，27B 自带的 `num_ctx 98304` 会被**拉到** 131072（差点把它顶爆）。
> 实测（2026-10-25，Ollama 0.40.10）：两个方向都被它改过。

**正确做法：删掉全局变量，每个模型单独钉。**

```powershell
# 1) 删掉全局覆盖（用户级 + 当前进程都要）
[Environment]::SetEnvironmentVariable('OLLAMA_CONTEXT_LENGTH', $null, 'User')
Remove-Item Env:OLLAMA_CONTEXT_LENGTH -ErrorAction SilentlyContinue

# 2) 按模型钉 num_ctx（Modelfile: FROM 原模型 + PARAMETER num_ctx）
"FROM qwen3.5:9b`nPARAMETER num_ctx 131072" | Set-Content mf.txt -Encoding utf8
ollama create qwen3.5:9b -f mf.txt

# 3) 重启 Ollama（新进程必须继承"已删除"的环境）
Get-Process 'ollama app','ollama','llama-server' | Stop-Process -Force
Start-Process "$env:LOCALAPPDATA\Programs\Ollama\ollama app.exe"

# 4) 验证：看 llama-server 的实际 -c 值
Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" |
  ForEach-Object { if ($_.CommandLine -match '-c\s+(\d+)') { $Matches[1] } }
```

> 踩坑：`Start-Process` 从**旧 shell** 启动会继承**旧的**环境变量 —— 今天因此白改了两轮。
> 要么在同一个进程里先改 `$env:` 再启动，要么先完全退出 Ollama 再从桌面启动。

**当前配置（2026-10-25 实测）**：

| 模型 | num_ctx | 加载后 GPU 占用 |
|---|---|---|
| huihui_ai/qwen3.5-abliterated:9b | **131072** | 11.7 GB（模型 9.2 GB） |
| huihui_ai/qwen3-vl-abliterated:8b | **131072** | 10.9 GB |
| qwen3.5:9b / qwen3-vl:8b | 131072 | — |
| qwen3.8:27b-abliterated | **98304**（保持原值） | 22.9 GB（**已接近满**） |
| qwen3-coder:30b | **32768**（故意小） | 21.6 GB |

**为什么有的给 32K**：coder:30b 是 MoE，权重 17.3 GB，128K 的 KV cache 会直接把它顶爆；27B 同理。

**代价与取舍**：
- 上下文每翻倍，KV cache 约翻倍：9B 从 64K→128K 让 GPU 占用 7.6 → 11.7 GB
- 256K 理论可行（原生支持），但 9B 会到 ~15 GB，和出图彻底冲突 → **128K 是甜点**
- 出图/出视频前这些模型会被显存快照卸掉（见规则 5），所以不用担心冲突

**DSH 侧也要同步**：`~\.dsh\profiles\desktop\cordis.patch.yml` 里每个模型的
`contextWindow` 要和 Ollama 的实际 `num_ctx` 一致（现在 9B/VL 都是 131072），
**改完必须重启 DSH**，否则模型端已是 128K、但 DSH 只发 64K 的历史。

**换新模型时的检查清单**：
1. `ollama show <模型> --parameters` 看有没有 `num_ctx`
2. 没有就按上面钉一个（参考：≤10B 给 131072，27B 给 98304，MoE 30B 给 32768）
3. 加载后读 `llama-server` 的 `-c` 确认生效
4. 同步改 `cordis.patch.yml` 的 `contextWindow`，重启 DSH
## 5.6 本地模型的会话卫生（9B 实测教训）

> **默认模型走云端（deepseek-flash）**：多步任务、看图判断、调脚本都交给它。
> 本地模型定位是「断网/隐私/单步/批量」——尤其本文档这种多步流程，别用本地 9B 硬扛。

**性能基线（2026-10-25 实测，RTX 5090 Laptop 24GB）**：

| 模型 | 预填充 | 生成 | 加载 |
|---|---|---|---|
| huihui_ai/qwen3.5-abliterated:9b（128K） | **4300 tok/s** | **~90 tok/s** | 0~12 秒（缓存热时 0 秒） |
| huihui_ai/qwen3-vl-abliterated:8b（128K，带图） | — | ~68 tok/s | 28 秒（首图含视觉塔） |

**为什么"看起来卡死"**：不是慢，是**上下文太大**。实测一次请求的提示词是 **38,103 token**
（AGENTS.md 10.7K + 工具定义 9.7K + skill 目录 + 历史），光预填充就要 **8.9 秒**，
而且**每一步工具调用都要重发整段上下文** → 多步任务越跑越慢。

**三条会话卫生规则**：

1. **小任务新开会话**：38K 上下文降到 2~5K，速度差约 10 倍
2. **一条明确命令 > 多轮试错**：本地 9B 实测同一任务 17 步没做完（还误用 `mp_upload_image`、
   拿 `edit` 改图片）；直接把成品命令给它（"执行 `修图.ps1 -Image x -Ops "blurfill=..."`"）最可靠
3. **别在同一会话里连续"再试一次"**：每轮叠加历史，第二轮开始就变慢

**怎么判断是真卡住**（三个信号同时出现才算）：

| 信号 | 查看方式 |
|---|---|
| Ollama 日志 `n_gen` 还在涨 | `%LOCALAPPDATA%\Ollama\server.log` 尾部 |
| llama-server 单核 100%、GPU 90%+ | `Get-Process llama-server`（看 CPU 增量） |
| 但界面长时间没有任何新内容 | 说明在空转/超长思考 |

处置：双击桌面 **「模型卡死 - 一键停止」**（中断生成 + 卸载 + 报显存回血）。
**只调 `keep_alive:0` 没用** —— 它会排在正在生成的任务后面。

**⚠ 重试会把上下文越滚越大（2026-10-25 实测的恶性循环）**：

```
客户端超时 → 自动重试 → 上下文重新组装，比上次更大
          → 38,103 token → 41,003 token   ← 每轮都涨
          → 预填充更久（8.9s → 13.0s）→ 又超时 → 再重试 …
```

所以**"卡住"往往是这个循环**，而不是单次生成慢。观察信号：日志 `n_tokens` 一次比一次大。

**断请求的三种手段（实测对比）**：

| 手段 | 效果 | 说明 |
|---|---|---|
| 杀 `llama-server` | ❌ **立刻重生** | Ollama 为挂起的请求重新拉 runner |
| 停整个 Ollama 服务 | ⚠️ 短暂有效 | 客户端一重试又把模型拉起来 |
| **临时摘掉模型 `ollama rm <模型>`** | ✅ **彻底停住** | 请求拿到 404，客户端放弃重试 |

摘模型后 10 秒就能装回去（GGUF 还在本地）：

```powershell
# 摘掉 → 断请求
ollama rm huihui_ai/qwen3.5-abliterated:9b
# 装回（带 128K 上下文）
"FROM D:\ollama-models\_import\Huihui-Qwen3.5-9B-abliterated.Q4_K_M.gguf
FROM D:\ollama-models\_import\Huihui-Qwen3.5-9B-abliterated.mmproj-Q8_0.gguf
PARAMETER num_ctx 131072" | Set-Content mf.txt -Encoding utf8
ollama create huihui_ai/qwen3.5-abliterated:9b -f mf.txt
```

`停止卡死.ps1` 已内置这个判断：杀掉 runner 后若 4 秒内又出现新 runner，
会**自动重启 Ollama 服务**来中断请求（`-KeepOffline` 可让它停着不自动拉起）。
**能力边界（别指望本地小模型做这些）**：
- 多步工具编排（看图→判断→选脚本→执行）：9B 实测 0 次主动加载 skill，容易乱试工具
- 需要先问再答的模糊需求：它倾向直接动手
- 适合：单步问答、摘要、明确命令执行、简单看图（VL 8B 能读图上数字，实测准确）
## 6. 跑完之后（必须做）

1. `read_image` 自查（确认不是黑图/糊图；批量时抽查）
2. **必须用 `present` 交付**：
   ```
   present({ files: [{ path: "C:\\Users\\wangzimu\\Desktop\\Qwen 图片\\xxx.png", description: "..." }] })
   ```
   Markdown 图片语法在这个 GUI **渲染不出来**，只显示 alt 文本。
3. 报告：分辨率 / **用了哪个模型（含 LoRA 与权重）** / 耗时 / 一句评价 / 文件位置
4. 用户要接着改：把上一张路径传给 `-Image`（Z-Image 图生图）或 `编辑.ps1`

**每张图自带溯源元数据（2026-10-25 起）**

所有出图/修图脚本都会把信息写进 **PNG text 块**（`_meta.ps1` + `_pngmeta.py`）：

| 字段 | 示例 |
|---|---|
| `Model` | `Z-Image Turbo + Kook_Zimage_ruhmeng@0.8` / `PixelDiT 1.3B` / `Pillow ops` |
| `Prompt` / `Negative` | 原始提示词 |
| `Steps` / `Cfg` / `Sampler` / `Seed` / `Size` | 生成参数 |
| `Ops` | 修图操作串（如 `cropc=640,640;wtext:...`）|
| `License` | PixelDiT 写 `NSCLv1 NON-COMMERCIAL`（其他模型无此字段）|
| `GeneratedBy` / `GeneratedAt` | 哪个脚本、什么时候 |

用途：整理作品集、复现某张图、许可留痕。
**许可提醒不要写进提示词**——模型不懂许可证，只会污染画面；写进元数据才可靠。
关闭：设环境变量 `PIPE_NOMETA=1`。
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
# ③ 批量任务由 提交作业.ps1 自动合并成一批（模型不要手工调 会话-开始.ps1）
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
| `会话-开始.ps1` / `会话-结束.ps1` | **仅供人类批量操作；模型会话禁止调用**（等于停掉自己）|
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
