#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""修图引擎（Pillow）：确定性的图片小修小改，CPU 完成，不占显存。

用法：
  python 修图.py --in x.png --out y.png --ops "cropc=800,600;resize=0.5;color=1.1,1.05"

支持的 op（用 ; 分隔，按顺序执行）：
  crop=l,t,r,b            按像素裁剪
  cropc=W,H               居中裁剪到 W×H
  resize=0.5              按比例缩放
  resize=WxH              缩放到指定尺寸（任一维度写 0 表示按比例）
  thumb=W,H               等比缩到不超过 W×H（不放大）
  rotate=90               旋转（度，逆时针）
  flip=h|v                水平/垂直翻转
  color=b,c,s,sharp       亮度/对比度/饱和度/锐化（1.0 为不变，可只写前几个）
  gray                    转灰度
  autocontrast=1          自动对比度（cutoff 百分比）
  border=px,color         加边框
  radius=px               圆角（输出需 png/webp 保留透明）
  text:内容:字号:x:y:颜色:背景   叠加文字（颜色 #rrggbb，背景 none 表示透明）
  wtext:内容:位置:字号:不透明度:颜色   位置 tl/tr/bl/br/center
  wimg:路径:位置:缩放:不透明度        叠加图片水印
  montage:文件1|文件2|...:列数:格子尺寸:间距:背景   拼图
  quality=90              输出质量（jpg/webp）
  exif=fix                按 EXIF 方向自动转正
