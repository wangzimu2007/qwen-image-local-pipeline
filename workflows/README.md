# ComfyUI 工作流

本目录收录项目里实际用到的 8 个 ComfyUI 工作流。**都是可直接拖进界面的 UI 格式**（不是 API 格式）。

## 安装

```powershell
# 方式一：放到 ComfyUI 的 workflows 目录（界面左侧「工作流」会直接列出来）
Copy-Item workflows\*.json "D:\你的ComfyUI\user\default\workflows\"

# 方式二：直接把 json 拖进 ComfyUI 窗口
```

模型不在本仓库分发，见仓库根目录 `NOTICE.md` 里的清单与来源。

## 清单

| 文件 | 用途 | 依赖模型 | 跑在 |
|---|---|---|---|
| `z-image-turbo-nvfp4.json` | Z-Image Turbo 基础文生图（官方模板 nvfp4 版） | `z_image_turbo_nvfp4` + `qwen_3_4b` + `ae` | 0.42+（桌面版/自建版） |
| `z-image-t2i-kook-mist.json` | **Z-Image + 风格 LoRA 文生图**（朦胧质感） | 同上 + 风格 LoRA | 0.42+ |
| `z-image-i2i-kook-mist.json` | **Z-Image + 风格 LoRA 图生图**（保留构图改氛围） | 同上 + 风格 LoRA | 0.42+ |
| `z-image-controlnet-nvfp4.json` | Z-Image + ControlNet Union（线稿/深度/姿态控制） | 同上 + `Z-Image-Turbo-Fun-Controlnet-Union` | 0.42+ |
| `qwen-image-edit-2511.json` | Qwen-Image-Edit-2511 指令编辑 | `qwen-image-edit-2511-Q4_K_M` + `qwen_2.5_vl_7b_fp8` + `qwen_image_vae` | 0.30+ |
| `qwen-t2i-2512.json` | Qwen-Image-2512 文生图 | `qwen-image-2512-Q3_K_M` + 同上编码器/VAE | 0.30+ |
| `seedvr2-video-upscale.json` | SeedVR2 3B 视频超分（nvfp4） | `seedvr2_3b_nvfp4` + `seedvr2_ema_vae_fp16` | 0.30+ |
| `film-frame-interpolation.json` | FILM 视频插帧（24→48fps） | `film_net_fp16`（放 `frame_interpolation` 目录） | 0.30+ |

## 各工作流的要点

### Z-Image 系列

- 采样：`res_multistep` + `simple`，cfg **1.0**，shift **3.0**，**8 步**（12 也可，别用 16）
- 编码器类型必须 `lumina2`；VAE 用 `ae.safetensors`（**不是** Qwen 的 VAE）
- 分辨率必须是 **16 的倍数**（832×1216 / 1024×1024 / 1216×832）
- **风格 LoRA 插在 `UNETLoader` 与 `ModelSamplingAuraFlow` 之间**
- 图生图：`LoadImage → VAEEncode → KSampler.latent_image`，用 `denoise` 控制改造幅度
  （0.45~0.55 保留构图改氛围，0.6+ 大改，1.0 等于重生成）

### Qwen 系列

- 2512 文生图：`UnetLoaderGGUF` + `ModelSamplingAuraFlow`(shift 3.0) + `CLIPLoader`(qwen_image)
  + 两个 `CLIPTextEncode` + `EmptySD3LatentImage` + `KSampler`(euler/simple, cfg 2.5)
- Edit-2511 指令编辑：参考图走 `TextEncodeQwenImageEditPlus`，负面用 `ConditioningZeroOut`；
  **必须启用 zero_cond_t**（本项目脚本用 `--model-args qwen_image_zero_cond_t=1`）
- **GGUF 版 Qwen2.5-VL 编码器在 ComfyUI 里不可用**（视觉权重布局不兼容），必须用 Comfy-Org 的 fp8 编码器

### SeedVR2 超分

- **这是前端子图模板，API 提交不了**（`seedvr2` 节点在 `/object_info` 里没有 input 定义），
  只能在界面里手动跑。要命令行批量超分请用官方 CLI（见 `docs/03-upscale.md`）
- 1080p 目标必须开 VAE 分块，否则解码阶段显存爆掉（实测 25.2 GB > 24 GB）

### FILM 插帧

- 模型目录 **必须是 `models\frame_interpolation\`**（放错目录下拉框里看不到）
- 24fps→48fps 只用 15 秒左右（121→241 帧）

## 与技能、脚本的关系

- 这些工作流是**界面里可调参的版本**
- 仓库 `scripts\` 下是**命令行版本**（同样的图结构，参数化成配置）
- `skills\` 下是**给 AI 助手用的判断规则**

三者等价，按你的使用习惯选一种即可。
