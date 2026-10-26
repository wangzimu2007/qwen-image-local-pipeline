# 新脚本接入显存快照 —— 模板与避坑

> 适用：任何"会启动本地模型 / ComfyUI"的新 PowerShell 脚本。
> 目标：让脚本在生成前**快照**正在服务的 Strata / Ollama，生成后**自动恢复**，并与其他脚本共享同一套状态文件，避免互相覆盖。

---

## 一、核心只有 4 行（贴在任何需要显存的地方之前）

```powershell
. (Join-Path $PSScriptRoot '_vram.ps1')
$vramState = $null
trap { try { Restore-VramPrep $vramState } catch { }; exit 1 }
if (-not $KeepChatBackend) { $vramState = Start-VramPrep -NeedMiB 16000 -TimeoutSeconds 180 }
```

参数里加一个开关：

```powershell
[switch]$KeepChatBackend
```

收尾处加一行（必须位于**所有**可能退出之前，且不能在 if 单行里）：

```powershell
Restore-VramPrep $vramState
```

---

## 二、完整样板（三种引擎）

### A. 用秋叶版 ComfyUI（8189，跑 H3 / Wan / FILM / FlashVSR）

```powershell
# ---- 1. 快照（必须在启动引擎之前）----
. (Join-Path $PSScriptRoot '_vram.ps1')
$vramState = $null
trap { try { Restore-VramPrep $vramState } catch { }; exit 1 }
if (-not $KeepChatBackend) { $vramState = Start-VramPrep -NeedMiB 16000 -TimeoutSeconds 180 }

# ---- 2. 启动引擎：让秋叶脚本不要自己快照 ----
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $akiRoot 'start-aki.ps1') `
    -KeepChatBackend -NoPause -NoBrowser

# ---- 3. ... 生成 ...

# ---- 4. 停引擎：让秋叶脚本不要自己恢复（恢复交给 _vram）----
if ($startedHere -and -not $KeepServer) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $akiRoot 'stop-aki.ps1') `
        -NoRestore -NoPause
}

# ---- 5. 恢复（顶层，独立一行，放在最后退出的前面）----
Restore-VramPrep $vramState
exit 0
```

### B. 用桌面版 ComfyUI（8188，跑 Z-Image）

```powershell
. (Join-Path $PSScriptRoot '_vram.ps1')
$vramState = $null
trap { try { Restore-VramPrep $vramState } catch { }; exit 1 }
if (-not $KeepChatBackend) { $vramState = Start-VramPrep -NeedMiB 12000 -TimeoutSeconds 150 }

# 引擎身份判断（避免 8188 上跑的是自建版）
function Get-EngineKind {
    try {
        $r = Invoke-RestMethod 'http://127.0.0.1:8188/object_info/UNETLoader' -TimeoutSec 8
        $list = $r.UNETLoader.input.required.unet_name[0]
        if (@($list | Where-Object { $_ -match 'moss_image' }).Count -gt 0) { return 'selfbuilt' }
        if (@($list | Where-Object { $_ -match 'z_image' }).Count -gt 0) { return 'desktop' }
        return 'unknown'
    } catch { return 'unknown' }
}
# ... 启动/切换引擎逻辑见 Z画图.ps1 ...

# 退出前一定恢复
Restore-VramPrep $vramState
exit 0
```

### C. 纯 CPU 脚本（拼接 / 裁剪 / Lanczos）

**不需要接入** —— 不占显存。只有调用 FILM 插帧、SeedVR2、FlashVSR 这类才需要。

---

## 三、必踩的三个坑

### 坑 1：把参数塞进 `Join-Path` 里

```powershell
# ✗ 错：会拼出 "...\start-aki.ps1\-KeepChatBackend\-NoBrowser" 这种非法路径
-File (Join-Path $akiRoot 'start-aki.ps1','-KeepChatBackend','-NoBrowser')

# ✓ 对：参数放在括号外面
-File (Join-Path $akiRoot 'start-aki.ps1') -KeepChatBackend -NoBrowser
```

### 坑 2：恢复插在单行 if 里 → 永远不执行

```powershell
# ✗ 错：这种结尾用多行正则会漏，恢复被插不进去
if ($status -eq 'ok') { exit 0 }

# ✓ 对：恢复必须是顶层独立一行，放在 Pause-Brief 之前
Restore-VramPrep $vramState
if ($status -eq 'ok') { exit 0 }
exit 1
```

