# 多后端支持：自动识别 Strata / Ollama / NInfer

## 目的

之前的作业队列、状态页、托盘、Keeper 都是**写死 Strata(8080)** 的。
本版把它们统一抽象成「本地聊天后端」，**自动识别 DSH 当前在用哪个后端 / 哪个模型**。

## 识别依据

`_backend.ps1` 读取 DSH 配置的**默认模型**：

```
%USERPROFILE%\.dsh\profiles\desktop\cordis.patch.yml
  - id: agent-default-model
    config:
      provider: strata-local | ollama-local | ninfer-local
      model:    qwen3.8-flash-next-iq3_s  …
```

provider 前缀映射到后端类型：

| provider 前缀 | 后端 | 端口 | 启动方式 |
|---|---|---|---|
| `strata*` | Strata | 8080 | `%LOCALAPPDATA%\Strata\actions\start-iq3s.cmd` |
| `ollama*` | Ollama | 11434 | `ollama app.exe` + `/api/generate` 重载模型 |
| `ninfer*` | NInfer (WSL) | 8090 | `D:\tools\ninfer\start-ninfer-server.vbs` |

**所以在 DSH 里切换模型（UI 选 Ollama / NInfer），状态页、托盘、Keeper 会自动跟着切换，无需改配置。**

## 三个组件都用同一套状态

| 状态 | 判据 |
|---|---|
| 出图中 | 队列有 running/pending |
| 恢复中 | `.jobs\guardian.lock` 存在 |
| 就绪 | **当前活动后端**的 `/v1/models`（Strata/NInfer）或 `/api/ps`（Ollama）能返回 |
| 启动中 | 端口在或进程在，但模型没答 |
| 离线 | 都不是 |

## 状态页（多后端）

```
● 就绪   （20:39:37）
strata · qwen3.8-flash-next-iq3_s

── 本地后端 ─────────────────────────
strata   :8080   ● 服务中    qwen3.8-flash-next-iq3_s  ← DSH 当前
ollama   :11434  ◐ 端口在
ninfer   :8090   ○ 离线

DSH 默认: strata-local / qwen3.8-flash-next-iq3_s
队列: 执行中 0 / 排队 0    守护锁: 无
```

## Keeper（画图结束后拉回）现在是通用的

作业守护批末写 `backends-wanted.json`：

```json
{ "at": "2026-10-25T20:38:57+08:00",
  "backends": [ { "kind": "strata", "variant": "iq3_s", "modelId": "qwen3.8-flash-next-iq3_s" } ] }
```

watchdog 的 `Invoke-BackendKeeper` 据此对**每一个被卸载的后端**调 `Start-LocalBackend`：
- strata → 起 `start-iq3s.cmd`
- ollama → 起托盘 + 按模型列表 `/api/generate` 重载
- ninfer → 起 `start-ninfer-server.vbs`

**实测**：故意停掉 Ollama，Keeper 在 **3 秒**内拉起（日志 `拉回本地后端 ollama（: 11434）`）。

## 实测（一次完整队列作业）

| 阶段 | 耗时 |
|---|---|
| 卸载 | 27.1 秒（显存 1.0 → 21.9 GB 可用）|
| 出图（zimage）| 74.5 秒 |
| 恢复 | 59.6 秒 |
| **整批** | **167.6 秒** |

状态页/托盘同步显示：`出图中 → 恢复中 → 就绪`。

## 局限

- **出图任务只走 ComfyUI**（与聊天后端无关）；本抽象解决的是"谁被卸载/恢复/显示状态"
- Ollama 的 `enable_thinking` 代理（8081）只对 Strata 生效；Ollama 如需关思考要另配
- 多后端同时在线时，Keeper 只恢复"被作业卸载过"的那些（记在 wanted 文件里）
## 踩坑：Keeper 30 秒周期 < 启动时间（v0.6.5 修复）

**现象**：托盘黄红横跳，Strata 永远起不来。

**根因**：本地模型自己停掉 Strata → Keeper 每 30 秒拉起 → `start-iq3s.cmd` 开头 `launch --stop`
杀掉正在加载的实例（启动要 40~90 秒）→ 循环。

**修法**：
1. Keeper 加 **180 秒冷却**（`keeper-last-start-<kind>.txt`）
2. 进程已在（正在加载）→ 跳过
3. 端口探测改 `TcpClient`：状态脚本 **6.81s → 0.95s**

**验证**：停 Strata → 第一次 -Once 拉回 + 写冷却 → 6 秒后第二次 -Once 正确跳过 → Strata 30 秒就绪。

**规则**：本地模型会话**禁止停止自己的后端**（Stop Strata / 会话-开始 / watchdog -Once），
要重启只能让用户点「Strata IQ3_S - 启动」。
## 手动停止要一直停着（v0.6.7）

从快捷方式手动停掉 Strata 后，Keeper 以前会 15 分钟内又拉回来。现在加了用户意图标记：

- `scripts/stop-strata.ps1`：写 `.jobs\user-stop.flag` → 停 Strata → 清 wanted 记录
- `scripts/start-strata.ps1`：**清标记** → 启动（已在加载则不重复启动，避免 `launch --stop` 杀掉加载中的实例）
- Keeper（`backend.ps1`/watchdog）与守护批末恢复都会**尊重标记**（12 小时有效，防遗忘）
- 状态页/托盘显示：`离线 · 已手动停止（不会自动拉回）`

