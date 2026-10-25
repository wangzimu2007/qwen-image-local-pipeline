# 作业队列：让本地聊天模型安全地调用出图

## 问题

本地聊天模型（Strata 8080 / Ollama 11434）占着 15~22 GB 显存，出图脚本为腾显存会把**正在服务你的
聊天模型**卸载掉 → 对话立刻断线（`TRANSPORT Connection error`），而且脚本末尾的"恢复模型"那一步
没人执行（因为执行者已经下线）。

**本质**：卸载动作不能由"被卸载者"自己执行。

## 方案：作业队列 + 独立守护

```
本地聊天模型 ──提交──▶ .jobs\pending\<id>.json
     │                        │
     │（不卸载自己）           ▼
     │                  作业守护（独立进程，开机自启）
     │                  ① 快照聊天后端（Strata 变体 / Ollama 模型）
     │                  ② 卸载 → 等显存
     │                  ③ 跑目标脚本（Z画图 / 编辑 / H3 …）
     │                  ④ 关闭 ComfyUI 引擎
     │                  ⑤ 恢复聊天后端
     │                  ⑥ 结果写 .jobs\done\<id>.json
     ▼                        │
  对话不断线 ◀────────────────┘
```

## 两个脚本

| 脚本 | 谁调 | 作用 |
|---|---|---|
| `submit-job.ps1`（本地 `提交作业.ps1`）| **聊天模型** | 显存够 → 同步出图（带 `-KeepChatBackend`，不卸载）；不够 → 写队列立即返回 |
| `job-worker.ps1`（本地 `作业守护.ps1`）| 用户/开机自启 | 消费队列：快照→卸载→出图→关引擎→恢复→写结果 |

## 用法（模型侧）

```powershell
提交作业.ps1 -Task zimage -Prompt "海边灯塔，黄昏"
提交作业.ps1 -Task edit -Image x.png -Prompt "把外套换成红色"
提交作业.ps1 -Task krea2 -Prompt "..." -Extra "Lora=aoi_haru:0.9"
提交作业.ps1 -Task zimage -Prompt "..." -Wait     # 排队后等结果
提交作业.ps1 -List                                # 任务清单 + 显存需求
提交作业.ps1 -Status                              # 队列状态
```

任务 → 显存需求：`zimage` 14000 / `moss` 15000 / `t2i` 16000 / `krea2` 19000 / `pixeldit` 11000 /
`edit` 21000 / `inpaint` 14000 / `pid` 21000 / `upscale` 16000 / `h3` 22000 / `i2v` 17000（MiB）。

## 硬防护（防自杀闸门）

`_vram.ps1` 里新增：

```
Get-DshActiveModel()          → 读 DSH 默认模型（provider/model）
Test-IsDshActiveBackend($b)   → 该后端是否正在服务当前对话
```

`Start-VramPrep` 在卸载前判断：**如果目标是 DSH 当前默认模型，且 `PIPE_ALLOW_SELF_UNLOAD` 不是 `1`
→ 抛出错误拒绝执行**。守护进程自己设置该环境变量，所以只有它能合法卸载。

于是：本地模型就算误调 `Z画图.ps1`，也只会得到一条清楚的中文报错，**不会断线**。

## 实测（RTX 5090 Laptop 24 GB）

| 步骤 | 结果 |
|---|---|
| 提交时可用显存 | 0.9 GB（Strata 占着 22.5 GB）|
| 判定 | 不足 13.7 GB → 排队，**聊天模型未动** |
| 守护执行 | 卸载 Strata → Z-Image 8 步出图 → 关引擎 → 恢复 Strata |
| 总耗时 | **144.9 秒**（其中恢复 Strata 约 60 秒）|
| 成品 | `qwen-0114-zimg-20261025-170936.png` |
| 恢复校验 | 8080 回来了，8188 已关 ✅ |

## 参数兼容坑

不同脚本参数不一致（`Z画图.ps1` 没有 `-NoPause`），守护进程用 AST 解析目标脚本来**只传它支持的开关**：

```powershell
Get-ScriptParamSet $path     # 读 param 块
Add-SupportedSwitch $list $set 'NoPause'
```

## 运维

- 启动：桌面「作业守护 - 启动」；开机自启已加入启动文件夹
- 停止：桌面「作业守护 - 停止」（队列保留）
- 查看：桌面「作业状态 - 查看」
- 日志：`.jobs\守护.log`；单作业输出 `.jobs\running\<id>.log`
- 单实例：`.jobs\守护.pid`