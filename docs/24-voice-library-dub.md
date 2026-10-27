# 用声音库克隆角色给视频配音（2026-10-27）

## 结论

**现在可以直接用提示词给无音频/无人声的视频配音，并指定克隆的游戏角色音色。**

```powershell
视频配音提示词.ps1 -Video 视频.mp4 -Prompt "用阮梅的声音，清冷平静地念一句湖景旁白" -Voice 阮梅 -Mode auto -BurnSubtitles
```

- 视频没有音轨 → 正常加上旁白音轨
- 视频有背景音乐但没人声 → 加 `-KeepOriginal`，原声压到 25% 与旁白混合
- 指定 `-Voice 阮梅` → 从声音库 `C:\音频素材\voices.json` 解析参考音，用 **F5 克隆**（不是之前的 Chatterbox）

## 链路

```
提示词 → qwen3-vl 抽帧理解 → qwen3.5:9b 写旁白/配音提示词
      → 声音库按角色名找参考音（voices.json）
      → F5 零样本克隆 TTS（失败回退 Chatterbox）
      → 音调/共振峰/音色处理 → 时长适配（≤1.8×）
      → 字幕对齐（可烧录）→ 封装（可选保留原声 25% 混音）
```

## 声音库

`C:\音频素材\voices.json`，每条 profile：

| 字段 | 说明 |
|---|---|
| `id` | 唯一 ID，如 `hsr-ruanmei` |
| `game` / `character` | 游戏、角色名 |
| `aliases` | 别名（阮·梅、Ruan Mei、ruanmei…），`-Voice` 可模糊匹配 |
| `reference` | 参考音频路径（建议 3~10 秒人声） |
| `tags` | 女声/清冷/学者… |

当前已登记：**崩坏星穹铁道 / 阮梅**（参考音 5.73 秒 48kHz）。
新增角色：把参考音频放 `C:\音频素材\<游戏>\<角色>\`，并在 `voices.json` 加一条 profile 即可。

## 实测

| 用例 | 结果 |
|---|---|
| 无声视频 + `-Voice 阮梅` + 烧字幕 | 72.6 秒，成片 `video-0074`，F5 克隆，video+audio 双流，4.04 秒 |
| 只有音乐的视频 + `-Voice 阮梅` + `-KeepOriginal` | 187.9 秒，成片 `video-0078`，原声 25% 混入，4.04 秒 |
| `_mux_video(keep_original=True)` 单测 | 退出码 0，音频混合正常 |

## 本次修复

| 问题 | 修法 |
|---|---|
| 视频配音入口没有声音库参数 | 新增 `-Voice 角色`，自动解析参考音 |
| 传参考音时默认走 Chatterbox | auto + 参考音改为 **F5 克隆**，失败才回退 Chatterbox |
| 无法保留原视频背景音 | 新增 `-KeepOriginal`（原声 25% + 旁白混合） |
| F5 环境被 AudioSep 装坏 | f5-venv 里 torchvision 与 torch 2.11 不匹配 → 安装 `torchvision==0.26.0`；F5 恢复正常 |
| 队列任务不便传开关 | `提交作业 -Task videodub -Extra "Voice=阮梅;KeepOriginal"` 可透传 |

## 用法

```powershell
# 无声视频 + 角色音色
视频配音提示词.ps1 -Video x.mp4 -Prompt "用阮梅的声音念一段湖景旁白" -Voice 阮梅 -Mode auto -BurnSubtitles

# 有背景音乐、想保留
视频配音提示词.ps1 -Video x.mp4 -Prompt "..." -Voice 阮梅 -KeepOriginal

# 显式选引擎（f5 / chatterbox / qwen-fast / kokoro / cosyvoice）
视频配音提示词.ps1 -Video x.mp4 -Prompt "..." -Voice 阮梅 -Engine f5

# 本地模型会话走队列（自动继续）
提交作业.ps1 -Task videodub -Video x.mp4 -Prompt "..." -Extra "Voice=阮梅;KeepOriginal" -Wait
```

## 注意

- F5 首次加载约 20 秒，之后单次 RTF 明显更低；参考音 48kHz 也能直接读
- 旁白长度按视频时长自动裁剪；4 秒短片旁白可能偏短（留白），长片更自然
- 声音库参考音质量决定克隆效果，建议用干净、无背景音乐的单人片段
- 声音库 GUI 的“生成”仍走 CosyVoice2 零样本；视频配音已优先 F5，效果更好
