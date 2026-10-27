# -*- coding: utf-8 -*-
"""AudioSep CLI: language-queried audio separation.

用法：
  python _audiosep_infer.py --input mix.wav --text "vocals" --out out.wav [--device cuda]
"""
import argparse
import os
import sys
import time

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

SRC = r"D:\audio-tools\audiosep-src"
os.chdir(SRC)
sys.path.insert(0, SRC)
os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--text", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--ckpt", default="checkpoint/audiosep_base_4M_steps.ckpt")
    ap.add_argument("--config", default="config/audiosep_base.yaml")
    a = ap.parse_args()

    import torch
    from pipeline import build_audiosep, separate_audio

    t0 = time.time()
    model = build_audiosep(config_yaml=a.config, checkpoint_path=a.ckpt, device=a.device)
    load = time.time() - t0
    t1 = time.time()
    separate_audio(model, a.input, a.text, a.out, a.device)
    gen = time.time() - t1
    print("音频完成：" + a.out)
    print("RESULT=" + a.out)
    import json
    print("META=" + json.dumps({"load_sec": round(load, 2), "sep_sec": round(gen, 2),
                                "query": a.text, "device": a.device}, ensure_ascii=False))


if __name__ == "__main__":
    main()
