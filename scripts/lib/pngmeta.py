#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""给 PNG 写入文本元数据（模型 / 许可 / 提示词 / 种子），用于溯源与许可留痕。

用法：
  python _pngmeta.py --in x.png --key Model --value "PixelDiT 1.3B" [...]
简写：
  python _pngmeta.py --in x.png --json '{"Model":"...","License":"..."}'
"""

import argparse
import json
import os
import sys

from PIL import Image
from PIL.PngImagePlugin import PngInfo


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--in', dest='src', required=True)
    ap.add_argument('--key', action='append', default=[])
    ap.add_argument('--value', action='append', default=[])
    ap.add_argument('--json', dest='jstr', default='')
    ap.add_argument('--jsonfile', dest='jfile', default='')
    args = ap.parse_args()

    if not os.path.exists(args.src):
        print(json.dumps({'ok': False, 'error': '文件不存在'}, ensure_ascii=False))
        return 2
    if not args.src.lower().endswith('.png'):
        print(json.dumps({'ok': True, 'skipped': '非 PNG，跳过元数据'}, ensure_ascii=False))
        return 0

    meta = {}
    if args.jfile and os.path.exists(args.jfile):
        with open(args.jfile, 'r', encoding='utf-8') as fh:
            meta.update(json.load(fh))
    elif args.jstr:
        meta.update(json.loads(args.jstr))
    for k, v in zip(args.key, args.value):
        meta[k] = v
    if not meta:
        print(json.dumps({'ok': False, 'error': '没有要写入的键值'}, ensure_ascii=False))
        return 2

    img = Image.open(args.src)
    info = PngInfo()
    # 保留原有 text 块
    for k, v in (img.info or {}).items():
        if isinstance(v, str) and k not in ('icc_profile',):
            try:
                info.add_text(str(k), v)
            except Exception:
                pass
    for k, v in meta.items():
        info.add_text(str(k), str(v))
    img.save(args.src, pnginfo=info)
    print(json.dumps({'ok': True, 'added': list(meta.keys())}, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as e:
        print(json.dumps({'ok': False, 'error': str(e)}, ensure_ascii=False))
        sys.exit(1)
