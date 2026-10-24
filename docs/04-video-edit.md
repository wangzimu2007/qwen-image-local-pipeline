# 04 · 视频后期：拼接 / 裁剪 / 放大 / 插帧

## 1. 拼接 —— `scripts\concat.ps1`

```powershell
scripts\concat.ps1 -Videos "a.mp4,b.mp4"
scripts\concat.ps1 -Videos "a.mp4,b.mp4" -Fps 24
```

- `-Videos`：**逗号分隔成一个字符串**（PowerShell `-File` 调用会把数组拍平，
  脚本已按 `,` `;` 拆分兼容）；也可以只写文件名，会到输出目录里找
- 分辨率统一取**第一段**，其它段等比拉伸
- 帧率默认跟第一段；`-Fps 24` 强制统一（自动补帧/丢帧）
- **无转场**（硬切）

实测：1280×720(5.04s) + 640×640@16fps(2.06s) → 1280×720@24fps / 7.08 秒，**2.5 秒完成**。

## 2. 裁剪 —— `scripts\trim.ps1`

```powershell
scripts\trim.ps1 -Video x.mp4 -Start 1 -Duration 3
```

`-Start` 起点秒数；`-Duration` 时长秒数（0 = 到结尾）。

## 3. 放大 + 插帧 —— `scripts\post.ps1`

```powershell
scripts\post.ps1 -Video x.mp4 -Scale 1.5 -Interp 2
```

| 参数 | 说明 | 实测（5 秒片） |
|---|---|---|
| `-Scale` | Lanczos 放大倍数（1 = 不放大） | ×1.5 → **2.3 秒** |
| `-Interp` | FILM 插帧倍数（2~16） | ×2 → **15~25 秒** |

- 放大是**纯插值**：提分辨率、不增加细节。要细节用 `ai-upscale.ps1`
- 插帧走 ComfyUI 的 `FrameInterpolationModelLoader` + `FrameInterpolate`（后端节点，可 API）
- 模型 `film_net_fp16.safetensors` 需放在 ComfyUI 的 `models/frame_interpolation/`

## 4. 输出整理 —— `scripts\organize.ps1`

```powershell
scripts\organize.ps1
scripts\organize.ps1 -SourceDir D:\ai-output\raw -DestDir D:\ai-output\videos
```

作用：

1. 把目标目录里**没编号**的视频按时间升序补上 `video-NNNN-<类型>-<时间戳>.mp4`
2. 把来源目录里的视频搬进目标目录并编号
3. 打印最新成品的完整参数

## 5. 命名与目录约定

```
<OutVideoDir>/
  video-0001-wan-20260101-120000.mp4      ← wan: 图生/文生视频
  video-0002-aiup-20260101-120500.mp4     ← aiup: AI 超分
  video-0003-post-20260101-121000.mp4     ← post: 放大+插帧
  video-0004-join-20260101-121500.mp4     ← join: 拼接
  video-0005-trim-20260101-122000.mp4     ← trim: 裁剪
```

序号自增，**按名称降序**排序时最新的一定在最上面（Windows 资源管理器设成「名称 + 降序」）。

## 6. 常见组合

| 想要 | 做法 |
|---|---|
| 30 秒长片 | `extend.ps1 -Segments 5 -Seconds 5` |
| 两个镜头接一起 | `concat.ps1 -Videos "a,b"` |
| 成片不够清晰 | `ai-upscale.ps1 -Resolution 720` |
| 成片不够流畅 | `post.ps1 -Interp 2` |
| 要 720p 且 48fps | `video.ps1 -Action upscale -Preset final` |
| 只要中间 3 秒 | `trim.ps1 -Start 2 -Duration 3` |

## 7. 坑

- **拼接前先确认比例**：分辨率取第一段，比例不同会被拉伸变形
- **没有音轨**：整套流程只处理画面（Wan 产物本来无音），拼接也不会带音频
- **`trim` 的时间基**：实现里必须走 `to_image()` → `VideoFrame.from_image()`，
  直接 `frame.reformat()` 会导致输出时长错乱（实测 2 秒变 0.04 秒 / 1152fps）
- **临时文件**：中间产物都在 `%TEMP%\pipeline-*`，可随时删
