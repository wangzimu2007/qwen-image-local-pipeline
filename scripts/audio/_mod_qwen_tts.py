# -*- coding: utf-8 -*-
"""Qwen3-TTS 本地配音（VoiceDesign 1.7B / CustomVoice 0.6B）。

模式：
  design —— 自然语言描述音色（1.7B，RTF≈2.9）
  custom —— 固定 speaker + 风格指令（0.6B，RTF≈1.45）
用法：
  python _mod_qwen_tts.py --text "..." --instruct "低沉男声" --out a.wav
  python _mod_qwen_tts.py --text "..." --mode custom --speaker serena --out b.wav
"""
import argparse
import json
import sys
import time
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

DESIGN_DIR = r"D:\audio-tools\qwen3-tts\voicedesign"
CUSTOM_DIR = r"D:\audio-tools\qwen3-tts\customvoice-0.6b"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", default="")
    ap.add_argument("--text-file", default="")
    ap.add_argument("--instruct-file", default="")
    ap.add_argument("--instruct", default="")
    ap.add_argument("--language", default="Chinese")
    ap.add_argument("--out", required=True)
    ap.add_argument("--mode", default="design", choices=["design", "custom"])
    ap.add_argument("--speaker", default="")
    ap.add_argument("--model", default="")
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

    model_dir = a.model or (CUSTOM_DIR if a.mode == "custom" else DESIGN_DIR)
    t0 = time.time()
    import numpy as np
    import soundfile as sf
    import torch
    from qwen_tts import Qwen3TTSModel
    model = Qwen3TTSModel.from_pretrained(
        model_dir,
        device_map="cuda:0",
        dtype=torch.bfloat16,
        attn_implementation="sdpa",   # Windows 上没有 flash-attn，用 sdpa
    )
    load_s = time.time() - t0

    t1 = time.time()
    speaker = None
    if a.mode == "custom":
        speakers = model.get_supported_speakers()
        speaker = a.speaker or ("uncle_fu" if "uncle_fu" in speakers else speakers[0])
        wavs, sr = model.generate_custom_voice(
            text=a.text,
            speaker=speaker,
            language=a.language,
            instruct=a.instruct or "自然、清晰的中文配音，语速平稳",
            max_new_tokens=a.max_new_tokens,
        )
    else:
        wavs, sr = model.generate_voice_design(
            text=a.text,
            instruct=a.instruct or "自然、清晰的中文配音",
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
        "mode": a.mode,
        "model": model_dir,
        "speaker": speaker,
        "sample_rate": int(sr),
        "duration_sec": round(dur, 2),
        "load_sec": round(load_s, 2),
        "gen_sec": round(gen_s, 2),
        "rtf": round(gen_s / dur, 3) if dur > 0 else None,
        "instruct": a.instruct,
        "language": a.language,
    }
    print("音频完成：" + str(out))
    print("RESULT=" + str(out))
    print("META=" + json.dumps(meta, ensure_ascii=False))

    try:
        del model
        torch.cuda.empty_cache()
    except Exception:
        pass


if __name__ == "__main__":
    main()
