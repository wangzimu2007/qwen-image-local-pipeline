# 生成 B 站封面（16:9，带标题文字）
import os
import av
from PIL import Image, ImageDraw, ImageFont, ImageFilter

OUT_DIR = r"D:\publish"
SAMPLES = r"D:\publish\qwen-image-local-pipeline\assets\samples"
BG_VIDEO = r"C:\Users\wangzimu\Desktop\视频\video-0002-wan-20261024-124801.mp4"

def font(size, bold=False):
    cands = [r"C:\Windows\Fonts\msyhbd.ttc", r"C:\Windows\Fonts\msyh.ttc"] if bold else [r"C:\Windows\Fonts\msyh.ttc"]
    for p in cands:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    return ImageFont.load_default()

def cover_1080(png_path):
    W, H = 1920, 1080
    # 背景：视频中间帧，铺满 + 轻微模糊
    c = av.open(BG_VIDEO); s = c.streams.video[0]
    frames = [f.to_image() for f in c.decode(s)]
    bg = frames[len(frames)//2]
    r = max(W / bg.width, H / bg.height)
    bg = bg.resize((int(bg.width * r) + 1, int(bg.height * r) + 1), Image.LANCZOS)
    left = (bg.width - W) // 2
    top = (bg.height - H) // 2
    bg = bg.crop((left, top, left + W, top + H)).filter(ImageFilter.GaussianBlur(3))

    # 压暗：左侧更暗，保证文字可读
    overlay = Image.new("L", (W, H), 0)
    od = ImageDraw.Draw(overlay)
    for x in range(W):
        # 左黑右透
        alpha = int(210 - 150 * (x / W))
        od.line([(x, 0), (x, H)], fill=max(60, alpha))
    dark = Image.new("RGB", (W, H), (6, 9, 13))
    bg = Image.composite(dark, bg, overlay)

    # 顶部/底部再加一层渐变压暗
    vgrad = Image.new("L", (1, H), 0)
    vd = ImageDraw.Draw(vgrad)
    for y in range(H):
        a = 0
        if y < 220: a = int(120 * (1 - y / 220))
        if y > H - 260: a = max(a, int(150 * ((y - (H - 260)) / 260)))
        vd.point((0, y), fill=a)
    vgrad = vgrad.resize((W, H))
    bg = Image.composite(dark, bg, vgrad)

    canvas = bg.convert("RGB")
    d = ImageDraw.Draw(canvas)

    # 左侧竖条
    d.rectangle([96, 250, 108, 690], fill=(77, 163, 255))

    # 主标题：一条命令出片（"出片"高亮）
    x, y = 140, 246
    f_title = font(132, True)
    part1 = "一条命令"
    part2 = "出片"
    d.text((x, y), part1, font=f_title, fill=(240, 246, 252))
    w1 = d.textlength(part1, font=f_title)
    d.text((x + w1, y), part2, font=f_title, fill=(77, 163, 255))

    # 副标题
    f_sub = font(48, True)
    d.text((x, y + 170), "文生图 → 视频 → AI 超分 → 48fps", font=f_sub, fill=(200, 214, 228))

    # 第二行小字
    f_small = font(38)
    d.text((x, y + 240), "全本地推理 · 不调云端 API · 24GB 显卡实测", font=f_small, fill=(154, 167, 180))

    # 数据徽章
    badges = [("5.9 分钟", "一句话到成片"), ("720p / 48fps", "超分 + 插帧"), ("13 个脚本", "MIT 开源")]
    bx, by = x, y + 330
    f_bn = font(46, True)
    f_bs = font(30)
    for i, (big, small) in enumerate(badges):
        bw = int(max(d.textlength(big, font=f_bn), d.textlength(small, font=f_bs)) + 60)
        bh = 132
        bw = int(bw)
        mask = Image.new("L", (bw, bh), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, bw - 1, bh - 1], radius=16, fill=255)
        canvas.paste(Image.new("RGB", (bw, bh), (20, 26, 33)), (bx, by), mask)
        dd = ImageDraw.Draw(canvas)
        dd.rounded_rectangle([bx, by, bx + bw, by + bh], radius=16, outline=(52, 62, 76), width=2)
        dd.rounded_rectangle([bx, by, bx + bw, by + bh], radius=16, outline=(52, 62, 76), width=2)
        dd.text((bx + 30, by + 18), big, font=f_bn, fill=(77, 163, 255))
        dd.text((bx + 30, by + 78), small, font=f_bs, fill=(154, 167, 180))
        bx += bw + 24

    # 右下角仓库名
    f_repo = font(34, True)
    repo = "qwen-image-local-pipeline"
    tw = d.textlength(repo, font=f_repo)
    d.text((W - 110 - tw, H - 118), repo, font=f_repo, fill=(120, 134, 150))

    # 右下角小装饰：三条进度块（示意流水线）
    for i in range(3):
        cxp = W - 110 - tw - 260 + i * 74
        col = (77, 163, 255) if i < 2 else (63, 185, 80)
        d.rounded_rectangle([cxp, H - 96, cxp + 58, H - 74], radius=6, fill=col)

    canvas.save(png_path, quality=92, optimize=True)
    print("saved", png_path, canvas.size)
    return canvas

c1 = cover_1080(os.path.join(OUT_DIR, "封面-一条命令出片.jpg"))

# B 站封面规格 1146x717（比例接近，缩放到 16:9 后裁）
W2, H2 = 1146, 717
r = max(W2 / c1.width, H2 / c1.height)
c2 = c1.resize((int(c1.width * r), int(c1.height * r)), Image.LANCZOS)
left = (c2.width - W2) // 2
top = (c2.height - H2) // 2
c2 = c2.crop((left, top, left + W2, top + H2))
p2 = os.path.join(OUT_DIR, "封面-B站1146x717.jpg")
c2.save(p2, quality=92, optimize=True)
print("saved", p2, c2.size)
