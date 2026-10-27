# 换脸增强 + 视频换衣（2026-10-27 安装与实测）

## 一、换脸：现在有三条路

| 方案 | 入口 | 效果 | 速度（CPU） |
|---|---|---|---|
| 原流程 + CodeFormer 增强（新） | `换脸.ps1`（默认开启，`-NoEnhance` 关闭） | 比原版锐一点（清晰度 176→184） | 图片约 5 秒 |
| **FaceFusion（新装，推荐）** | `FaceFusion换脸.ps1 -Src 脸图 -Dst 目标 -Model alphaface_256` | **alphaface_256 / hyperswap 明显更自然**：保留原表情、肤色融合更好 | 图片约 13 秒；视频约 1.5 秒/帧（不增强）、约 2.4 秒/帧（带 CodeFormer） |
| 现有 inswapper（不增强） | `换脸.ps1 -NoEnhance` | 基础 | 图片约 4 秒 |

### FaceFusion 安装信息

| 项 | 值 |
|---|---|
| 版本 | 3.9.2（2026-10-26 更新） |
| 代码 | `D:\audio-tools\facefusion-src`（GitHub 网页被墙，用 api.github.com 逐文件镜像） |
| 环境 | `D:\audio-tools\facefusion-venv`（Python 3.13，onnxruntime CPU） |
| 模型 | `.assets\models`：alphaface_256、hyperswap_1a_256、inswapper_128、arcface、yunet、2dfan4、codeformer、gfpgan_1.4 等（HF 镜像下载，约 2 GB） |
| 处理器 | `face_swapper` + `face_enhancer`（可加 face_masker/face_editor 等） |

```powershell
# 图片
FaceFusion换脸.ps1 -Src 我的脸.png -Dst 目标.png
# 视频（alphaface + CodeFormer）
FaceFusion换脸.ps1 -Src 我的脸.png -Dst 视频.mp4 -Model alphaface_256 -Enhancer codeformer
# 更快：关增强
FaceFusion换脸.ps1 -Src face.png -Dst clip.mp4 -Enhancer none
```

### 遇到并修好的坑

1. **中文输出路径会失败** → 封装先写 ASCII 临时文件，再移动到中文路径
2. **无声视频在“恢复音轨”步骤失败** → 封装检测无音轨时先补一条静音轨
3. **`--processors` 为空** → 必须在 `facefusion-src` 目录下运行
4. **首次运行会自动下载缺失模型**（走 HF 镜像，可用）

## 二、视频换衣：ViViD（专用视频试衣模型，已装）

| 项 | 值 |
|---|---|
| 模型 | ViViD（阿里元境，Apache-2.0，arXiv 2405.11794） |
| 代码 | `D:\audio-tools\vivid-src`（API 镜像，含官方 demo 数据） |
| 权重 | ViViD 12.77 GB + SD image variations 5.78 GB + motion module 1.73 GB + VAE 0.62 GB |
| 环境 | `D:\audio-tools\vivid-venv`（torch 2.11+cu128 复用、diffusers 0.24、transformers 4.44） |
| 实测 | 官方 demo `upper1`：48 帧 / 20 步 / 384×512 → **166 秒**，成功把上衣换成给定衣服 |
| 入口 | `ViViD换衣.ps1 -Demo upper1` / `-Demo lower1` |

```powershell
ViViD换衣.ps1 -Demo upper1            # 官方 demo（自带视频+衣服+预处理数据）
ViViD换衣.ps1 -Demo lower1 -L 24
```

### 换**自己的视频**还缺预处理

ViViD 需要 5 类输入，官方 demo 已带齐；自定义视频需要：

| 输入 | 说明 | 现成工具 |
|---|---|---|
| `videos/*.mp4` | 原视频 | — |
| `agnostic/*.mp4` + `agnostic_mask/*.mp4` | 去掉衣服区域的人体视频 | README 推荐 OOTDiffusion 逐帧抽 |
| `densepose/*.mp4` | DensePose 姿态视频 | `vid2densepose` |
| `cloth/*.jpg` + `cloth_mask/*.jpg` | 衣服图 + 衣服 mask | SAM / 分割模型 |

这几步**尚未自动化**（是下一步要补的）；也可以先用官方 demo 换衣服验证效果。

## 三、流水线接入

`流水线.ps1` 新增工具：

| 工具名 | 对应脚本 |
|---|---|
| `faceswap-ff` | `D:\audio-tools\FaceFusion换脸.ps1` |
| `video-tryon` | `D:\audio-tools\ViViD换衣.ps1` |

## 四、磁盘与显存

| 项 | 占用 |
|---|---|
| `facefusion-src` + 模型 | 约 2.6 GB |
| `facefusion-venv` | 约 1.4 GB |
| `vivid-src`（含权重） | 约 20.9 GB |
| `vivid-venv` | 约 5.4 GB |
| 测试时峰值显存 | ViViD 约 20 GB（24 GB 卡可跑） |
