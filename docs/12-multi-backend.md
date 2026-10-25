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