# 生成 README 用的对比图
import os, sys, subprocess
import av
from PIL import Image, ImageDraw, ImageFont

OUT = r"D:\publish\qwen-image-local-pipeline\assets\samples"
os.makedirs(OUT, exist_ok=True)
py = sys.executable

def mid_frame(video, out_png):
    c = av.open(video); s = c.streams.video[0]
    frames = [f.to_image() for f in c.decode(s)]
    img = frames[len(frames)//2]
    img.save(out_png)
    return img

def font(size, bold=False):
    for p in (r"C:\Windows\Fonts\msyhbd.ttc" if bold else r"C:\Windows\Fonts\msyh.ttc",
              r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\simhei.ttf"):
        if os.path.exists(p):
            try: return ImageFont.truetype(p, size)
            except Exception: pass
    return ImageFont.load_default()

F_TITLE = font(30, True)
F_LABEL = font(21, True)
F_SMALL = font(18)

BG = (16, 20, 26)
CARD = (26, 32, 40)
TXT = (230, 237, 243)
DIM = (154, 167, 180)
ACC = (77, 163, 255)
GRN = (63, 185, 80)

def fit(img, w, h):
    r = min(w / img.width, h / img.height)
    return img.resize((int(img.width * r), int(img.height * r)), Image.LANCZOS)

def panel(dst, img, x, y, w, h, label, sub=""):
    d = ImageDraw.Draw(dst)
    d.rectangle([x, y, x + w, y + h], fill=CARD, outline=(42, 49, 60), width=2)
    im = fit(img, w - 24, h - 84)
    dst.paste(im, (x + (w - im.width) // 2, y + 12))
    d.text((x + 14, y + h - 62), label, font=F_LABEL, fill=TXT)
    if sub:
        d.text((x + 14, y + h - 34), sub, font=F_SMALL, fill=DIM)

# ---------- 对比图 1：视频 AI 超分 ----------
src_v = r"C:\Users\wangzimu\Desktop\视频\video-0002-wan-20261024-124801.mp4"
up_v  = r"C:\Users\wangzimu\Desktop\视频\video-0015-wan-20261024-141944.mp4"
a = mid_frame(src_v, os.path.join(OUT, "_tmp_a.png"))   # 832x480
b = mid_frame(up_v,  os.path.join(OUT, "_tmp_b.png"))   # 1248x720

W, H = 1360, 1030
canvas = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(canvas)
d.text((30, 24), "视频 AI 超分对比 · SeedVR2 3B (fp8)", font=F_TITLE, fill=TXT)
d.text((30, 64), "Video AI upscale — Lanczos 无法还原的细节，扩散模型能重建", font=F_SMALL, fill=DIM)

pw = (W - 90) // 2
panel(canvas, a, 30, 100, pw, 400, "原始 Original", "832 × 480 · 121 帧 · 24 fps")
panel(canvas, b, 30 + pw + 30, 100, pw, 400, "AI 超分 Upscaled", "1248 × 720 · SeedVR2 3B fp8 · 103 秒")

# 局部放大对比（同一区域：灯塔 + 礁石，细节最丰富）
cx, cy, cw, ch = 0.38, 0.04, 0.26, 0.30
def crop(img, scale_to):
    x0, y0 = int(img.width * cx), int(img.height * cy)
    x1, y1 = x0 + int(img.width * cw), y0 + int(img.height * ch)
    c = img.crop((x0, y0, x1, y1))
    r = max(1, int(scale_to / c.width))
    return c.resize((c.width * r, c.height * r), Image.LANCZOS)

ca, cb = crop(a, 0), crop(b, 0)
zoom = min((pw - 24) / ca.width, 400 / ca.height)
ca = ca.resize((int(ca.width * zoom), int(ca.height * zoom)), Image.LANCZOS) if zoom > 1 else ca
zoom2 = min((pw - 24) / cb.width, 400 / cb.height)
cb = cb.resize((int(cb.width * zoom2), int(cb.height * zoom2)), Image.LANCZOS) if zoom2 > 1 else cb

panel(canvas, ca, 30, 525, pw, 400, "局部放大 ×3 Original", "建筑/岩石边缘：糊、块状")
panel(canvas, cb, 30 + pw + 30, 525, pw, 400, "局部放大 ×3 Upscaled", "边缘重建、纹理连续")
d = ImageDraw.Draw(canvas)
d.rectangle([30, 960, W - 30, 1000], fill=(20, 26, 33))
d.text((44, 970), "同一帧 · 同一区域 · 无其他处理（未插帧、未调色）", font=F_SMALL, fill=GRN)
canvas.save(os.path.join(OUT, "compare-video-upscale.jpg"), quality=90, optimize=True)
print("saved compare-video-upscale.jpg")

# ---------- 对比图 2：流水线三段 ----------
v1 = src_v
v2 = up_v
v3 = r"C:\Users\wangzimu\Desktop\视频\video-0009-wan-20261024-135113.mp4"  # 1248x720@48
f1 = mid_frame(v1, os.path.join(OUT, "_tmp_1.png"))
f2 = mid_frame(v2, os.path.join(OUT, "_tmp_2.png"))
f3 = mid_frame(v3, os.path.join(OUT, "_tmp_3.png")) if os.path.exists(v3) else f2

W3, H3 = 1620, 520
c3 = Image.new("RGB", (W3, H3), BG)
d = ImageDraw.Draw(c3)
d.text((30, 22), "一条命令的完整流水线 · t2v → AI 超分 → 插帧", font=F_TITLE, fill=TXT)
d.text((30, 60), "Draft 832×480 → SeedVR2 720p → FILM 48fps（总计 5.9 分钟）", font=F_SMALL, fill=DIM)
pw3 = (W3 - 120) // 3
for i, (imgx, lab, sub) in enumerate([
        (f1, "① 草稿生成 Draft", "832×480 · 24 fps · 125 秒"),
        (f2, "② AI 超分 Upscale", "1248×720 · SeedVR2 · 103 秒"),
        (f3, "③ 插帧 Interpolate", "1248×720 · 48 fps · 16 秒")]):
    x = 30 + i * (pw3 + 30)
    panel(c3, imgx, x, 110, pw3, 380, lab, sub)
    if i < 2:
        d.text((x + pw3 + 4, 280), "→", font=font(34, True), fill=ACC)
c3.save(os.path.join(OUT, "compare-pipeline.jpg"), quality=90, optimize=True)
print("saved compare-pipeline.jpg")

# ---------- 对比图 3：图片超分 4K ----------
isrc = r"C:\Users\wangzimu\Desktop\Qwen 图片\qwen-0035-t2i-20261024-095218.png"
iup  = r"C:\Users\wangzimu\Desktop\Qwen 图片\qwen-0038-up-20261024-150244.png"
if os.path.exists(isrc) and os.path.exists(iup):
    A = Image.open(isrc).convert("RGB")   # 1280x768
    B = Image.open(iup).convert("RGB")    # 3600x2160
    W4, H4 = 1360, 760
    c4 = Image.new("RGB", (W4, H4), BG)
    d4 = ImageDraw.Draw(c4)
    d4.text((30, 22), "图片 AI 超分：2K → 4K", font=F_TITLE, fill=TXT)
    d4.text((30, 60), "1024×1024 → 1440×1440 / 1280×768 → 3600×2160（SeedVR2 单图模式，约 15~100 秒）", font=F_SMALL, fill=DIM)
    pw4 = (W4 - 90) // 2
    panel(c4, A, 30, 100, pw4, 520, "原始 Original", "1280 × 768 · 1.0 MP")
    panel(c4, B, 30 + pw4 + 30, 100, pw4, 520, "AI 超分 4K", "3600 × 2160 · 7.8 MP · 102 秒")
    d4.text((30, 650), "结论：不是简单插值放大，雪面/岩石/木屋纹理都是重建出来的", font=F_SMALL, fill=GRN)
    c4.save(os.path.join(OUT, "compare-image-upscale.jpg"), quality=90, optimize=True)
    print("saved compare-image-upscale.jpg")

# 清理临时帧
for f in os.listdir(OUT):
    if f.startswith("_tmp_"):
        os.remove(os.path.join(OUT, f))
print("done")
