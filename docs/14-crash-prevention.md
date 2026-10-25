# 防崩溃与崩溃自愈

## 现象与归因

2026-10-25 22:58:42 系统蓝屏重启（`0x19C WIN32K_POWER_WATCHDOG_TIMEOUT`），
重启后 DSH 与所有 WMI 守护进程自动恢复。

近 30 天崩溃记录：

| 时间 | 错误码 | 含义 |
|---|---|---|
| 2026-10-12 21:00 | `0x116` | VIDEO_TDR_FAILURE（显卡驱动超时）|
| 2026-10-23 22:21 | `0x20001` | HYPERVISOR_ERROR（虚拟化层）|
| 2026-10-25 22:58 | `0x19C` | WIN32K_POWER_WATCHDOG_TIMEOUT（显卡/电源转换卡死）|

三类问题都属于**显卡驱动 / 虚拟化 / 电源转换**，与出图流水线无直接关系。
其中 `0x19C` 的触发点最可能是「显示器自动关闭」：显示器超时 300 秒，崩溃发生在最后一次操作 5 分钟后。

## 系统层措施

| 项 | 值 | 状态 |
|---|---|---|
| 关显示器超时 | 从不 | 已应用 |
| 睡眠超时 | 从不 | 已应用 |
| PCIe 链接电源管理 | 关闭 | 已应用 |
| 快速启动 HiberbootEnabled | 0 | **需管理员** |
| NVIDIA 驱动 32.0.16.2101 | 待更新/回滚 | **需人工** |

## 流水线层：崩溃自愈

`scripts/crash-recovery.ps1`（开机自启）

1. **清理遗留锁**：`guardian.lock`、`守护.pid`、`守护.instance.lock`、`watchdog.pid`、
   `keeper-last-start-*.txt`；其中 PID 文件若对应进程仍存活则跳过
2. **续跑被中断作业**：`running/*.json` → 重新入队（`attempt` 计数，超过 2 次标失败）
3. **拉起守护**：幂等调用 `start-daemons.ps1`（思考代理 / watchdog / 作业守护）
4. **写记录**：`.jobs\崩溃自愈.log`

另有 `scripts/crash-history.ps1`：汇总崩溃事件与错误码，支持 `-Days N` 与 `-Json`。

## 使用

```powershell
# 自动：开机自启，无需干预
# 手动检查：
D:\qwen-image-2.1\崩溃记录.ps1 -Days 30
D:\qwen-image-2.1\崩溃自愈.ps1 -DryRun    # 演练
D:\qwen-image-2.1\崩溃自愈.ps1            # 执行
```

## 注意

- 崩溃瞬间正在执行的作业会丢失；**批量出图后等队列归零再离开**更稳
- 崩溃后不要手动删锁文件，交给 `崩溃自愈.ps1`（它有存活判断）