# NOTICE — 第三方组件与模型

本项目**不包含**任何模型权重或第三方软件。以下清单仅供使用者自行下载安装，
各组件许可证由其各自发布方决定，**不与本项目的 MIT 许可证混合**。

## 一、软件依赖

| 组件 | 用途 | 许可证 | 获取 |
|---|---|---|---|
| stable-diffusion.cpp | 文生图 / 图生图 / 指令编辑推理 | MIT | https://github.com/leejet/stable-diffusion.cpp |
| ComfyUI | 视频生成与插帧的推理后端 | GPL-3.0 | https://github.com/comfyanonymous/ComfyUI |
| ComfyUI-GGUF | 让 ComfyUI 加载 GGUF 量化模型 | Apache-2.0 | https://github.com/city96/ComfyUI-GGUF |
| ComfyUI-SeedVR2_VideoUpscaler | AI 超分核心（含独立 CLI） | Apache-2.0 | https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler |
| PyAV | 视频解码/编码/抽帧 | BSD-3-Clause | `pip install av` |
| Pillow | 图像缩放与读写 | HPND | `pip install pillow` |

> 说明：ComfyUI 是 GPL-3.0。本项目**不捆绑也不修改** ComfyUI，仅通过其 HTTP API 调用，
> 两者是独立程序。若你要二次分发整合包，请自行遵守 GPL。

## 二、模型清单（自行下载，禁止随本项目分发）

### 图片生成 / 编辑

| 用途 | 文件 | 体积 | 下载源 | 许可证 |
|---|---|---|---|---|
| 文生图去噪 | `Qwen-Image-2.1-Turbo-*.gguf` | 6~8 GB | HuggingFace（Qwen 官方/社区量化） | Apache-2.0（以模型卡为准） |
| 文生图编码器 | `Qwen-Image-2.1-Turbo-*-Q8_0.gguf` | 8 GB | 同上 | 同上 |
| 文生图 VAE | `qwen_image_2.1_vae_bf16.safetensors` | 0.63 GB | 同上 | 同上 |
| 指令编辑去噪 | `qwen-image-edit-2511-Q4_K_M.gguf` | 12.3 GB | 社区 GGUF 量化 | Apache-2.0（Qwen-Image-Edit） |
| 编辑编码器 | `Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf` + `mmproj-F16.gguf` | 5.6 GB | 同上 | Apache-2.0 |
| 编辑 VAE | `qwen_image_vae.safetensors` | 0.24 GB | Comfy-Org 重打包 | 同上游 |

### 视频生成（Wan 2.2 TI2V-5B）

| 文件 | 体积 | 下载源 | 许可证 |
|---|---|---|---|
| `wan2.2_ti2v_5B_fp16.safetensors` | 9.99 GB | `Comfy-Org/Wan-2.2`（HF / ModelScope） | Apache-2.0 |
| `umt5_xxl_fp8_e4m3fn_scaled.safetensors` | 6.27 GB | 同上 | Apache-2.0 |
| `wan2.2_vae.safetensors` | 1.31 GB | 同上 | Apache-2.0 |

### AI 超分（SeedVR2）

| 文件 | 体积 | 下载源 | 许可证 |
|---|---|---|---|
| `seedvr2_ema_3b_fp8_e4m3fn.safetensors` | 3.16 GB | `numz/SeedVR2_comfyUI` | Apache-2.0 |
| `ema_vae_fp16.safetensors` | 0.47 GB | 同上（与 Comfy-Org 版本同哈希） | Apache-2.0 |

### 视频超分（FlashVSR+，可选高分辨率档）

| 文件 | 体积 | 下载源 | 许可证 |
|---|---|---|---|
| `turbo_dit_plus.safetensors` | 5.4 GB | `ruchangyao/FlashVSR_plus` | 以模型卡为准 |
| `lq_proj_in_plus_turbo.safetensors` | 1.1 GB | 同上 | 同上 |
| `TCDecoder_plus.ckpt` | 180 MB | 同上 | 同上 |
| `posi_prompt_plus.pth` | 4 MB | `OpenImagingLab/FlashVSR_Plus` | 同上 |
| `wan_2.1_vae.safetensors` | 242 MB | `Comfy-Org/Wan_2.1_ComfyUI_repackaged` | Apache-2.0 |

组件：`smthemex/ComfyUI_FlashVSR`（节点包装）、`OpenImagingLab/FlashVSR`（上游模型）。
Triton 内核 `flashvsr_attn` 由节点自带源码本地编译。
### 帧插值（FILM）

| 文件 | 体积 | 下载源 | 许可证 |
|---|---|---|---|
| `film_net_fp16.safetensors` | 66 MB | `Comfy-Org/Frame-Interpolation` | **以模型卡为准，商用前请自行确认** |

## 三、可选替代

| 方案 | 说明 |
|---|---|
| Topaz Video（商业） | 超分/补帧质量更高，但需订阅（官方页面 2026-10 约 $59/月） |
| Real-ESRGAN / 4x-UltraSharp | 逐帧 AI 超分，可一键但会轻微闪烁，体积约 67 MB |
| 秋叶（aaaki）ComfyUI 整合包 | 国内一键环境，**请从其官方发布页获取，不要二次分发** |

## 四、合规提醒

1. 模型权重受各自许可证约束，**多数允许商用但要求署名/保留声明**，请阅读模型卡。
2. FILM 等研究模型可能限制商用，**发布作品前请确认**。
3. 生成的图像/视频若涉及肖像、商标、版权素材，责任由使用者承担。

## 五、音频模型（v0.4.0 新增）

| 模型 / 引擎 | 用途 | 上游许可（以仓库为准） | 商用 |
|---|---|---|---|
| Demucs v4 htdemucs_ft | 人声分离 | MIT | ✅ |
| faster-whisper + Whisper large-v3-turbo | 转录 | MIT | ✅ |
| Chatterbox Multilingual | 语音克隆 | MIT（Resemble AI） | ✅ |
| pyannote segmentation + 3D-Speaker | 说话人分离 | MIT / Apache-2.0 | ✅ |
| AudioSR | 音频超分 | MIT | ✅ |
| Basic Pitch | 音频转 MIDI | Apache-2.0 | ✅ |
| **Resemble Enhance** | 降噪/增强 | **非商业类许可** | ⚠️ **商用前必须自行确认** |

生成/处理结果若涉及他人声音、肖像或版权音乐，责任由使用者承担。
