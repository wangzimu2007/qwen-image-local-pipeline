# 作业完成后自动继续（2026-10-27 验证）

## 结论

**可以自动返回，不需要用户再发消息。** 前提是本地模型会话用 `提交作业.ps1 -Wait` 提交任务，
而不是直接调用出图/出视频脚本。

## 机制

守护进程执行队列作业时会先卸载本地聊天模型（腾显存），跑完再恢复；
`-Wait` 会等四个条件**同时**满足才返回：

1. 所有作业的 `done` 文件存在
2. `.jobs\guardian.lock` 已释放（守护不再跑批）
3. `.jobs\last-batch.json` 的 `batchFinishedAt` 晚于本次提交（批末恢复已做完）
4. 本地聊天后端 `serving=true`（`Get-LocalBackends -Role chat`）

返回后模型在同一轮继续输出，不需要用户再发消息。

## 实测（2026-10-27）

| 任务 | 总耗时 | 产物 | 返回时后端 |
|---|---|---|---|
| zimage（图片）| **119.6 秒** | qwen-0194-zimg-*.png | ollama 11434 ✓ |
| videodub（视频配音）| **79.1 秒** | video-0070-promptdub-*.mp4 | ollama 11434 ✓ |
| i2v（图生视频）| **124.9 秒** | video-0072-wan-*.mp4 | ollama 11434 ✓ |

三次都打印 `✓ 聊天后端已就绪：ollama 11434`，且 GPU 回到 20.6 GB（qwen3.8 已重新加载）。

## 这次补的东西

### 1. 新增队列任务 `videodub`

```powershell
提交作业.ps1 -Task videodub -Video 视频.mp4 -Prompt "低沉男声，纪录片旁白" -Wait
```

默认自动加 `-Mode auto` 和 `-BurnSubtitles`；需要指定引擎时用 `-Extra "Engine=qwen-fast"`。

### 2. 支持绝对脚本路径

配音脚本在 `D:\audio-tools`，而 `提交作业/作业守护` 原先只按 `D:\qwen-image-2.1` 拼相对路径，
会报“找不到脚本”。现在两边都用 `[IO.Path]::IsPathRooted()` 判断。

### 3. 守护捕获子进程输出改 UTF-8

原先按 GBK 解码，出现“视频完成：”变成乱码、成品识别不到、作业被误判失败。
现在守护运行子进程前设 `Console.OutputEncoding=UTF8` 并用 `cmd /c chcp 65001` 包裹。

### 4. 成品识别优先视频

配音日志里 TTS 子日志会先打印“音频完成：xxx.wav”，原先会把它当成品；
现在收集所有候选，优先 `.mp4/.mov`，再图片，再音频/字幕。

## 用法（本地模型会话）

```powershell
# 出图
提交作业.ps1 -Task zimage -Prompt "..." -Wait -TimeoutSec 600
# 图生视频
提交作业.ps1 -Task i2v -Image 图.png -Prompt "..." -Wait -TimeoutSec 600
# 视频配音（出片后自动补声）
提交作业.ps1 -Task videodub -Video 视频.mp4 -Prompt "..." -Wait -TimeoutSec 600
# 一次出多张（同一批只卸载/恢复一次）
提交作业.ps1 -Task zimage -Prompt "..." -Count 2 -Wait
```

## 注意

- **不要直接调** `图生视频.ps1` / `Z画图.ps1` 等：它们会卸载正在服务对话的模型，对话会断。
- `-Wait` 默认 600 秒；i2v + H3 这类长任务建议 `-TimeoutSec 900`。超时只是脚本先返回，
  守护仍会跑完并写结果。
- 本地模型会话建议关闭「自动审查」，否则卸载窗口内的工具调用可能失败。
- 改过 `作业守护.ps1` 后必须重启守护进程才生效（旧进程内存里是旧代码）。
