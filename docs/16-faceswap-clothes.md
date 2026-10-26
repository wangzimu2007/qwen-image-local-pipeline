# 换脸 / 换衣（局部替换）能力说明与使用（2026-10-27）

## 结论先看

| 需求 | 能不能做 | 用什么 | 状态 |
|---|---|---|---|
| 图片换衣（改款式/颜色/材质） | ✅ 好 | **Qwen-Image-Edit-2511**（已有 `编辑.ps1`） | 实测 194 秒出图，人脸/背景保持好 |
| 图片局部改（只动一块） | ✅ | `局部重绘.ps1`（Rect/Mask） | 已有 |
| 图片换脸（指定某人脸） | ✅ | **新装**：SCRFD + ArcFace + inswapper_128 | 实测 3.7 秒/张 |
| 视频换脸 | ✅ 可跑 | 同一套模型逐帧 + 原音轨回封 | 5 秒 121 帧 = 126 秒（CPU，约 1 秒/帧） |
| 视频换衣 | ⚠️ 不成熟 | 需逐帧 VTON + 去闪，本地无成熟方案 | 不建议依赖 |

## 已下载的换脸模型（D:\qwen-image-2.1\models\faceswap）

| 文件 | 大小 | 作用 |
|---|---|---|
| `insightface-buffalo-l-onnx\scrfd_10g.onnx` | 16 MB | 人脸检测 + 5 关键点 |
| `insightface-buffalo-l-onnx\arcface_w600k_r50.onnx` | 166 MB | 身份特征提取 |
| `inswapper_128.onnx\inswapper_128.onnx` | 529 MB | 换脸主模型 |

## 用法

```powershell
# 图片（默认输出到 桌面\Qwen 图片\测试\）
D:\qwen-image-2.1\换脸.ps1 -Src 某人的脸.png -Dst 目标.png

# 视频（默认输出到目标视频同目录）
D:\qwen-image-2.1\换脸.ps1 -Src 某人的脸.png -Dst clip.mp4

# 直接调 Python（可指定输出）
D:\ComfyUI-aki-v3.2\python\python.exe D:\qwen-image-2.1\换脸.py --src a.png --dst b.mp4 --out c.mp4 --max-faces 1
```

## 实现要点（避坑记录）

- SCRFD 的 anchor 范围必须固定 640²，**不能乘 stride**（否则关键点飞到图外、贴回白块）
- inswapper 的 `target` 输入要求 **0~1 浮点**（BGR 不换通道），传 0~255 会全白
- 输出是 NCHW 0~1，要 `transpose` 再 ×255
- 贴回用逆仿射 + 高斯羽化 mask，避免边界硬切
- Windows 中文路径要用 `np.fromfile + cv2.imdecode`（`cv2.imread` 会失败）

## 性能与后续优化

- 当前 ONNX 走 CPU（onnxruntime CUDA 需要 cuDNN9/cuBLAS，本机 aki 环境未配）
- 视频 121 帧 126 秒；可优化：关键帧检测 + 光流跟踪、跳帧检测、或补齐 CUDA 运行库

## 使用边界

仅限本人或已获肖像权人同意的素材；不要用于伪造他人身份、诈骗、成人内容或任何违法用途。
成人向素材不处理、不保留产物。

## 两图换衣（2026-10-27 实测）

**需求**：衣服不用文字描述，而是**给第二张图**，把那张图里人物穿的衣服套到目标人物身上。

**实现**：Qwen-Image-Edit-2511 支持多参考图（sd-cli 的 `-r` 可重复）。`编辑.ps1` 新增 `-RefImage`：

```powershell
D:\qwen-image-2.1\编辑.ps1 -Image A.png -RefImage B.png `
  -Prompt "把图1人物的上衣换成图2人物穿的绿色针织开衫（款式、颜色、材质以图2为准），图1人物的脸、发型、姿势和背景保持不变" `
  -Steps 20 -Width 768 -Height 1024 -OutDir "C:\Users\wangzimu\Desktop\Qwen 图片\测试" -NoOpen -NoAsk
```

实测（768×1024，20 步）：

| 方向 | 耗时 | 结果 |
|---|---|---|
| B 的绿开衫 → A（白 T 人物） | 235.6 秒 | 款式/纽扣/材质与图 2 一致，A 的脸/姿势/背景保持 |
| A 的白 T → B（绿开衫人物） | 226.0 秒 | 反向同样成立（可做"两个角色互换衣服"）|

**注意**：这是**参考图条件重绘**，不是像素级服装贴合；追求"衣服纹理完全不变"要用 IDM-VTON/CatVTON（未装，9 GB 级）。

## 视频换脸加速（2026-10-27）

| 版本 | 每帧耗时 | 相对基线 |
|---|---|---|
| 初版（640 检测 + 每帧检测，CPU） | 1.04 秒 | 1× |
| 检测降到 320 + 每 12 帧检测 + LK 光流跟踪 | 0.52 秒 | 2.0× |
| 再换 onnxruntime(-gpu) 1.22 + CUDA 12 库目录 | **0.22 秒** | **4.7×** |

- `换脸.ps1` 对视频自动用 `det-size=320, det-every=12`；图片仍用 640
- 可加 `-Gpu` 尝试 CUDA；实测 ORT 仍回落 CPU（缺 `cudart`/cuDNN 精确匹配），CPU 版已够快
- 121 帧 5 秒片：126 秒 → 27 秒