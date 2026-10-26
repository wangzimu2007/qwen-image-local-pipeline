# 运行平台总览（v0.7.0）

> 这个仓库前身只是「一堆出图/出视频脚本」。v0.4 之后逐步长成了一个**本地 AI 运行平台**：
> 它管的不再是"怎么画一张图"，而是"多个本地模型在同一块 24 GB 显卡上，怎么互不打架地活着"。
>
> 本文件是这套平台的总入口。想快速上手看 [README](../README.md)；
> 想改脚本看 [scripts/](../scripts/) 与 [docs/](.)。

---

## 1. 解决什么问题

一台机器（Windows 11 + RTX 5090 Laptop 24 GB）上同时存在：

| 角色 | 例子 | 特点 |
|---|---|---|
| **chat 后端**（DSH 直连的 LLM）| Strata（8080）、Ollama（11434）、NInfer（8090）| 常驻、体积大（19~21 GB 显存）、会随对话自动重载 |
| **media 引擎**（出图/出视频/音频）| ComfyUI（8188）、sd.cpp（1234）、音频工具 | 按需启动、用完即关 |
| 常驻小工具 | 截图热键、窗口归位、音箱屏黑屏、状态托盘 | 21 MB 级，长期保留 |

它们都想用同一块显存。平台要保证三件事：

1. **不互相抢显存**：出图前把 chat 后端卸掉，出完再装回来
2. **不互相打断**：谁在卸载/恢复，其他组件必须让路
3. **不擅自启动**：模型只在"人点了启动"或"作业批末恢复"时才会被拉起来

---

## 2. 四层结构

```
┌──────────────────────────────────────────────────────┐
│ 运维层  状态页 · 托盘 · 崩溃自愈 · 崩溃记录 · 电源记录   │
├──────────────────────────────────────────────────────┤
│ 守护层  思考代理(8081) · watchdog · 作业守护(单实例)     │
├──────────────────────────────────────────────────────┤
│ 作业层  提交作业.ps1 → .jobs/{pending,running,done}     │
├──────────────────────────────────────────────────────┤
│ 模型层  backends.json（chat/media 注册表 + 启停方式）   │
└──────────────────────────────────────────────────────┘
```

### 模型层 — `backends.json`

配置驱动，每条后端声明：`kind / display / role / port / api / 启动方式 / 停止方式 / 进程名`。

- `role=chat`  → 走完整保活逻辑
- `role=media` → 只做按需启停 + 状态显示，**永不保活**
- 新增后端只需一条命令：`接入新后端.ps1`（自动写配置 + 建快捷方式）

### 作业层 — 队列

`提交作业.ps1` 判断显存：

- 够 → 同步执行（不卸载聊天模型，对话不中断）
- 不够 → 写 `.jobs/pending/` 交给守护

守护每轮先看队列，**一次卸载跑完整批**（4 秒收集窗口合并同时到达的作业），批末统一恢复。
支持一次提交多张：`-Count 3 -Seeds "11,22,33"`，3 张只卸载/恢复一次（实测省约 120 秒）。

### 守护层 — 三件套

| 组件 | 端口/形态 | 职责 |
|---|---|---|
| 思考代理 | 8081（pythonw，无窗口）| 给 Strata 请求补 `enable_thinking=false`，避免"一直在思考" |
| watchdog | 常驻进程 | 守护常驻小工具、提供两个 Keeper（后端/Strata）|
| 作业守护 | 常驻进程（文件独占锁单实例）| 卸载 → 跑批 → 恢复 → 写结果 |

三者都通过 **WMI** 拉起（父进程 `WmiPrvSE.exe`），脱离 DSH 进程树，DSH 重启不会带走。

### 运维层

| 工具 | 作用 |
|---|---|
| `看状态.ps1` / 托盘 | 一屏看 就绪/出图中/恢复中/启动中/离线·已手动停止 |
| `崩溃自愈.ps1`（开机自启）| 清残锁 → 续跑被中断作业 → 拉起守护 |
| `崩溃记录.ps1` | 汇总蓝屏时间 + 错误码 + 含义 + dump |
| `电源记录.ps1` | 每 30 秒记录电源计划/GPU 功耗上限/温度，用于对照崩溃 |
| `显存体检.ps1` | 谁占着显存、够不够、可强制释放 |

---

## 3. 五条硬规则（代码级强制，不是文档约定）

| # | 规则 | 强制位置 |
|---|---|---|
| 1 | **LLM 后端只允许 manual / restore 两种来源启动** | `lib/backend.ps1` 白名单 + `lib/vram.ps1` + `lib/win-watchdog.ps1`（只认 `by=guardian`）+ `job-worker.ps1` |
| 2 | **手动停止要一直停着**：`user-stop-<kind>.flag`，12 小时有效；启动快捷方式才清除 | 启停脚本 + Keeper + 守护批末 |
| 3 | **chat 与 media 分开**：media 引擎不保活、不写停止标记 | `backends.json` role + `Get-LocalBackends -Role` |
| 4 | **恢复要有内存/显存闸**：物理 < 6 GB 等 30 秒仍不足则跳过；显存 < 3 GB 跳过 | `job-worker.ps1` 批末 |
| 5 | **脚本托管模式**：守护调子脚本时设 `PIPE_GUARDIAN_MANAGED=1`，子脚本不再自己快照/恢复 | `lib/vram.ps1` 短路 |