> 教训：改完一定要**跑一次真实测试**并检查「快照文件是否残留」。只看"文件里有 Restore-VramPrep"不算数。

### 坑 3：两套快照同时生效

秋叶的 `start-aki.ps1` 自己就带快照（状态文件在 `D:\ComfyUI-aki-v3.2\.chat-backend-state.json`）。
如果新脚本再用 `_vram.ps1`（状态文件在 `D:\qwen-image-2.1\.chat-backend-state.json`），两套会互相覆盖。

**必须**给秋叶脚本加 `-KeepChatBackend`（启动时）和 `-NoRestore`（停止时），让 `_vram.ps1` 独占。

---

## 四、验收清单（每条都要过）

1. `[System.Management.Automation.Language.Parser]::ParseFile` 语法 0 错误
2. 文件是 **UTF-8 带 BOM**（PowerShell 5.1 中文必需）
3. 先 `ollama run qwen3.5:9b` 之类让本地模型加载，再跑新脚本，确认日志出现：
   - `检测到 Ollama 已加载模型（...），先卸载腾显存。`
   - 结束时 `已重新加载 Ollama 模型：...`
4. 结束后检查：
   - `D:\qwen-image-2.1\.chat-backend-state.json` **不存在**
   - `D:\ComfyUI-aki-v3.2\.chat-backend-state.json` **不存在**
   - `/api/ps` 里模型**回来了**
5. 加 `-KeepChatBackend` 再跑一次，确认**没有**卸载动作（说明开关有效）

---

## 五、`_vram.ps1` 提供的函数

| 函数 | 作用 |
|---|---|
| `Get-ChatBackends` | 探测 Strata（8080，按模型 id 判变体）与 Ollama（11434 `/api/ps`） |
| `Start-VramPrep -NeedMiB -TimeoutSeconds` | 快照 + 停止/卸载 + **自适应等待**显存 |
| `Wait-VramFree -NeedMiB -TimeoutSeconds` | 只等待，不停止任何东西 |
| `Restore-VramPrep $state` | 恢复（Strata 等最多 420 秒；Ollama 用 `keep_alive 30m`）+ 清理状态文件 |
| `Get-FreeVramMiB` | 读当前可用显存（MiB） |

**自适应等待规则**：达到阈值立即继续；连续 9 秒不再增长且 ≥9 GB 也继续；<8 GB 才告警。
（原因：浏览器/系统常年占 15 GB，死等阈值会白等 150 秒）

---

## 六、当前已接入的脚本

| 脚本 | 引擎 | 快照来源 |
|---|---|---|
| `Z画图.ps1` | 桌面版 8188 | `_vram.ps1` |
| `MOSS画图.ps1` | 自建版 8188 | `_vram.ps1` |
| `文本生视频H3快照.ps1` | 秋叶 8189 | `_vram.ps1` |
| `图生视频.ps1` | 秋叶 8189 | `_vram.ps1` |
| `续接视频.ps1` | 秋叶 8189 | `_vram.ps1` |
| `后期处理.ps1`（插帧） | 秋叶 8189 | `_vram.ps1` |
| `AI超分FlashVSR.ps1` | 秋叶 8189 | `_vram.ps1` |
| `画图.ps1` / `改图.ps1` / `编辑.ps1` / `start-imggen.ps1` | sd.cpp / 自建 | 各自内置 |
| `文本生视频H3.ps1`（旧版） | 秋叶 8189 | 秋叶脚本隐式 |

---

## 七、实测参考耗时（Ollama 装 9B 时）

| 场景 | 耗时构成 |
|---|---|
| Z-Image 832×1216 | 卸载 ~5 秒 + 生成 4 秒 + 恢复 4~120 秒（模型是否还在系统缓存） |
| 图生视频 2 秒 | 卸载 ~5 秒 + 引擎 60 秒 + 生成 45 秒 + 停止 ~5 秒 + 恢复 |
| H3 512×512/4 秒 | 卸载 ~5 秒 + 引擎 63 秒 + 生成 64 秒 + 恢复 |

> 恢复是**阻塞**的：9B 约 1~2 分钟、27B 更久。赶时间就加 `-KeepChatBackend`（确认显存够时）。
