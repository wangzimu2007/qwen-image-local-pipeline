#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""LaMa 局部抹除：去掉水印 / 杂物 / 多余物体，用周围内容填补。

用法：
  python 修图_lama.py --in x.png --out y.png --rect 100,200,400,320 [--feather 6]

说明：
- 模型 D:\\lama\\models\\lama_fp32.onnx 固定 512×512 输入
- 实际流程：按矩形外扩取 ROI → 缩放到 512 → 推理 → 缩回 → 羽化贴回原图
- 必须用带 onnxruntime 的 Python（本机是秋叶版 3.13）
"""

import os
import sys
import json
import time
import argparse

import numpy as np
from PIL import Image, ImageFilter

MODEL = r'D:\lama\models\lama_fp32.onnx'
_ORT_SESSION = None


def get_session():
    global _ORT_SESSION
    if _ORT_SESSION is None:
        import onnxruntime as ort
        so = ort.SessionOptions()
        so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        _ORT_SESSION = ort.InferenceSession(MODEL, sess_options=so, providers=['CPUExecutionProvider'])
    return _ORT_SESSION


def build_rect_mask(w, h, x1, y1, x2, y2):
    m = np.zeros((h, w), dtype=np.uint8)
    x1 = max(0, min(w - 1, int(x1)))
    y1 = max(0, min(h - 1, int(y1)))
    x2 = max(x1 + 1, min(w, int(x2)))
    y2 = max(y1 + 1, min(h, int(y2)))
    m[y1:y2, x1:x2] = 255
    return m, (x1, y1, x2, y2)


def inpaint(img, mask, feather=6):
    """返回抹除后的 PIL RGB 图。"""
    sess = get_session()
    W, H = img.size

    ys, xs = np.where(mask > 127)
    if len(xs) == 0:
        return img

    bx1, bx2 = int(xs.min()), int(xs.max()) + 1
    by1, by2 = int(ys.min()), int(ys.max()) + 1

    # ROI 外扩 30%，并保证正方形，边长至少 128
    bw, bh = bx2 - bx1, by2 - by1
    pad = int(max(bw, bh) * 0.45) + 8
    side = max(128, max(bw, bh) + pad * 2)
    cx = (bx1 + bx2) // 2
    cy = (by1 + by2) // 2
    rx1 = max(0, cx - side // 2)
    ry1 = max(0, cy - side // 2)
    rx2 = min(W, rx1 + side)
    ry2 = min(H, ry1 + side)
    # 贴边时补足正方形
    rx1 = max(0, rx2 - side)
    ry1 = max(0, ry2 - side)

    roi = img.crop((rx1, ry1, rx2, ry2)).convert('RGB')
    roi_mask = Image.fromarray(mask[ry1:ry2, rx1:rx2], mode='L')

    tgt = 512
    roi_in = roi.resize((tgt, tgt), Image.LANCZOS)
    mask_in = roi_mask.resize((tgt, tgt), Image.NEAREST)

    arr = np.asarray(roi_in).astype(np.float32) / 255.0
    m = (np.asarray(mask_in).astype(np.float32) / 255.0)
    m = (m > 0.5).astype(np.float32)

    inp = arr.transpose(2, 0, 1)[None, ...]
    msk = m[None, None, ...]
    out = sess.run(None, {'image': inp, 'mask': msk})[0][0]
    out = np.clip(out, 0, 1).transpose(1, 2, 0)
    out_img = Image.fromarray((out * 255).astype(np.uint8), mode='RGB')

    out_img = out_img.resize((rx2 - rx1, ry2 - ry1), Image.LANCZOS)

    # 羽化：只在掩码边缘过渡，避免硬缝
    soft = roi_mask.filter(ImageFilter.GaussianBlur(max(0.1, feather)))
    base = img.convert('RGB').copy()
    base.paste(out_img, (rx1, ry1), soft)
    return base


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--in', dest='src', required=True)
    ap.add_argument('--out', dest='dst', required=True)
    ap.add_argument('--rect', default='')
    ap.add_argument('--mask', default='')
    ap.add_argument('--feather', type=float, default=6)
    args = ap.parse_args()

    if not os.path.exists(MODEL):
        print(json.dumps({'ok': False, 'error': 'LaMa 模型不存在: ' + MODEL}, ensure_ascii=False))
        return 2

    t0 = time.time()
    img = Image.open(args.src)
    img.load()
    W, H = img.size
    rgba = img.convert('RGBA')

    if args.mask:
        if not os.path.exists(args.mask):
            print(json.dumps({'ok': False, 'error': '掩码不存在: ' + args.mask}, ensure_ascii=False))
            return 2
        mk = Image.open(args.mask).convert('L').resize((W, H), Image.NEAREST)
        mask = np.asarray(mk)
        box = None
    else:
        parts = [float(v) for v in args.rect.split(',')]
        if len(parts) != 4:
            print(json.dumps({'ok': False, 'error': '--rect 需要 4 个数：x1,y1,x2,y2'}, ensure_ascii=False))
            return 2
        mask, box = build_rect_mask(W, H, *parts)

    result = inpaint(rgba, mask, feather=args.feather)

    # 保留原 alpha（若有）
    if 'A' in img.getbands():
        r2 = result.convert('RGBA')
        r2.putalpha(img.convert('RGBA').split()[3])
        result = r2

    os.makedirs(os.path.dirname(os.path.abspath(args.dst)), exist_ok=True)
    fmt = os.path.splitext(args.dst)[1].lower().lstrip('.')
    if fmt in ('jpg', 'jpeg'):
        result.convert('RGB').save(args.dst, quality=95, optimize=True)
    else:
        result.save(args.dst)

    print(json.dumps({
        'ok': True, 'dst': args.dst, 'rect': box,
        'size': [W, H], 'seconds': round(time.time() - t0, 2),
    }, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as e:
        print(json.dumps({'ok': False, 'error': str(e)}, ensure_ascii=False))
        sys.exit(1)