> 教训：同一功能有两套实现（新/旧 Keeper）时，只改一套等于没改。加规则要 `grep` 全项目。

---

## 4. 一次出图的数据流

```
用户/模型: 提交作业.ps1 -Task zimage -Prompt "..."
   │  显存不足 → 写 .jobs/pending/<id>.json
   ▼
作业守护（4 秒收集窗口）
   ├─ 写 guardian.lock（告诉 Keeper 别插手）
   ├─ Start-VramPrep：快照 chat 后端 → 卸载（Strata 22 s / Ollama 9 s）
   ├─ 每个作业前复查显存（被自动重载就再卸一次）
   ├─ 逐个跑脚本（PIPE_GUARDIAN_MANAGED=1，脚本只出图）
   ├─ 关 ComfyUI 引擎
   ├─ 内存/显存闸逐个体检 → Restore-VramPrep（默认 5~10 s，实测模型真加载 20.6 GB）
   ├─ 写 wanted 记录（by=guardian）
   └─ 删 guardian.lock，写 .jobs/done/<id>.json
   ▼
Keeper（仅在 wanted 记录 by=guardian + 15 分钟窗口 + 无作业 + 无手动停止标记时）
   └─ 兜底把后端拉回来（180 秒冷却，正在加载则跳过）
```

状态页会按顺序判断：队列非空 → **出图中**；`guardian.lock` → **恢复中**；端口通 + 模型应答 → **就绪**；
进程在但没应答 → **启动中**；都不满足 → **离线**（若手动停止则标注"不会自动拉回"）。

---

## 5. 目录与文件对照

本地实际目录 `D:\qwen-image-2.1\`，仓库里做了英文名映射（便于跨平台阅读）：

| 本地 | 仓库 |
|---|---|
| `提交作业.ps1` / `作业守护.ps1` | `scripts/submit-job.ps1` / `job-worker.ps1` |
| `_backend.ps1` / `_vram.ps1` / `看状态.ps1` | `scripts/lib/backend.ps1` / `lib/vram.ps1` / `status.ps1` |
| `后端启停.ps1` / `接入新后端.ps1` / `backends.json` | `scripts/backend-startstop.ps1` / `onboard-backend.ps1` / `backends.sample.json` |
| `停Strata.ps1` / `启Strata.ps1` | `scripts/stop-strata.ps1` / `start-strata.ps1` |
| `崩溃自愈.ps1` / `崩溃记录.ps1` / `电源记录.ps1` | `scripts/crash-recovery.ps1` / `crash-history.ps1` / `power-monitor.ps1` |
| `启动守护.ps1` / `会话-开始.ps1` / `会话-结束.ps1` | `scripts/start-daemons.ps1` / `session-start.ps1` / `session-end.ps1` |
| `think-off-proxy.py` | `scripts/think-off-proxy.py` |
| `D:\tools\win-layout\watchdog.ps1` | `scripts/lib/win-watchdog.ps1`（另在 `tools/` 有一份）|
| `StrataTray.cs`、黑屏/截图/窗口工具源码 | `tools/*.cs` |

出图/出视频脚本按功能映射到 `scripts/t2i-*.ps1`、`edit.ps1`、`i2v.ps1`、`ai-upscale*.ps1` 等。

---

## 6. 换机器 / 重装后的恢复步骤

1. 装好 ComfyUI、模型、Python 依赖（见 [07-local-setup.md](07-local-setup.md)）
2. 把 `scripts/` 放回工具目录，按需改 `config.sample.ps1` → `config.ps1`
3. 复制 `backends.sample.json` → `backends.json`，按实际端口/路径修正
4. 以管理员/普通用户运行一次 `scripts/start-daemons.ps1`（拉起思考代理 / watchdog / 作业守护）
5. 开机自启：把 `start-daemons.ps1`、`crash-recovery.ps1`、状态托盘放进启动文件夹
6. 自检：`status.ps1` 应显示后端列表；`power-monitor.ps1 -Once` 能采一行数据

---

## 7. 排障速查

| 现象 | 先查 |
|---|---|
| 本地模型会话断线 `TRANSPORT` | 8081 代理在不在 → 8080 在不在 → `看状态.ps1` |
| 出图失败 0 秒 | `.jobs/done/<id>.json` 的 `error`；多半是参数错误（提交前会 AST 校验）|
| 卡在"恢复中" | `.jobs/guardian.lock` 是否残留（守护崩了才会留）|
| 模型自己起来了 | `watchdog.log` 是否有"拉回"；检查 `user-stop-*.flag` 与 `by=guardian` |
| 蓝屏/重启 | `崩溃记录.ps1 -Days 30`；`电源记录.csv` 看崩溃前电源模式是否切换 |
| 内存吃紧/卡顿 | 日志里的"保护闸"行；`显存体检.ps1` |

---

## 8. 版本与文档索引

| 文档 | 内容 |
|---|---|
| [docs/10-job-queue.md](10-job-queue.md) | 作业队列与批量提交 |
| [docs/11-think-off-proxy.md](11-think-off-proxy.md) | 关思考代理 |
| [docs/12-multi-backend.md](12-multi-backend.md) | 多后端、手动停止、autostart 策略 |
| [docs/13-onboarding-backends.md](13-onboarding-backends.md) | 新模型接入清单 |
| [docs/14-crash-prevention.md](14-crash-prevention.md) | 防崩溃与自愈 |
| [CHANGELOG.md](../CHANGELOG.md) | 版本历史 |
