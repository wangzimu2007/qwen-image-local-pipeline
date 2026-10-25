#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""根据「文案 + 视频时长」生成 srt 字幕（不依赖语音识别）。

用途：视频是无声的（Wan 生成），字幕来自用户给的文案，按字符数均分到各时间段。

用法：
  python _mksrt.py --video x.mp4 --text "第一句。第二句。" --out sub.srt [--max-chars 18]
"""

import argparse
import os
import subprocess
import sys


def probe_duration(video):
    ffprobe = r'D:\tools\ffmpeg\bin\ffprobe.exe'
    if os.path.exists(ffprobe):
        out = subprocess.run(
            [ffprobe, '-v', 'error', '-show_entries', 'format=duration',
             '-of', 'default=noprint_wrappers=1:nokey=1', video],
            capture_output=True, text=True)
        try:
            return float(out.stdout.strip())
        except Exception:
            pass
    # 退化：用 PyAV
    try:
        import av
        c = av.open(video)
        d = float(c.duration or 0) / 1e6
        c.close()
        return d
    except Exception:
        return 0.0


def split_text(text, max_chars=18):
    """按句末标点切分，再按 max_chars 二次切分。"""
    seps = '。！？!?；;\n'
    parts, buf = [], ''
    for ch in text:
        buf += ch
        if ch in seps:
            parts.append(buf.strip())
            buf = ''
    if buf.strip():
        parts.append(buf.strip())

    out = []
    for p in parts:
        if not p:
            continue
        while len(p) > max_chars:
            cut = p.rfind('，', 0, max_chars)
            if cut < max_chars // 3:
                cut = max_chars
            out.append(p[:cut + 1].strip())
            p = p[cut + 1:].strip()
        if p:
            out.append(p)
    return out


def fmt(t):
    h = int(t // 3600)
    m = int((t % 3600) // 60)
    s = t % 60
    return ('%02d:%02d:%06.3f' % (h, m, s)).replace('.', ',')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--video', required=True)
    ap.add_argument('--text', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--max-chars', type=int, default=18)
    ap.add_argument('--lead', type=float, default=0.2, help='开头留白秒数')
    ap.add_argument('--tail', type=float, default=0.3, help='结尾留白秒数')
    a = ap.parse_args()

    dur = probe_duration(a.video)
    if dur <= 0:
        print('ERROR: 读不到视频时长')
        return 2

    parts = split_text(a.text, a.max_chars)
    if not parts:
        print('ERROR: 文案切分为空')
        return 2

    usable = max(0.5, dur - a.lead - a.tail)
    total_chars = sum(len(p) for p in parts)
    lines = []
    t = a.lead
    for i, p in enumerate(parts, 1):
        seg = usable * (len(p) / total_chars)
        start, end = t, min(dur - 0.05, t + seg)
        if end <= start:
            end = start + 0.4
        lines += [str(i), '%s --> %s' % (fmt(start), fmt(end)), p, '']
        t = end

    with open(a.out, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))
    print('已生成 %d 条字幕 → %s（视频 %.2f 秒）' % (len(parts), a.out, dur))
    return 0


if __name__ == '__main__':
    sys.exit(main())
