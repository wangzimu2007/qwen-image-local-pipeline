# Promo / 发布物料

| 文件 | 用途 |
|---|---|
| `cover-1920x1080.jpg` | 通用封面（YouTube / 公众号头图 / README 首图） |
| `cover-bilibili-1146x717.jpg` | B 站投稿封面（直接上传，无需裁切） |
| `release-notes-v0.1.0.md` | GitHub Release 正文（标题 + body + 附件清单，可直接粘贴） |
| `launch-copy.md` | 发布文案：标题候选、开头钩子、B 站时间轴脚本、长文结构、配图清单 |
| `make_cover.py` | 重新生成封面（改文字/版式后重跑） |
| `make_compare.py` | 重新生成效果对比图（需要本地成片） |

## 封面设计要点

- 背景用**真实成片帧**（不是素材图），压暗 + 3px 模糊保证文字可读
- 主标题 6 个字：「一条命令出片」，其中「出片」走高亮色
- 三个数据徽章：**5.9 分钟 / 720p 48fps / 13 个脚本**（时间、质量、体量）
- 缩放后仍可读：B 站缩略图尺寸下标题依然清晰

## 重新生成

```powershell
# 需要：Python + Pillow + av，以及本地产出的成片视频
python promo/make_cover.py
python promo/make_compare.py
```