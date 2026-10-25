# 新模型接入标准动作（Onboarding）

> 以后**每加一个新本地模型**，都走这套流程，保证它自动获得：启停快捷方式、手动停止保护、
> 状态页/托盘显示、Keeper 自动拉回、作业队列兼容。

## 一条命令接入

```powershell
D:\qwen-image-2.1\接入新后端.ps1 -Kind <kind> -Display "<显示名>" -Port <端口> [启动/停止方式]
```

### 三种启动/停止方式（按后端类型选）

| 后端类型 | 参数 | 例子 |
|---|---|---|
| **命令行型**（有 start/stop cmd）| `-StartCmd`、`-StopCmd` | Strata：`start-iq3s.cmd` / `stop-iq3s.cmd` |
| **可执行程序型**（托盘 exe）| `-StartExe`、`-StopProcs "a","b"` | Ollama：`ollama app.exe` |
| **VBS / PS1 型** | `-StartVbs`、`-StopPs` | NInfer：`start-ninfer-server.vbs` / `stop-ninfer-server.ps1` |

可选参数：

| 参数 | 作用 |
|---|---|
| `-Api openai\|ollama` | 探测模型列表用 `/v1/models` 还是 `/api/ps` |
| `-Procs "name1","name2"` | 判断"是否正在加载"的进程名（防止重复启动）|
| `-Note "..."` | 备注，写进配置 |
| `-Disabled` | 先登记但不在状态页显示 |
| `-NoShortcut` | 不建桌面快捷方式 |
| `-Force` | 覆盖同名 kind |

## 脚本自动做的事

1. 往 `backends.json` 追加/更新一条定义
2. 建桌面快捷方式「`<Display> - 启动`」和「`<Display> - 停止`」
3. 打印验证命令

## 之后自动生效的能力（无需改代码）

| 能力 | 机制 |
|---|---|
| **状态页 / 托盘** | `Get-LocalBackends` 读 `backends.json`，自动列一行并给出 就绪/启动中/离线/已手动停止 |
| **手动停止保护** | `后端启停.ps1 -Action stop` 写 `user-stop-<kind>.flag`（12 小时有效）|
| **Keeper 尊重手动停止** | watchdog 按 kind 检查标记，停过的绝不自动拉回 |
| **作业后自动拉回** | 守护批末按 kind 过滤：只恢复"没被手动停"的后端 |
| **作业队列** | `提交作业.ps1` 的卸载/恢复走 `_vram.ps1`（本身支持 strata/ollama/ninfer）|

## 接入后的验证清单

```powershell
# 1) 能看到它
D:\qwen-image-2.1\看状态.ps1

# 2) 启停正常
D:\qwen-image-2.1\后端启停.ps1 -Kind <kind> -Action start -Wait
D:\qwen-image-2.1\后端启停.ps1 -Kind <kind> -Action stop

# 3) 手动停止后不会被拉起
#    stop 之后造 wanted 记录，跑一次 watchdog -Once，看日志里没有"拉回"
```

## 实际配置示例（backends.json）

```json
{
  "kind": "lmstudio",
  "display": "LM Studio",
  "port": 1234,
  "api": "openai",
  "enabled": true,
  "startCmd": "C:\\LM Studio\\start.cmd",
  "stopCmd": "C:\\LM Studio\\stop.cmd",
  "startExe": "", "startVbs": "", "stopPs": "",
  "stopProcs": [],
  "procs": ["LM Studio"],
  "note": "示例"
}
```

## 如果要让 DSH 真正用它

1. DSH 设置 → 模型 → 新增 provider：`api: openai-completions`，`baseURL: http://127.0.0.1:<端口>/v1`
2. 把默认模型切到它 → 状态页/托盘会把它标成「← DSH 当前」
3. 想关思考：参照 `think-off-proxy.py` 起一个代理端口，把 baseURL 指向代理

## 当前已接入

| kind | 端口 | 显示 | 启动 | 停止 |
|---|---|---|---|---|
| `strata` | 8080 | Strata | `start-iq3s.cmd` | `stop-iq3s.cmd` |
| `ollama` | 11434 | Ollama | `ollama app.exe` | 结束 `ollama app`/`ollama` |
| `ninfer` | 8090 | NInfer (WSL) | `start-ninfer-server.vbs` | `stop-ninfer-server.ps1` |
