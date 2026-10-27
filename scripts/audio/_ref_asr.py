# -*- coding: utf-8 -*-
"""Reference audio -> transcript (faster-whisper, for zero-shot TTS prompt text)."""
import argparse
import glob
import json
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

from faster_whisper import WhisperModel


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--audio", required=True)
    ap.add_argument("--language", default="auto")
    a = ap.parse_args()
    md = sorted(glob.glob(r"D:\audio-tools\hf-cache\models--mobiuslabsgmbh--faster-whisper-large-v3-turbo\snapshots\*"))[-1]
    m = WhisperModel(md, device="cpu", compute_type="int8")
    lang = None if a.language in ("", "auto") else a.language
    segs, info = m.transcribe(a.audio, language=lang, beam_size=5, vad_filter=True)
    text = "".join(s.text for s in segs).strip()
    print("TEXT=" + json.dumps(text, ensure_ascii=False))
    print("LANG=" + str(info.language))


if __name__ == "__main__":
    main()
