# v0.3.4 — 修图工具箱 + 显存体检 + 会话模式

## 新增脚本

| 脚本 | 作用 |
|---|---|
| `scripts/img-edit.ps1` | **确定性图片小修小改**，纯 CPU 不占显存，单张 0.1~1 秒 |
| `scripts/lib/imgops.py` | 图片 op 引擎（Pillow），20 多个 op |
| `scripts/lib/imgerase.py` | OpenCV 修补后端（`erase` 用） |
| `scripts/vram-check.ps1` | **显存体检**：谁占着、够不够、`-Kill` 一键释放 |
| `scripts/session-start.ps1` / `session-end.ps1` | **会话模式**：批量出图只换入换出一次模型 |

## 修图 op（分五类）

- 几何：`crop` `cropc` `resize` `thumb` `rotate` `flip` `radius`
- 色彩：`color` 整图 / **`boxcolor` 只调区域** / `gray` `autocontrast`
- 合成：`text` `wtext` `wimg` `border` `montage`
- 修补：`erase`（OpenCV）/ **`blurfill`（平滑区首选）** / `clone` / `heal`（实验性）
- 输出：`format` `quality` `exif`

## 显存体检的判定

按任务对照门槛（zimage 13.7 / moss 14.6 / seedvr2 14.6 / wan 15.6 / h3 20.5 / flashvsr 21.5 GB），三档结论：

- 可用 ≥ 门槛 → 正常速度
- 可用 < 门槛但 > 8 GB → **不报错但慢 5~10 倍**（驱动回退系统内存）
- 可用 < 8 GB → 先关程序

已过滤 `dwm`/`csrss` 等系统进程的虚报（WDDM 下会假报十几到二十 GB）。

## 会话模式解决什么

默认流程每张图都要"卸载聊天模型 → 出图 → 重新加载"，27B 模型一次换入换出就要 1~2 分钟。
会话模式只在开始和结束各做一次，中间每张图只需几秒。

## 实测

| 场景 | 结果 |
|---|---|
| 裁剪 + 调色 + 水印（1.05 MP） | 0.15~0.9 秒 |
| 抹除灰块（4K，blurfill） | 6.2 秒 |
| 转 webp（缩到 800） | 0.09 秒 |
| 超分两步走 832×1216 → 2160 | 46 秒，无灰块 |

## 已知限制

- `heal` 实现不稳定，优先用 `blurfill`
- LaMa ONNX 跑通但填充质量不达标，未纳入主线
- `erase` 需要带 cv2 的 Python；没有时只警告不崩