"""

import sys
import os
import json
import time
import argparse
import subprocess
import tempfile

import numpy as np

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

AKI_PY = os.environ.get('PIPE_ERASE_PYTHON') or sys.executable
ERASE_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'imgerase.py')

try:
    from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont, ImageOps
except ImportError:
    print(json.dumps({'ok': False, 'error': 'Pillow 未安装'}, ensure_ascii=False))
    sys.exit(3)


def parse_color(s, default=None):
    if not s or s.lower() in ('none', 'transparent', ''):
        return default
    s = s.strip()
    named = {'white': (255, 255, 255, 255), 'black': (0, 0, 0, 255),
             'red': (220, 40, 40, 255), 'grey': (128, 128, 128, 255), 'gray': (128, 128, 128, 255)}
    if s.lower() in named:
        return named[s.lower()]
    if s.startswith('#'):
        h = s[1:]
        if len(h) == 3:
            h = ''.join(c * 2 for c in h)
        if len(h) == 6:
            return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), 255)
        if len(h) == 8:
            return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), int(h[6:8], 16))
    return default


def load_font(size):
    """优先用系统中文字体，保证中文不出现方块。"""
    cands = [
        r'C:\Windows\Fonts\msyh.ttc',
        r'C:\Windows\Fonts\msyhbd.ttc',
        r'C:\Windows\Fonts\simhei.ttf',
        r'C:\Windows\Fonts\simsun.ttc',
        r'C:\Windows\Fonts\arial.ttf',
    ]
    for p in cands:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                continue
    return ImageFont.load_default()


def to_rgba(img):
    return img.convert('RGBA') if img.mode != 'RGBA' else img


def ensure_even(im):
    return im


def apply_op(img, op, part):
    """返回修改后的图像；part 是冒号语法拆出来的参数（可能为空）。"""
    key = op.lower()

    if key == 'crop':
        l, t, r, b = [int(float(x)) for x in part.split(',')]
        return img.crop((l, t, r, b))

    if key == 'cropc':
        w, h = [int(float(x)) for x in part.split(',')]
        return ImageOps.fit(img, (w, h), method=Image.LANCZOS, centering=(0.5, 0.5))

    if key == 'resize':
        p = part.lower()
        if 'x' in p:
            w, h = p.split('x')
            w, h = int(float(w)), int(float(h))
            if w == 0:
                w = max(1, round(img.width * h / img.height))
            if h == 0:
                h = max(1, round(img.height * w / img.width))
            return img.resize((w, h), Image.LANCZOS)
        s = float(p)
        return img.resize((max(1, round(img.width * s)), max(1, round(img.height * s))), Image.LANCZOS)

    if key == 'thumb':
        w, h = [int(float(x)) for x in part.split(',')]
        out = img.copy()
        out.thumbnail((w, h), Image.LANCZOS)
        return out

    if key == 'rotate':
        return img.rotate(float(part), expand=True)

    if key == 'flip':
        if part.lower().startswith('h'):
            return ImageOps.mirror(img)
        return ImageOps.flip(img)

    if key == 'color':
        vals = (part.split(',') + ['1', '1', '1', '1'])[:4]
        out = img
        for i, enh in enumerate((ImageEnhance.Brightness, ImageEnhance.Contrast,
                                 ImageEnhance.Color, ImageEnhance.Sharpness)):
            v = float(vals[i] or 1)
            if abs(v - 1.0) > 1e-6:
                out = enh(out).enhance(v)
        return out

    if key == 'gray':
        out = ImageOps.grayscale(img)
        return out.convert('RGBA') if img.mode == 'RGBA' else out.convert('RGB')

    if key == 'autocontrast':
        cutoff = float(part or 0)
        out = ImageOps.autocontrast(img.convert('RGB'), cutoff=cutoff)
        return out.convert('RGBA') if img.mode == 'RGBA' else out

    if key == 'border':
        seg = part.split(',')
        px = int(float(seg[0]))
        col = parse_color(seg[1] if len(seg) > 1 else 'white', (255, 255, 255, 255))
        base = to_rgba(img)
        out = Image.new('RGBA', (base.width + px * 2, base.height + px * 2), col)
        out.paste(base, (px, px), base if base.mode == 'RGBA' else None)
        return out

    if key == 'radius':
        r = int(float(part))
        base = to_rgba(img).copy()
        mask = Image.new('L', base.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, base.width - 1, base.height - 1], radius=r, fill=255)
        base.putalpha(mask)
        return base

    if key == 'text':
        seg = part.split(':')
        content = seg[0] if seg else ''
        size = int(float(seg[1])) if len(seg) > 1 and seg[1] else 32
        x = int(float(seg[2])) if len(seg) > 2 and seg[2] else 10
        y = int(float(seg[3])) if len(seg) > 3 and seg[3] else 10
        fg = parse_color(seg[4] if len(seg) > 4 else 'white', (255, 255, 255, 255))
        bg = parse_color(seg[5] if len(seg) > 5 else 'none', None)
        out = to_rgba(img).copy()
        d = ImageDraw.Draw(out)
        font = load_font(size)
        box = d.textbbox((x, y), content, font=font)
        if bg:
            d.rectangle([box[0] - 6, box[1] - 4, box[2] + 6, box[3] + 4], fill=bg)
        d.text((x, y), content, font=font, fill=fg)
        return out

    if key == 'wtext':
        seg = part.split(':')
        content = seg[0] if seg else ''
        pos = (seg[1] if len(seg) > 1 else 'br').lower()
        size = int(float(seg[2])) if len(seg) > 2 and seg[2] else max(14, img.width // 30)
        opacity = float(seg[3]) if len(seg) > 3 and seg[3] else 0.6
        color = parse_color(seg[4] if len(seg) > 4 else 'white', (255, 255, 255, 255))
        out = to_rgba(img).copy()
        layer = Image.new('RGBA', out.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        font = load_font(size)
        box = d.textbbox((0, 0), content, font=font)
        tw, th = box[2] - box[0], box[3] - box[1]
        margin = max(10, img.width // 60)
        if pos == 'tl':
            xy = (margin, margin)
        elif pos == 'tr':
            xy = (img.width - tw - margin, margin)
        elif pos == 'bl':
            xy = (margin, img.height - th - margin)
        elif pos == 'center':
            xy = ((img.width - tw) // 2, (img.height - th) // 2)
        else:
            xy = (img.width - tw - margin, img.height - th - margin)
        d.text(xy, content, font=font, fill=(color[0], color[1], color[2], int(255 * max(0, min(1, opacity)))))
        return Image.alpha_composite(out, layer)

    if key == 'wimg':
        # 语法：wimg:位置:缩放:不透明度:水印图片路径（路径放最后，避免 C: 被当分隔符）
        parts = part.split(':', 3)
        pos = (parts[0].strip() if len(parts) > 0 and parts[0] else 'br').lower()
        scale = float(parts[1]) if len(parts) > 1 and parts[1] else 0.15
        opacity = float(parts[2]) if len(parts) > 2 and parts[2] else 0.8
        path = parts[3].strip() if len(parts) > 3 else ''
        if not path or not os.path.exists(path):
            raise RuntimeError('水印图片不存在: ' + path)
        mark = Image.open(path).convert('RGBA')
        tw = max(16, int(img.width * scale))
        mark = mark.resize((tw, max(1, round(mark.height * tw / mark.width))), Image.LANCZOS)
        if opacity < 1:
            mark.putalpha(mark.split()[3].point(lambda v: int(v * opacity)))
        out = to_rgba(img).copy()
        margin = max(10, img.width // 50)
        if pos == 'tl':
            xy = (margin, margin)
        elif pos == 'tr':
            xy = (out.width - mark.width - margin, margin)
        elif pos == 'bl':
            xy = (margin, out.height - mark.height - margin)
        elif pos == 'center':
            xy = ((out.width - mark.width) // 2, (out.height - mark.height) // 2)
        else:
            xy = (out.width - mark.width - margin, out.height - mark.height - margin)
        layer = Image.new('RGBA', out.size, (0, 0, 0, 0))
        layer.paste(mark, xy, mark)
        return Image.alpha_composite(out, layer)
    if key == 'montage':
        # 语法：montage:列数:格子尺寸:间距:背景:清单文件
        parts = part.split(':', 4)
        cols = int(float(parts[0])) if len(parts) > 0 and parts[0] else 2
        cell = int(float(parts[1])) if len(parts) > 1 and parts[1] else 512
        pad = int(float(parts[2])) if len(parts) > 2 and parts[2] else 8
        bg = parse_color(parts[3] if len(parts) > 3 else '#000000', (0, 0, 0, 255))
        spec = parts[4].strip() if len(parts) > 4 else ''
        if not spec:
            raise RuntimeError('montage 缺少图片清单')
        if spec.lower().endswith('.txt') and os.path.exists(spec):
            files = [ln.strip() for ln in open(spec, 'r', encoding='utf-8') if ln.strip()]
        else:
            files = [f for f in spec.split('|') if f]
        if not files:
            raise RuntimeError('montage 没有给文件')
        tiles = []
        for f in files:
            if not os.path.exists(f):
                raise RuntimeError('文件不存在: ' + f)
            tile = Image.open(f).convert('RGBA')
            tile.thumbnail((cell, cell), Image.LANCZOS)
            canvas = Image.new('RGBA', (cell, cell), (0, 0, 0, 0))
            canvas.paste(tile, ((cell - tile.width) // 2, (cell - tile.height) // 2), tile)
            tiles.append(canvas)
        rows = (len(tiles) + cols - 1) // cols
        W = cols * cell + pad * (cols + 1)
        H = rows * cell + pad * (rows + 1)
        out = Image.new('RGBA', (W, H), bg)
        for i, tile in enumerate(tiles):
            r, c = divmod(i, cols)
            out.paste(tile, (pad + c * (cell + pad), pad + r * (cell + pad)), tile)
        return out
    if key == 'erase':
        # 抹除：erase=x1,y1,x2,y2  或  erase=掩码.png
        ex_tmp = tempfile.mkdtemp(prefix='erase-')
        ex_in = os.path.join(ex_tmp, 'in.png')
        ex_out = os.path.join(ex_tmp, 'out.png')
        to_rgba(img).convert('RGB').save(ex_in)
        args = [AKI_PY, ERASE_PY, '--in', ex_in, '--out', ex_out]
        p = part.strip()
        if p.lower().endswith(('.png', '.jpg', '.jpeg')) and os.path.exists(p):
            args += ['--mask', p]
        else:
            args += ['--rect', p]
        r = subprocess.run(args, capture_output=True, text=True, encoding='utf-8', errors='replace')
        out_line = ''
        for line in (r.stdout or '').splitlines():
            if line.strip().startswith('{'):
                out_line = line.strip()
                break
        if not out_line:
            raise RuntimeError('抹除失败：' + ((r.stdout or '') + (r.stderr or ''))[:200])
        info = json.loads(out_line)
        if not info.get('ok'):
            raise RuntimeError('抹除失败：' + str(info.get('error')))
        fixed = Image.open(ex_out).convert('RGB')
        try:
            import shutil
            shutil.rmtree(ex_tmp, ignore_errors=True)
        except Exception:
            pass
        return to_rgba(fixed) if img.mode == 'RGBA' else fixed

    if key == 'boxcolor':
        # 区域调色：boxcolor:亮度,对比,饱和,锐化:x1,y1,x2,y2:羽化
        segs = part.split(':')
        if len(segs) < 2:
            raise RuntimeError('boxcolor 语法：boxcolor:亮度,对比,饱和,锐化:x1,y1,x2,y2[:羽化]')
        vals = (segs[0].split(',') + ['1', '1', '1', '1'])[:4]
        bx1, by1, bx2, by2 = [int(float(v)) for v in segs[1].split(',')]
        feather = float(segs[2]) if len(segs) > 2 and segs[2] else 24

        adj = img.copy()
        for i, enh in enumerate((ImageEnhance.Brightness, ImageEnhance.Contrast,
                                 ImageEnhance.Color, ImageEnhance.Sharpness)):
            v = float(vals[i] or 1)
            if abs(v - 1.0) > 1e-6:
                adj = enh(adj).enhance(v)

        W2, H2 = img.size
        bx1 = max(0, min(W2 - 1, bx1)); by1 = max(0, min(H2 - 1, by1))
        bx2 = max(bx1 + 1, min(W2, bx2)); by2 = max(by1 + 1, min(H2, by2))
        m = Image.new('L', (W2, H2), 0)
        ImageDraw.Draw(m).rectangle([bx1, by1, bx2 - 1, by2 - 1], fill=255)
        if feather > 0:
            m = m.filter(ImageFilter.GaussianBlur(feather))
        return Image.composite(to_rgba(adj), to_rgba(img), m)
    if key == 'heal':
        # 平滑区域修复：heal=x1,y1,x2,y2[,迭代次数]  用周围做谐波填充（类似污点修复）
        seg = part.split(',')
        hx1, hy1, hx2, hy2 = [int(float(v)) for v in seg[:4]]
        iters = int(float(seg[4])) if len(seg) > 4 and seg[4] else 300
        W3, H3 = img.size
        hx1 = max(0, min(W3 - 1, hx1)); hy1 = max(0, min(H3 - 1, hy1))
        hx2 = max(hx1 + 1, min(W3, hx2)); hy2 = max(hy1 + 1, min(H3, hy2))
        pad = 40
        cx1, cy1 = max(0, hx1 - pad), max(0, hy1 - pad)
        cx2, cy2 = min(W3, hx2 + pad), min(H3, hy2 + pad)
        crop = to_rgba(img).crop((cx1, cy1, cx2, cy2))
        arr = np.asarray(crop).astype(np.float32)
        hh, ww = arr.shape[:2]
        mk = np.zeros((hh, ww), bool)
        mk[hy1 - cy1:hy2 - cy1, hx1 - cx1:hx2 - cx1] = True
        # 谐波填充：区域内反复用模糊值替换，边界固定
        for _ in range(max(30, iters)):
            blur = np.asarray(Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(3))).astype(np.float32)
            arr[mk] = blur[mk]
        filled = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), 'RGBA' if crop.mode == 'RGBA' else 'RGB')
        # 羽化贴回
        soft = Image.new('L', (ww, hh), 0)
        ImageDraw.Draw(soft).rectangle([hx1 - cx1, hy1 - cy1, hx2 - cx1 - 1, hy2 - cy1 - 1], fill=255)
        soft = soft.filter(ImageFilter.GaussianBlur(3))
        base = to_rgba(img).copy()
        base.paste(to_rgba(filled), (cx1, cy1), soft)
        return base
    if key == 'clone':
        # 克隆修补：clone=源x,源y,目标x,目标y,宽,高[,羽化]
        seg = [int(float(v)) for v in part.split(',')[:6]]
        fe = float(part.split(',')[6]) if len(part.split(',')) > 6 else 6
        sx_, sy_, dx_, dy_, w_, h_ = seg
        patch = to_rgba(img).crop((sx_, sy_, sx_ + w_, sy_ + h_))
        soft = Image.new('L', (w_, h_), 255).filter(ImageFilter.GaussianBlur(fe))
        base = to_rgba(img).copy()
        base.paste(patch, (dx_, dy_), soft)
        return base
    if key == 'blurfill':
        # 平滑区填补：blurfill=x1,y1,x2,y2[,sigma]  用四周颜色的大半径模糊覆盖
        seg = part.split(',')
        bx1, by1, bx2, by2 = [int(float(v)) for v in seg[:4]]
        sigma = float(seg[4]) if len(seg) > 4 and seg[4] else 25
        W4, H4 = img.size
        bx1 = max(0, min(W4 - 1, bx1)); by1 = max(0, min(H4 - 1, by1))
        bx2 = max(bx1 + 1, min(W4, bx2)); by2 = max(by1 + 1, min(H4, by2))
        pad = int(sigma * 2)
        cx1, cy1 = max(0, bx1 - pad), max(0, by1 - pad)
        cx2, cy2 = min(W4, bx2 + pad), min(H4, by2 + pad)
        crop = to_rgba(img).crop((cx1, cy1, cx2, cy2))
        soft_img = crop.filter(ImageFilter.GaussianBlur(sigma))
        soft = Image.new('L', crop.size, 0)
        ImageDraw.Draw(soft).rectangle([bx1 - cx1, by1 - cy1, bx2 - cx1 - 1, by2 - cy1 - 1], fill=255)
        soft = soft.filter(ImageFilter.GaussianBlur(max(2, sigma / 3)))
        base = to_rgba(img).copy()
        base.paste(soft_img, (cx1, cy1), soft)
        return base
    raise RuntimeError('不认识的 op: ' + key)


def argv_get(name, default=None):
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


def main():
    src = argv_get('--in')
    dst = argv_get('--out')
    ops_str = argv_get('--ops', '') or ''
    ops_file = argv_get('--opsfile')
    if ops_file and os.path.exists(ops_file):
        ops_str = open(ops_file, 'r', encoding='utf-8').read()
    quality = int(argv_get('--quality', 92))

    if not src or not dst:
        print(json.dumps({'ok': False, 'error': '缺少 --in 或 --out'}, ensure_ascii=False))
        return 2
    if not os.path.exists(src):
        print(json.dumps({'ok': False, 'error': '输入文件不存在: ' + src}, ensure_ascii=False))
        return 2

    t0 = time.time()
    img = Image.open(src)
    img.load()
    before = {'w': img.width, 'h': img.height, 'mode': img.mode, 'format': img.format}

    # 只按 ; 和换行切分；montage 的 | 保持在 op 内部
    raw = ops_str.replace('\r', '\n')
    ops = [o.strip() for o in raw.replace('\n', ';').split(';') if o.strip()]

    done = []
    out_format = None

    for o in list(ops):
        if o.lower().startswith('exif') and 'fix' in o.lower():
            img = ImageOps.exif_transpose(img)
            done.append('exif=fix')
            ops.remove(o)

    for o in ops:
        head = o.split('=')[0].split(':')[0].strip().lower()
        if head == 'quality':
            quality = int(float(o.split('=', 1)[1] if '=' in o else o.split(':', 1)[1]))
            continue
        if head == 'format':
            sep = '=' if '=' in o else ':'
            out_format = o.split(sep, 1)[1].strip().lower().lstrip('.')
            continue
        if '=' in o and ':' not in o.split('=')[0]:
            name, part = o.split('=', 1)
        elif ':' in o:
            name, part = o.split(':', 1)
        else:
            name, part = o, ''
        img = apply_op(img, name, part)
        done.append(o)

    ext = os.path.splitext(dst)[1].lower().lstrip('.')
    fmt = out_format or ext or 'png'
    if fmt in ('jpg', 'jpeg'):
        if img.mode == 'RGBA':
            bg = Image.new('RGB', img.size, (255, 255, 255))
            bg.paste(img, mask=img.split()[3])
            img = bg
        elif img.mode != 'RGB':
            img = img.convert('RGB')
        save_kwargs = {'quality': quality, 'optimize': True, 'progressive': True}
    elif fmt == 'webp':
        save_kwargs = {'quality': quality, 'method': 6}
    else:
        save_kwargs = {'optimize': True}

    os.makedirs(os.path.dirname(os.path.abspath(dst)), exist_ok=True)
    img.save(dst, **save_kwargs)

    after_img = Image.open(dst)
    print(json.dumps({
        'ok': True, 'src': src, 'dst': dst,
        'before': before,
        'after': {'w': after_img.width, 'h': after_img.height, 'format': fmt},
        'ops': done, 'quality': quality, 'seconds': round(time.time() - t0, 2),
    }, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as e:
        print(json.dumps({'ok': False, 'error': str(e)}, ensure_ascii=False))
        sys.exit(1)