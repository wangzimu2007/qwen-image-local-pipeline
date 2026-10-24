# 05 · 踩坑清单（照着躲能省几小时）

> 全部是实测踩出来的，按「现象 → 原因 → 解决」写。

## A. 环境类

### A1. 脚本中文全变乱码 + 一堆"意外的标记"
- **现象**：`.ps1` 报语法错误，但内容看着没问题
- **原因**：Windows PowerShell 5.1 读取无 BOM 的 UTF-8 文件时按 GBK 解码
- **解决**：所有含中文的 `.ps1` 必须存成 **UTF-8 with BOM**
  ```powershell
  $b = [IO.File]::ReadAllBytes($p)
  if (-not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) {
      $bom = [byte[]](0xEF,0xBB,0xBF)
      $all = New-Object byte[] ($bom.Length + $b.Length)
      [Array]::Copy($bom,0,$all,0,3); [Array]::Copy($b,0,$all,3,$b.Length)
      [IO.File]::WriteAllBytes($p, $all)
  }
  ```
  校验：`[Parser]::ParseFile($p,[ref]$null,[ref]$errs)` 错误数为 0

### A2. 编辑工具改脚本后 BOM 丢失
- **现象**：改完立刻报语法错
- **原因**：很多编辑器/工具写回时会去掉 BOM
- **解决**：每次改完执行 A1 的补 BOM 片段

### A3. `$x.Count` 返回空
- **现象**：`if ($files.Count -eq 0)` 判断失效
- **原因**：PS 5.1 中单对象没有 `.Count`
- **解决**：一律写 `@($x).Count`

### A4. 嵌套调用别的脚本时报 NativeCommandError
- **现象**：子脚本明明成功，父脚本却中断
- **原因**：原生命令（exe）写 stderr，`$ErrorActionPreference='Stop'` 把它当终止错误
- **解决**：调用前后临时改成 `Continue`（本项目 `common.ps1` 的 `Invoke-Exe` 已处理）

### A5. 函数参数叫 `$Args`
- **现象**：参数莫名丢失
- **原因**：`$args` 是 PowerShell 自动变量
- **解决**：改名叫 `$ScriptArgs`

## B. stable-diffusion.cpp 类

### B1. 8 步出糊图
- **原因**：Turbo 模型没带 `--sigmas` 蒸馏序列
- **解决**：见 `docs/01-image.md` 的 sigma 列表

### B2. 编辑画质退化
- **原因**：2511 没开 `zero_cond_t`
- **解决**：加 `--model-args qwen_image_zero_cond_t=1`（脚本会自动回退尝试三种写法）

### B3. 编辑用错 VAE
- **现象**：偏色、发糊
- **解决**：编辑用 `qwen_image_vae`（v1），文生图用 `qwen_image_2.1_vae_bf16`

### B4. 报 `CUDA error: unknown error` / 退出码 -1073740791
- **现象**：加载完权重就崩，512² 也崩
- **原因**：GPU 状态异常（长时间/多进程切换后）
- **解决**：**重启系统**；仍崩则换 ComfyUI 路线（同卡同驱动下 ComfyUI 正常）

## C. ComfyUI 类

### C1. `Value not in list: unet_name ...`
- **原因**：`config.ps1` 里的模型名和 ComfyUI 下拉框不一致
- **解决**：打开 ComfyUI 界面看准确文件名，或用 `/object_info/UNETLoader` 查列表

### C2. `LoadImage` 找不到图
- **原因**：ComfyUI 只认自己 `input/` 目录下的文件
- **解决**：脚本已用 `Copy-ToComfyInput` 自动复制；手工调用要自己放

### C3. 官方 SeedVR2 模板 API 提交不了
- **原因**：模板里的 `seedvr2` 是**前端子图**，没有后端输入定义
- **解决**：用官方 CLI（`inference_cli.py`），见 `docs/03-upscale.md`

### C4. 生成的文件找不到
- **原因**：产物落在 ComfyUI 的 `output/` 而不是项目输出目录
- **解决**：`organize.ps1` 会搬；或看 `ComfyOutputDir` 配置

## D. SeedVR2 类

### D1. 自带下载器失败（10061）
- **原因**：代码里写死了 `huggingface.co`
- **解决**：手动下载模型放到 `models/SEEDVR2/`（见 NOTICE.md 清单）

### D2. `Cannot open image file`
- **原因**：OpenCV 读不了**中文路径**
- **解决**：复制到英文临时目录再处理（脚本已内置）

### D3. `UnicodeEncodeError: 'gbk' codec`
- **原因**：CLI 打印 emoji，GBK 控制台编码不了
- **解决**：`$env:PYTHONIOENCODING='utf-8'; $env:PYTHONUTF8='1'`（脚本已设）

### D4. 1080p 崩在 Phase 3（解码）
- **原因**：不开 VAE 分块，显存吃到 25 GB+
- **解决**：`-Resolution >= 900` 时脚本自动加 `--vae_decode_tiled`，并把 batch 降到 13

### D5. `--model_dir` 无效
- **原因**：默认是**相对于当前工作目录**的 `./models/SEEDVR2`
- **解决**：永远传绝对路径（脚本已传）

### D6. 依赖把 torch 升级了
- **原因**：`pip install -r requirements.txt` 会重装 torch
- **解决**：`pip install --no-deps` 逐个补缺的包

## E. 视频参数类

### E1. 帧数报错
- **原因**：Wan 要求帧数 = 4n+1
- **解决**：`-Seconds` 让脚本算，或手动取 5/9/13/…/121/241

### E2. 拼接后画面变形
- **原因**：分辨率取第一段，比例不同被拉伸
- **解决**：先统一各段尺寸，或接受拉伸

### E3. `trim` 输出时长错乱（2 秒变 0.04 秒）
- **原因**：直接 `frame.reformat()` 导致时间基错乱
- **解决**：走 `to_image()` → `VideoFrame.from_image()`（本项目已如此）

### E4. 插帧后很卡/很怪
- **原因**：插帧倍数过高
- **解决**：`-Interp` 别超 4；24→48 最自然

## F. 显存类

| 现象 | 处理 |
|---|---|
| 出图前就 OOM | 关掉本地聊天大模型（Ollama 等常驻 19~20 GB 显存） |
| 视频生成 OOM | 降分辨率到 640²、步数到 12 |
| 超分 OOM | `-BatchSize 9` 或 `-Resolution 720` |
| 1080p 超分崩 | 确认已开 VAE 分块 + batch 13 |

一张 24 GB 卡同时只能跑一件事：出图 / 视频 / 超分是三套不同权重，别并发。
