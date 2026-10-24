# ============================================================
#  配置模板：复制为 config.ps1 后按你的环境修改
#  Copy-Item config.sample.ps1 config.ps1
# ============================================================

$Cfg = @{
    # ---------- stable-diffusion.cpp（文生图 / 图生图 / 指令编辑） ----------
    SdCli          = 'D:\sd-cpp\sd-cli.exe'          # sd-cli 可执行文件
    ModelT2I       = 'D:\models\Qwen-Image-2.1-Turbo-AD-Q6_K.gguf'
    ModelT2I_Te    = 'D:\models\Qwen-Image-2.1-Turbo-Uncensored-Q8_0.gguf'
    ModelT2I_Vae   = 'D:\models\qwen_image_2.1_vae_bf16.safetensors'
    ModelRedraw    = 'D:\models\Qwen-Image-2.1-Turbo-AD-Q6_K.gguf'   # 图生图用的去噪模型
    ModelEdit      = 'D:\models\qwen-image-edit-2511-Q4_K_M.gguf'
    ModelEdit_Te   = 'D:\models\Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf'
    ModelEdit_Mmproj = 'D:\models\mmproj-F16.gguf'
    ModelEdit_Vae  = 'D:\models\qwen_image_vae.safetensors'

    # Turbo 模型的 8 步蒸馏 sigma 序列（漏了会出糊图）
    T2ISigmas      = '1.0,0.978453,0.95418,0.926626,0.89508,0.845148,0.704534,0.414568,0.0'

    # 指令编辑必须启用 zero_cond_t（不启用画质会明显退化）
    EditExtraArgs  = @('--model-args', 'qwen_image_zero_cond_t=1')
    EditCfgScale   = 2.5
    EditFlowShift  = 3
    EditSteps      = 20

    # ---------- ComfyUI（视频生成 / 插帧） ----------
    ComfyRoot      = 'D:\ComfyUI'                     # ComfyUI 根目录
    ComfyPython    = 'D:\ComfyUI\python\python.exe'   # 跑 PyAV 用的 Python
    ComfyPort      = 8188
    ComfyOutputDir = ''      # ComfyUI 产物目录；留空 = <ComfyRoot>\output。改过就填这里
    ComfyStartCmd  = ''                               # 可选：启动脚本完整路径
    ComfyStopCmd   = ''                               # 可选：停止脚本完整路径

    # ComfyUI 里看到的模型名（下拉框里显示的名字）
    WanUnet        = 'wan2.2_ti2v_5B_fp16.safetensors'
    WanClip        = 'umt5_xxl_fp8_e4m3fn_scaled.safetensors'
    WanVae         = 'wan2.2_vae.safetensors'
    FilmModel      = 'film_net_fp16.safetensors'

    # ---------- SeedVR2 官方 CLI（AI 超分） ----------
    SeedVR2Root    = 'D:\seedvr2\ComfyUI-SeedVR2_VideoUpscaler'
    SeedVR2Python  = 'D:\ComfyUI\python\python.exe'   # 需要 torch + av + cv2 + diffusers
    SeedVR2Models  = 'D:\seedvr2\ComfyUI-SeedVR2_VideoUpscaler\models\SEEDVR2'
    SeedVR2Dit     = 'seedvr2_ema_3b_fp8_e4m3fn.safetensors'

    # ---------- FlashVSR+（高分辨率超分，走 ComfyUI 节点） ----------
    # 需要 ComfyUI_FlashVSR 节点 + plus 权重 + flashvsr_attn(triton) 内核，见 docs/03-upscale.md
    FlashVSRDit     = 'turbo_dit_plus.safetensors'
    FlashVSRProj    = 'lq_proj_in_plus_turbo.safetensors'
    FlashVSREmb     = 'posi_prompt_plus.pth'
    FlashVSRTcd     = 'TCDecoder_plus.ckpt'
    FlashVSRVersion = 'plus_turbo'
    # ---------- 输出目录 ----------
    OutImageDir    = 'D:\ai-output\images'            # 生成图片
    OutVideoDir    = 'D:\ai-output\videos'            # 成品视频（自增编号）
    OutRawDir      = 'D:\ai-output\raw'               # ComfyUI 原始输出（中间产物）

    # ---------- Z-Image Turbo（ComfyUI，快速文生图 / 风格 LoRA） ----------
    ZImagePort     = 8188
    ZImageUnet     = 'z_image_turbo_nvfp4.safetensors'
    ZImageClip     = 'qwen_3_4b.safetensors'
    ZImageVae      = 'ae.safetensors'

    # ---------- MOSS-Image（ComfyUI，写实人像） ----------
    MossPort       = 8188
    MossUnet       = 'moss_image_sft_int8_convrot.safetensors'
    MossClip       = 'qwen3.5_9b_w4a8_gptq.safetensors'
    MossVae        = 'flux2-vae.safetensors'
    MossAccelLora  = 'moss_image_sft_8steps_dmd.safetensors'

    # ---------- MiniMax H3（ComfyUI，带音频视频） ----------
    H3Port         = 8189
    H3Unet         = 'minimax_h3_fl2va_pruned_int8_convrot.safetensors'
    H3Clip         = 'qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors'
    H3VideoVae     = 'minimax_h3_video_vae_fp16.safetensors'
    H3AudioVae     = 'minimax_h3_audio_vae_fp32.safetensors'
    H3TurboLora    = 'minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors'

    # ---------- 显存快照（生成前停本地模型，结束后恢复） ----------
    VramStateDir     = ''                             # 留空 = <repo>\.state
    StrataUrl        = 'http://127.0.0.1:8080'
    OllamaUrl        = 'http://127.0.0.1:11434'
    StrataActionsDir = ''                             # 留空 = %LOCALAPPDATA%\Strata\actions
    # ---------- 默认参数 ----------
    DefaultFps     = 24
    DefaultSeconds = 5
    DefaultSteps   = 20
    DefaultWidth   = 832
    DefaultHeight  = 480
    VramWaitSec    = 120                              # 等显存释放的最长秒数
}