---
name: image-to-video
description: 图生视频skill（把静态图片变成动态视频 + 一键后期）：用 Wan 2.2 5B 以一张图为第一帧生成 2~10 秒视频，支持 Lanczos 放大、FILM 插帧、续接拼长片，自动启动/关闭 ComfyUI、自动归位编号、自动抽帧预览。Use for 图生视频、让这张图动起来、把图片做成视频、动画化、放大视频、提高帧率 requests.
---

# 图生视频（静态图 → 视频，含一键后期）

**不要自己拼 ComfyUI 节点或手写 API 请求**。底层脚本已处理全部流程。

## 1. 生成：`图生视频.ps1`

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\qwen-image-2.1\图生视频.ps1 `
  -Image "C:\Users\wangzimu\Desktop\Qwen 图片\qwen-0035-t2i-20261024-095218.png" `
  -Prompt "镜头缓慢推进，炊烟飘动，阳光在雪山上移动，电影感" `
  -Seconds 5 -Fps 24 -Steps 20 -NoPause
```

工具超时给 **≥ 1200000 ms**。

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Image` | **必填** | 输入图片 |
| `-Prompt` | 镜头缓慢推进… | 描述**运动**，不描述画面内容 |
| `-Seconds` | 5 | 自动换算 4n+1 帧 |
| `-Fps` | 24 | 帧率 |
| `-Steps` | 20 | 降到 12~15 明显加快 |
| `-KeepServer` / `-NoPause` | — | 连跑/自动化用 |

分辨率不用指定：按原图比例算，对齐 32，上限约 0.55 MP。

## 2. 一键后期：`后期处理.ps1`（放大 + 插帧）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\qwen-image-2.1\后期处理.ps1 `
  -Video "C:\Users\wangzimu\Desktop\视频\video-0002-wan-20261024-124801.mp4" `
  -Scale 1.5 -Interp 2 -NoPause
```

| 参数 | 说明 | 实测耗时（5 秒片） |
|---|---|---|
| `-Scale 2` | **Lanczos 快速放大**（纯本地，无 AI 模型） | **2.3 秒** |
| `-Interp 2` | FILM 插帧，帧率 ×N（2~16） | **4~25 秒** |

- 放大是 **Lanczos（非 AI）**：能提分辨率、不增加细节。真 AI 超分只有 SeedVR2，**只能在 ComfyUI 界面跑**（API 实测 121 帧 2× 超 16 分钟未完成，不适合一键）。
- 插帧是**后端节点**，可以 API 调用，很快。
- 跑完自动归位编号、抽预览帧；**每次只产出一个新视频**（中间产物会清掉）。

## 3. 续接：`续接视频.ps1`（显存不够做长片）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\qwen-image-2.1\续接视频.ps1 `
  -Video "C:\Users\wangzimu\Desktop\视频\video-0002-wan-20261024-124801.mp4" `
  -Prompt "镜头继续推进，海浪持续拍打礁石" -Segments 2 -Seconds 5 -NoPause
```

取上一段**最后一帧** → 当首帧再生成 → PyAV 拼接。显存占用与单段相同，所以再长的片子也能做。

## 4. 画质/速度怎么平衡（重要）

**推荐流水线：低分辨率生成（快）→ Lanczos 放大 → FILM 插帧**

| 方案 | 生成耗时 | 后期耗时 | 合计 | 成片 |
|---|---|---|---|---|
| 直接生成 720p/24fps | 362 秒 | 0 | **6 分钟** | 1280×720 @24fps |
| **480p 生成 + 放大 1.5× + 插帧 2×** | 125 秒 | 30 秒 | **2.5 分钟** | 1248×720 @48fps |
| 480p 生成 + 放大 2× + 插帧 2× | 125 秒 | 35 秒 | 2.7 分钟 | 1664×960 @48fps |

结论：
1. **草稿/定型阶段一律用 832×480**（2 分钟/5 秒），不要为了清晰度直接上 720p。
2. 满意后用 `-Scale 1.5 -Interp 2`，2.5 分钟得到 720p/48fps，比直接生成 720p **快 2.4 倍且更流畅**。
3. **放大不超过 2×**：Lanczos 超过 2× 会明显发糊；真要 4K 只能在界面里用 SeedVR2 超分。
4. 插帧别超过 4×：帧率太高会让运动显得"滑"但不自然，24→48 最稳。
5. 需要更长时优先**续接**（分段 5 秒），而不是一次生成 10 秒（后者显存和耗时都翻倍）。

## 5. 生成端内部分解

1. 读图尺寸 → 算分辨率与帧数
2. 秋叶版 ComfyUI（8189）没跑就自动启动，用完自动关闭（`-KeepServer` 保留）
3. 图复制到 `D:\ComfyUI-aki-v3.2\ComfyUI\input\`
4. 提交：`LoadImage` → `Wan22ImageToVideoLatent`(start_image) → `KSampler` → `VAEDecode` → `CreateVideo` → `SaveVideo`
5. 调 `整理视频.ps1` 归位编号、PyAV 抽 3 帧预览

## 6. 跑完必须做

1. `present` 交付 **mp4 + 2 张预览帧**（对话里 mp4 不能内嵌播放）
2. 告诉用户去 `C:\Users\wangzimu\Desktop\视频\` 双击播放
3. 报告：分辨率、时长、帧率、耗时、文件名
4. 提醒：**没有音频**（Wan 2.2 不支持）；要音频只能上 MiniMax H3

## 7. 提示词写法

要写**怎么动**：✅"镜头缓慢推进，海浪拍打礁石，云层流动"；❌"一片海滩有灯塔"。

## 8. 失败排查

| 现象 | 处理 |
|---|---|
| ComfyUI 启动超时 | 关掉占显存程序（Strata/Ollama） |
| `CUDA out of memory` | 降 `-Seconds`（3）和 `-Steps`（12） |
| 视频几乎静止 | 提示词加明确运动词，或提 `-Steps` |
| 插帧失败 | 看 8189 是否起来；FILM 模型在 `models\frame_interpolation\` |
| 拼接后色调跳变 | 段与段用同一 `-Prompt`，seed 已固定为 1000+段号 |

## 9. 相关 skill

- 首帧可用 `text-to-image`（文生图skill）生成
- 已有视频要改风格用 `video-to-video`（视频生视频skill）
- 拼接/延长/裁剪视频用 `video-edit`（视频编辑skill）
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

`图生视频.ps1` 已接入共享模块 `D:\qwen-image-2.1\_vram.ps1`：
生成前快照 Strata / Ollama → 停止或卸载 → 生成 → 自动恢复（秋叶引擎调用带 `-KeepChatBackend`，避免两套快照打架）。
`-KeepChatBackend` 可跳过快照。**实测**：Ollama 装 9B 时跑 2 秒/4 步 → 卸载 → 生成 45.1 秒 → 恢复 9B，状态文件无残留。
