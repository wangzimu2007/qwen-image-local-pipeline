#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""快速抹除（OpenCV inpaint）：去掉水印 / 小杂物 / 小块污点。

用法：
  python 修图_erase.py --in x.png --out y.png --rect 100,540,240,640 [--method telea|ns] [--radius 5]
  python 修图_erase.py --in x.png --out y.png --mask mask.png

适用：小到中等面积（几十像素到几百像素），背景有纹理时效果最好。
大面积会糊 —— 大面积请用 AI 重绘（后续可接 Z-Image inpaint）。
"""

import os
import sys
import json
import time
import argparse

import numpy as np
import cv2
from PIL import Image


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--in', dest='src', required=True)
    ap.add_argument('--out', dest='dst', required=True)
    ap.add_argument('--rect', default='')
    ap.add_argument('--mask', default='')
    ap.add_argument('--method', default='telea')
    ap.add_argument('--radius', type=float, default=5)
    ap.add_argument('--dilate', type=int, default=2)
    args = ap.parse_args()

    if not os.path.exists(args.src):
        print(json.dumps({'ok': False, 'error': '输入不存在: ' + args.src}, ensure_ascii=False))
        return 2

    t0 = time.time()
    bgr = cv2.imread(args.src, cv2.IMREAD_COLOR)
    if bgr is None:
        print(json.dumps({'ok': False, 'error': '读不出图片（中文路径请先转成英文临时路径）'}, ensure_ascii=False))
        return 2
    H, W = bgr.shape[:2]

    if args.mask:
        if not os.path.exists(args.mask):
            print(json.dumps({'ok': False, 'error': '掩码不存在: ' + args.mask}, ensure_ascii=False))
            return 2
        m = cv2.imread(args.mask, cv2.IMREAD_GRAYSCALE)
        if m is None:
            print(json.dumps({'ok': False, 'error': '读不出掩码'}, ensure_ascii=False))
            return 2
        if (m.shape[1], m.shape[0]) != (W, H):
            m = cv2.resize(m, (W, H), interpolation=cv2.INTER_NEAREST)
        mask = (m > 127).astype(np.uint8) * 255
    else:
        parts = [float(v) for v in args.rect.split(',')]
        if len(parts) < 4:
            print(json.dumps({'ok': False, 'error': '--rect 需要 x1,y1,x2,y2'}, ensure_ascii=False))
            return 2
        x1, y1, x2, y2 = [int(v) for v in parts[:4]]
        x1, x2 = sorted((max(0, min(W - 1, x1)), max(1, min(W, x2))))
        y1, y2 = sorted((max(0, min(H - 1, y1)), max(1, min(H, y2))))
        mask = np.zeros((H, W), np.uint8)
        mask[y1:y2, x1:x2] = 255

    if args.dilate > 0:
        k = np.ones((args.dilate * 2 + 1, args.dilate * 2 + 1), np.uint8)
        mask = cv2.dilate(mask, k, iterations=1)

    flag = cv2.INPAINT_NS if str(args.method).lower().startswith('n') else cv2.INPAINT_TELEA
    fixed = cv2.inpaint(bgr, mask, float(args.radius), flag)

    # 用羽化掩码把修补区域贴回，避免硬边
    if args.dilate > 0:
        soft = cv2.GaussianBlur(mask, (0, 0), max(1.0, args.dilate * 2.0)).astype(np.float32) / 255.0
        soft = soft[..., None]
        out = (fixed.astype(np.float32) * soft + bgr.astype(np.float32) * (1 - soft))
        out = np.clip(out, 0, 255).astype(np.uint8)
    else:
        out = fixed

    os.makedirs(os.path.dirname(os.path.abspath(args.dst)), exist_ok=True)
    cv2.imwrite(args.dst, out)
    print(json.dumps({
        'ok': True, 'dst': args.dst, 'size': [W, H],
        'mask_pixels': int((mask > 127).sum()),
        'seconds': round(time.time() - t0, 2),
    }, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as e:
        print(json.dumps({'ok': False, 'error': str(e)}, ensure_ascii=False))
        sys.exit(1)
