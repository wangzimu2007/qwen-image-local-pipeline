# v0.3.1 — 发布 AI 助手技能包（6 个 SKILL.md）

本版把项目配套的 **Agent 技能（skills）** 一并开源，让 AI 助手能按"说人话"的方式驱动这套流水线。

## 新增

- `skills/text-to-image/SKILL.md` — 画图 / 改图 / 指令编辑 / 风格化 / 图片超分，**含模型选型路由表**
- `skills/image-to-video/SKILL.md` — 图生视频 + 一键后期
- `skills/text-to-video-h3/SKILL.md` — 带音频视频（音画同步）
- `skills/video-upscale/SKILL.md` — 超分 / 放大 / 补帧（Lanczos / SeedVR2 / FlashVSR+）
- `skills/video-edit/SKILL.md` — 拼接 / 延长 / 裁剪 / 放大 / 插帧
- `skills/video-to-video/SKILL.md` — 视频按提示词重绘风格
- `skills/README.md` — 安装方法、路径替换说明、六个技能对照表、设计要点

## 技能里固化下来的四件事

1. **先路由再执行**：一句话 → 用哪个模型（避免在多个模型之间瞎猜）
2. **参数与档位**：步数 / LoRA 权重 / 分辨率 / denoise 的实测建议值
3. **失败自动降级**：关 LoRA → 降步数 → 降分辨率，日志里标明降了什么
4. **交付规范**：必须报告分辨率 / 耗时 / 模型 / 文件位置

## 注意

- 技能文件里的 `D:\qwen-image-2.1\...` 是作者机器路径，**使用时替换成本仓库的 `scripts\`**
- 第三方技能 `fisher-moss-prompt-expander`（Apache-2.0）未随仓库分发，README 里给了上游链接