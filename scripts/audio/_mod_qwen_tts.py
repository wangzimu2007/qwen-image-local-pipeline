# -*- coding: utf-8 -*-
"""Qwen3-TTS VoiceDesign：文字 + 声音描述 → 语音（本地，Apache-2.0）。

用法：
  python _mod_qwen_tts.py --text "旁白内容" --instruct "低沉磁性的中年男声，语速偏慢" --out D:\audio-tools\gen-out
  python _mod_qwen_tts.py --text "..." --instruct "..." --out D:\...\a.wav --language Chinese
"""
import argparse
import json
import os
import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf

MODEL_DIR = r"D:\audio-tools\qwen3-tts\voicedesign"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", default="")
    ap.add_argument("--text-file", default="")
    ap.add_argument("--instruct-file", default="")
    ap.add_argument("--instruct", default="")
    ap.add_argument("--language", default="Chinese")
    ap.add_argument("--out", required=True)
    ap.add_argument("--model", default=MODEL_DIR)
    ap.add_argument("--max-new-tokens", type=int, default=2048)
    a = ap.parse_args()
    if a.text_file:
        a.text = Path(a.text_file).read_text(encoding="utf-8").strip()
    if a.instruct_file:
        a.instruct = Path(a.instruct_file).read_text(encoding="utf-8").strip()
    if not a.text:
        raise SystemExit("缺少 --text 或 --text-file")

    out = Path(a.out)
    if out.suffix.lower() not in (".wav", ".flac"):
        out = out / f"qwen3tts-{time.strftime('%Y%m%d-%H%M%S')}.wav"
    out.parent.mkdir(parents=True, exist_ok=True)

    t0 = time.time()
    import torch
    from qwen_tts import Qwen3TTSModel
    model = Qwen3TTSModel.from_pretrained(
        a.model,
        device_map="cuda:0",
        dtype=torch.bfloat16,
        attn_implementation="sdpa",   # Windows 上没有 flash-attn，用 sdpa
    )
    load_s = time.time() - t0

    t1 = time.time()
    wavs, sr = model.generate_voice_design(
        text=a.text,
        instruct=a.instruct,
        language=a.language,
        max_new_tokens=a.max_new_tokens,
    )
    gen_s = time.time() - t1
    wav = np.asarray(wavs[0], dtype=np.float32)
    sf.write(str(out), wav, sr)
    dur = len(wav) / float(sr)

    meta = {
        "ok": True,
        "file": str(out),
        "sample_rate": int(sr),
        "duration_sec": round(dur, 2),
        "load_sec": round(load_s, 2),
        "gen_sec": round(gen_s, 2),
        "rtf": round(gen_s / dur, 3) if dur > 0 else None,
        "text": a.text,
        "instruct": a.instruct,
        "language": a.language,
    }
    print("音频完成：" + str(out))
    print("RESULT=" + str(out))
    print("META=" + json.dumps(meta, ensure_ascii=False))

    # 释放显存
    try:
        del model
        import torch as _t
        _t.cuda.empty_cache()
    except Exception:
        pass


if __name__ == "__main__":
    main()