实测：停 → 造 wanted 记录 → `watchdog -Once` → **不拉回**；点启动 → 15 秒就绪。

桌面快捷方式「Strata IQ3_S/NVFP4 - 启动/停止」已改为指向这两个包装脚本。
## 手动停止：按后端独立（v0.6.8）

标记文件：`.jobs\user-stop-<kind>.flag`（strata / ollama / ninfer），也兼容旧全局 `user-stop.flag`。

| 后端 | 停止 | 启动 | 快捷方式 |
|---|---|---|---|
| Strata | 写标记 → `stop-iq3s.cmd` | 清标记 → `start-iq3s.cmd`（已在加载则不重复） | 「Strata IQ3_S/NVFP4 - 启动/停止」|
| Ollama | 写标记 → 结束 `ollama app`/`ollama` | 清标记 → `ollama app.exe` | 「Ollama - 启动/停止」|
| NInfer | 写标记 → `stop-ninfer-server.ps1` | 清标记 → `start-ninfer-server.vbs` | 「NInfer - 启动/停止」|

Keeper（watchdog）与守护批末恢复都**按 kind 判断**：只跳过用户停掉的那个后端，其他后端照常恢复。

实测（Ollama）：启动 → 就绪 3 秒；停止 → 标记写入；造 wanted 记录后 `watchdog -Once` → **不拉回**。

## 修复：手动停止仍被拉起（v0.6.11）

现象：手动停 Strata 后 1 小时它又起来了，watchdog.log 每 30 秒一条"拉回 Strata"。

根因：`watchdog.ps1` 里有两个 Keeper，新版 `Invoke-BackendKeeper` 检查
`user-stop-<kind>.flag`，**旧版 `Invoke-StrataKeeper` 不检查**，且没有冷却。
只要 `strata-wanted.json` 存在、8080 没在听，就会每 30 秒跑一次 `start-iq3s.cmd`；
而该脚本开头是 `launch --stop`，每次都把正在加载的实例杀掉，循环到某次碰巧加载成功。

修法：

1. `Invoke-StrataKeeper` 加三道闸：手动停止标记 / strata 进程已存在 / 180 秒冷却（`keeper-last-start-strata.txt`）
2. `job-worker.ps1` 只在真的恢复过 strata 时才写 `strata-wanted.json`

验证：停后观察 110 秒无拉起；伪造 wanted 文件跑 `watchdog -Once` 仍不拉起。

## 自动启动策略（v0.6.12）

LLM 本地后端只允许两种来源启动：**manual**（用户手动）与 **restore**（作业批末恢复）。
其他来源（Keeper 心跳、自愈脚本、未知 wanted 记录）一律拒绝。

四层强制：

| 层 | 做法 |
|---|---|
| `lib/backend.ps1` | `Start-LocalBackend -Reason ...` 白名单；`Test-AutoStartAllowed` |
| `lib/vram.ps1` | 恢复路径 `Assert-AutoStartAllowed -Reason 'restore'` |
| `lib/win-watchdog.ps1` | Keeper 只认 `wanted.json` 的 `by='guardian'`，并走 `-Reason 'restore'` |
| `job-worker.ps1` | 写 wanted 时带 `by='guardian'`，只写真实恢复过的后端 |

新接入后端默认 `autoStart=false`，自动继承策略。

## 测试期间/之后的本地模型处理（v0.7.2，漏洞审计）

**场景**：云端会话跑测试时清掉本地聊天模型腾显存。要求测试期间不提前拉回、测试结束必拉回。

### 让路闸（防提前拉回）

`win-watchdog.ps1` 的两个 Keeper 增加三道闸：

- `Test-MediaBusy`：ComfyUI / main.py / ffmpeg / 音频相关进程在跑 → 让路
- `Test-GpuHold`：`.jobs/gpu-hold.json` 存在且持有进程存活 → 让路
- `GPU 已用 > 4500 MiB` → 让路

`lib/vram.ps1` 的 `Start-VramPrep` 在卸载前写 `gpu-hold.json`，`Restore-VramPrep` 恢复后清除。

### 空闲恢复（防"不拉回"）

`Invoke-IdleRestoreKeeper` 全部满足才动作：

- 无排队/执行作业、无 `guardian.lock`
- 无媒体任务、无 gpu-hold、无 `.jobs\no-auto-restore.flag`
- GPU < 1.2 GB，**且连续 10 次检查（5 分钟）**
- 最近 15 分钟没有新启动的 python/ffmpeg
- 最近 10 分钟输出目录（视频/ComfyUI 输出/Qwen 图片/audio-tools）无写入

动作：DSH 默认模型是本地 chat 且未在服务时 → 有遗留快照按快照恢复，否则拉起后端并加载目标模型；冷却 15 分钟。

### 手动控制

```powershell
恢复本地模型.ps1 -Status    # 看状态
恢复本地模型.ps1 -Pause     # 长时间测试时暂停自动恢复
恢复本地模型.ps1 -Resume    # 恢复
恢复本地模型.ps1 -Force     # 立刻拉回
```