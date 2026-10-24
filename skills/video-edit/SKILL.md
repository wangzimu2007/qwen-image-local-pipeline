---
name: video-edit
description: 视频编辑skill（视频接视频 / 视频延长 / 裁剪 / 放大 / 插帧）：把多段视频拼成一条（自动统一分辨率帧率）、从末尾继续生成延长、按秒裁剪、Lanczos 放大、FILM 插帧，自动归位编号并抽帧预览。Use for 视频拼接、接视频、把两段视频接起来、延长视频、续接、裁剪视频、拼接、剪辑 requests.
---

# 视频编辑（拼接 / 延长 / 裁剪 / 放大 / 插帧）

全部脚本都在 `D:\qwen-image-2.1\`，**不需要打开任何专业软件**。

## 1. 视频接视频（多段拼一条）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\qwen-image-2.1\拼接视频.ps1 `
  -Videos "C:\Users\wangzimu\Desktop\视频\video-0003-wan-20261024-130006.mp4,C:\Users\wangzimu\Desktop\视频\video-0001-wan-20261024-122506.mp4" `
  -NoPause
```

- `-Videos`：**用逗号分隔**（`-File` 调用时数组会被拍平成一个字符串，脚本已兼容）；也可以只写文件名，脚本会到桌面「视频」里找
- `-Fps`：默认 `auto` = 跟第一段；写 `-Fps 24` 强制统一（自动补帧/丢帧）
- **分辨率统一取第一段**，其它段拉伸到同尺寸；**没有转场**
- 实测：720p(5.04s) + 640²@16fps(2.06s) → **1280×720@24fps / 7.08 秒 / 170 帧，2.5 秒完成**
- 成品自动归位到 `Desktop\视频\` 并编号，同时抽 3 帧预览

## 2. 视频延长（从末尾继续生成）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\qwen-image-2.1\续接视频.ps1 `
  -Video "C:\Users\wangzimu\Desktop\视频\video-0002-wan-20261024-124801.mp4" `
  -Prompt "镜头继续推进，海浪持续拍打礁石" -Segments 2 -Seconds 5 -NoPause
```

- 取上一段**最后一帧** → 当首帧再生成 → 与原片拼成一个文件
- `-Segments N`：往后接几段（每段 `-Seconds` 秒）
- 显存占用 = 单段，所以**再长的片子也能做**
- 实测：源 5.04 秒 + 续 3 秒 = **8.08 秒（194 帧）**，单段 12 步约 50 秒
- 提示词写**运动延续**（"镜头继续推进""动作自然延续"）

## 3. 裁剪（按秒截取）

```powershell
D:\ComfyUI-aki-v3.2\python\python.exe D:\qwen-image-2.1\_video_tools.py `
  trim "输入.mp4" "输出.mp4" 起点秒 时长秒
```

实测：`trim <in> <out> 1 2` → 2.00 秒 / 24fps / 48 帧。

## 3.5 AI 超分（SeedVR2 官方 CLI，真正重建细节）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\qwen-image-2.1\AI超分.ps1 `
  -Video "C:\Users\wangzimu\Desktop\视频\video-0002-wan-20261024-124801.mp4" -Resolution 720 -NoPause
```

- `-Resolution`：**短边**目标（720 / 1080），自动保持长宽比
- `-BatchSize`：必须 4n+1（5/9/13/21…），越大越连贯也越吃显存；默认 21
- 模型：3B fp8（3.16 GB），显存峰值约 16 GB
- **实测：832×480 / 121 帧 / 5 秒 → 1248×720，103 秒**（1.25 帧/秒）
- 走的是 `D:\seedvr2-cli\ComfyUI-SeedVR2_VideoUpscaler-main\inference_cli.py`，
  **不开 ComfyUI 界面**，直接出文件后自动归位编号

和 Lanczos 的区别：Lanczos 是插值放大（秒级、不增细节）；SeedVR2 是扩散重建（慢 30 倍、明显更清晰、跨帧不闪）。

## 4. 放大 / 插帧（Lanczos 快速版）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\qwen-image-2.1\后期处理.ps1 `
  -Video "某视频.mp4" -Scale 1.5 -Interp 2 -NoPause
