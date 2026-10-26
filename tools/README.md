# Win-Layout 工具（Windows 小工具集，C# 源码备份）

这些是本地长期常驻的 Windows 小工具，源码保存在这里作为备份/可重建依据。
它们**不参与** AI 推理，占用合计约 21 MB。

## 工具清单

| 源码 | 产物 | 作用 | 怎么用 |
|---|---|---|---|
| `StrataTray.cs` | `StrataTray.exe` | 托盘显示本地模型状态（绿/蓝/橙/黄/红），双击看详情 | 开机自启；状态来自 `看状态.ps1 -Json` |
| `BlackOverlay.cs` | `BlackOverlay.exe` | **主屏纯黑遮罩**（OLED 防烧屏）| 运行后全屏变黑；`Esc` 或 `Ctrl+Alt+B` 退出 |
| `BlackDisplay.cs` | `BlackDisplay.exe` | 在 800×600 副屏（回音壁/采集卡）上盖纯黑窗口 | 常驻 |
| `BlackHotkey.cs` | `BlackHotkey.exe` | 黑屏热键 | 常驻 |
| `ScreenshotHotkey.cs` | `ScreenshotHotkey.exe` | `Ctrl+Alt+Ins` 截主屏 | 常驻 |
| `WindowGuard.cs` | `WindowGuard.exe` | 新窗口自动挪回主屏，不落到副屏 | 常驻 |
| `DshStripGuard.cs` | `DshStripGuard.exe` | 修正 DSH 窗口贴边行为 | 常驻 |
| `CenterBrowser.cs` | `CenterBrowser.exe` | 让浏览器窗口居中打开 | 常驻 |
| `DisplayConfigTool.cs` | `DisplayConfigTool.exe` | 读/写显示配置 | 按需 |
| `TestWindow.cs` | `TestWindow.exe` | 调试用空窗口 | 开发用 |

## 重新编译（Windows 自带 csc，Win11 可用 .NET Framework 4.x）

```powershell
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'

# 托盘（纯 WinForms）
& $csc /nologo /target:winexe /out:StrataTray.exe StrataTray.cs `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll

# 黑屏遮罩
& $csc /nologo /target:winexe /out:BlackOverlay.exe BlackOverlay.cs `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll
```

> 注意：**不要用编辑工具改这些 `.cs` 后直接编译**——若编辑器改了编码，中文注释可能变乱码。
> 源码为 UTF-8（无 BOM）即可，`csc` 默认按 UTF-8 解析。

## 与平台的配合

- `watchdog.ps1`（也在 `scripts/lib/win-watchdog.ps1`）负责"这些工具掉了就拉起来"
- 托盘状态颜色定义见主仓库 `docs/00-platform-overview.md`
- 关显示器策略见 `docs/14-crash-prevention.md`（显示器不关屏 + 空白屏保 + 本目录的 `BlackOverlay`）
