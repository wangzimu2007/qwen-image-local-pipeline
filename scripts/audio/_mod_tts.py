# -*- coding: utf-8 -*-
"""Standalone TTS using the audio workbench (Kokoro). Prints output path."""
import argparse, sys, json
from pathlib import Path

WB = Path(r"D:\audio-tools\音频工作台")
sys.path.insert(0, str(WB))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", required=True)
    ap.add_argument("--voice", default="zf_001")
    ap.add_argument("--speed", type=float, default=1.0)
    ap.add_argument("--out", default=r"D:\audio-tools\gen-out")
    a = ap.parse_args()
    from desktop_backend import AudioBackend
    be = AudioBackend()
    r = be.tts(a.text, a.voice, float(a.speed))
    files = [p for p in r.get("files", []) if str(p).lower().endswith((".wav", ".mp3", ".flac"))]
    if not files:
        print(r.get("log", "TTS 失败"))
        raise SystemExit(1)
    print(json.dumps({"ok": True, "files": files}, ensure_ascii=False))
    for p in files:
        print("音频完成：" + str(p))

if __name__ == "__main__":
    main()