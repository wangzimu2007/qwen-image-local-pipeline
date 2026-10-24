# v0.3.2 — 发布 8 个 ComfyUI 工作流

把项目里实际在用的 8 个工作流一并开源，可直接拖进 ComfyUI 界面使用。

## 新增 `workflows/`

| 文件 | 用途 |
|---|---|
| `z-image-turbo-nvfp4.json` | Z-Image Turbo 基础文生图 |
| `z-image-t2i-kook-mist.json` | Z-Image + 风格 LoRA 文生图（朦胧质感） |
| `z-image-i2i-kook-mist.json` | Z-Image + 风格 LoRA 图生图（保留构图改氛围） |
| `z-image-controlnet-nvfp4.json` | Z-Image + ControlNet Union（线稿/深度/姿态） |
| `qwen-image-edit-2511.json` | Qwen-Image-Edit-2511 指令编辑 |
| `qwen-t2i-2512.json` | Qwen-Image-2512 文生图 |
| `seedvr2-video-upscale.json` | SeedVR2 3B 视频超分 |
| `film-frame-interpolation.json` | FILM 视频插帧（24→48fps） |

`workflows/README.md` 写明：依赖模型、跑在哪个版本、每个工作流的参数要点与坑。

## 关键要点（README 里展开）

- Z-Image：`lumina2` 编码器 + `ae` VAE，16 的倍数分辨率，**LoRA 插在 UNETLoader 与 ModelSamplingAuraFlow 之间**
- Qwen：GGUF 的 Qwen2.5-VL 编码器**不能用**，必须用 Comfy-Org 的 fp8 编码器；Edit-2511 必须开 zero_cond_t
- SeedVR2：**前端子图模板，API 提交不了**，只能界面跑；1080p 必须开 VAE 分块
- FILM：模型必须放 `models\frame_interpolation\`

## 注意

工作流里引用的是 **ComfyUI 下拉框里的模型名**，模型本身不随仓库分发（见 `NOTICE.md`）。