```

实测 5 秒片：Lanczos ×1.5 = 2.3 秒，FILM 插帧 ×2 = 4~25 秒。
AI 超分（SeedVR2）只能在 ComfyUI 界面跑，见 `image-to-video` 的说明。

## 5. 组合用法（常见需求）

| 需求 | 做法 |
|---|---|
| 30 秒长片 | `续接视频.ps1 -Segments 5 -Seconds 5` 一次搞定 |
| 两个镜头合成一条 | `拼接视频.ps1 -Videos "a,b"` |
| 片段太短想拉长 | `续接视频.ps1 -Segments 1`，再 `拼接视频.ps1` 拼回 |
| 成片不够清晰 | `后期处理.ps1 -Scale 1.5 -Interp 2` |
| 只要中间 3 秒 | `_video_tools.py trim` |
| 抽帧做封面 | `_video_tools.py frames <dir> 24`（每 24 帧抽一张） |

## 6. 输出规则

- 成品统一进 `C:\Users\wangzimu\Desktop\视频\`，命名 `video-<NNNN>-wan-<时间戳>.mp4`（自增编号）
- 每次操作**只产生一个新编号视频**；中间产物自动清掉
- 预览帧在 `视频\_预览帧\`

## 7. 交付时必做

1. `present` 给 **mp4 + 2 张预览帧**
2. 告诉用户双击 `Desktop\视频\` 里的文件播放
3. 报告：分辨率、时长、帧率、耗时、文件名
4. 拼接/裁剪/插帧都**没有音频**（Wan 系产物本身无音轨）

## 8. 失败排查

| 现象 | 处理 |
|---|---|
| `找不到视频：a.mp4,b.mp4` | 说明逗号没被识别，确认参数是**一个字符串**而不是被 shell 拆开 |
| 拼接后画面变形 | 分辨率取第一段，比例不同会被拉伸；先统一各段尺寸再拼 |
| 拼接后声音没了 | 正常，本流程不处理音轨 |
| 续接后色调跳变 | 段与段用同一 `-Prompt`；脚本已固定 seed=1000+段号 |
| 裁剪后时长不对 | 确认起点/时长是秒数（小数可用） |

## 9. 相关 skill

- `text-to-image`：生成图片
- `image-to-video`：图 → 视频（生成 + 后期）
- `video-to-video`：已有视频改风格
- `video-upscale`：AI 超分 / 放大 / 插帧（更专业的清晰度处理）
## 交付时必须报告参数（脚本已自动打印）

每次生成/处理后，脚本结尾会打印一段「输出参数」：
分辨率 / 帧率 / 时长 / 帧数 / 编码 / 码率 / 音轨 / 体积 / 比例。
**汇报时直接抄这段**，并额外补充：
1. 用的模型（Qwen-Image 2.1 Turbo / Qwen-Image-Edit-2511 / Wan 2.2 5B / SeedVR2 3B …）
2. 耗时（脚本里有「用时 X 秒」）
3. 一句画质或内容评价
4. 文件在哪（`Desktop\Qwen 图片\` 或 `Desktop\视频\`），提醒双击打开
## 显存快照（2026-10-24 接入）

> 接入模板见 `D:\qwen-image-2.1\_新脚本接入显存快照.md`。

`续接视频.ps1` 与 `后期处理.ps1`（用到秋叶引擎时）已接入 `_vram.ps1`：生成前快照并释放、结束后自动恢复；
秋叶脚本以 `-KeepChatBackend` / `-NoRestore` 调用，避免两套快照互相覆盖。`-KeepChatBackend` 可跳过。
纯 CPU 操作（拼接 / 裁剪 / Lanczos）不涉及显存，不会触发快照。
