# Skills —— 给 AI 助手用的指令包

这些是 **DSH（DeepSeek Harness）/ 兼容 skills 的 Agent** 用的技能文件。
每个目录一个 `SKILL.md`，带 YAML frontmatter（`name` / `description`），
模型根据 `description` 自动判断何时加载。

## 用法

把需要的目录复制到你的技能目录：

```powershell
# DSH
Copy-Item skills\text-to-image "$env:USERPROFILE\.dsh\skills\text-to-image" -Recurse

# 兼容 ~/.agents/skills 的其它 Agent
Copy-Item skills\video-upscale "$env:USERPROFILE\.agents\skills\video-upscale" -Recurse
```

写入后通常**无需重启**，技能目录会被重新扫描（DSH 实测生效）。

## 重要：这些文件里的路径是「作者机器」的

文中出现的 `D:\qwen-image-2.1\...`、`C:\Users\...\Desktop\...` 是作者本机的脚本位置。
在你自己的环境里请把它们替换成：

- 本仓库的 `scripts\` 目录（可移植版，配置驱动）
- 你自己的输出目录

**技能负责"该怎么判断和调用"，仓库脚本负责"具体怎么跑"。** 两者配合使用。

## 六个技能

| 技能 | 触发场景 | 对应仓库脚本 |
|---|---|---|
| `text-to-image` | 画图 / 改图 / 指令编辑 / 风格化 / 图片超分；含模型选型路由表、**7 条调用规则**、**附录 A 修图与超分技术栈** | `t2i.ps1` `img2img.ps1` `edit.ps1` `t2i-zimage.ps1` `t2i-moss.ps1` `img-upscale.ps1` |
| `image-to-video` | 图生视频、让图片动起来、一键后期 | `i2v.ps1` `post.ps1` |
| `text-to-video-h3` | 带声音的视频（音画同步） | `ai-video-h3.ps1` |
| `video-upscale` | 超分 / 放大 / 补帧（Lanczos / SeedVR2 / FlashVSR+） | `ai-upscale.ps1` `ai-upscale-flashvsr.ps1` `post.ps1` |
| `video-edit` | 拼接 / 延长 / 裁剪 / 放大 / 插帧 | `concat.ps1` `extend.ps1` `trim.ps1` `post.ps1` |
| `video-to-video` | 已有视频按提示词重绘风格 | `restyle.ps1` |

## 设计要点（为什么这么写）

1. **先路由再执行**：`text-to-image` 第一节就是"一句话 → 用哪个模型"的判定表，
   避免模型自己在五个模型之间瞎猜。
2. **规则写短、放最前**：本地小模型上下文小，长篇散文会被忽略，短表格命中率高。
3. **降级与快照写进脚本，不靠模型自觉**：模型判断可能出错，脚本层兜底。
4. **交付必须带参数**：每个技能末尾都要求报告分辨率/耗时/模型/文件位置。

## 第三方技能

`fisher-moss-prompt-expander`（把一句话扩写成 1500~2500 字详细提示词）是第三方项目，
Apache-2.0，未随本仓库分发，请从上游获取：

<https://github.com/Work-Fisher/fisher-moss-prompt-expander>