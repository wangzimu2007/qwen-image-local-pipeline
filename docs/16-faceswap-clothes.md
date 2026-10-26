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