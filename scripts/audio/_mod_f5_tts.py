# -*- coding: utf-8 -*-
"""F5-TTS 本地零样本克隆（独立 f5-venv）。

用法：
  python _mod_f5_tts.py --text "要读的内容" --ref ref16k.wav --ref-text "参考音频对应的文字" --out a.wav
说明：torchaudio 用 CPU 版且缺 torchcodec，这里 monkeypatch 成 soundfile 读取。
"""
import argparse
import json
import os
import sys
import time
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
os.environ.setdefault("HF_HOME", r"D:\audio-tools\hf-cache")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", default="")
    ap.add_argument("--text-file", default="")
    ap.add_argument("--ref", required=True)
    ap.add_argument("--ref-text", default="")
    ap.add_argument("--ref-text-file", default="")
    ap.add_argument("--out", required=True)
    ap.add_argument("--speed", type=float, default=1.0)
    ap.add_argument("--pause-ms", type=int, default=0, help="句间停顿毫秒数（>0 时按句合成再拼接）")
    ap.add_argument("--model", default="F5TTS_v1_Base")
    a = ap.parse_args()
    if a.text_file:
        a.text = Path(a.text_file).read_text(encoding="utf-8").strip()
    if a.ref_text_file:
        a.ref_text = Path(a.ref_text_file).read_text(encoding="utf-8").strip()
    if not a.text:
        raise SystemExit("缺少 --text 或 --text-file")
    if not os.path.exists(a.ref):
        raise SystemExit("参考音频不存在：" + a.ref)
    if not a.ref_text:
        # REF_ASR_AUTO：用 align-venv 的 faster-whisper 自动转写参考音频
        import subprocess
        r = subprocess.run([r"D:\audio-tools\align-venv\Scripts\python.exe",
                            r"D:\audio-tools\_ref_asr.py", "--audio", a.ref,
                            "--language", "zh"],
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
        for line in (r.stdout or "").splitlines():
            if line.startswith("TEXT="):
                import json as _json
                a.ref_text = _json.loads(line[5:])
        if not a.ref_text:
            raise SystemExit("参考音频转写失败，请用 --ref-text 指定")
        print("参考文案（自动转写）：" + a.ref_text)

    import numpy as np
    import soundfile as sf
    import torch
    import torchaudio

    def _sf_load(path, **kw):
        data, sr = sf.read(str(path), dtype="float32", always_2d=True)
        wav = torch.from_numpy(data.T)
        if wav.shape[0] > 1:
            wav = wav.mean(0, keepdim=True)
        return wav, sr

    torchaudio.load = _sf_load

    t0 = time.time()
    from f5_tts.api import F5TTS
    f5 = F5TTS(model=a.model, device="cuda")
    load = time.time() - t0

    t1 = time.time()
    sentences = []
    if a.pause_ms > 0:
        import re as _re
        sentences = [x.strip() for x in _re.split(r"(?<=[。！？!?；;])|\n+", a.text) if x.strip()]
    if a.pause_ms > 0 and len(sentences) > 1:
        chunks = []
        sr = 24000
        for sent in sentences:
            w, sr, _ = f5.infer(ref_file=a.ref, ref_text=a.ref_text,
                                gen_text=sent, speed=a.speed,
                                show_info=lambda *x, **k: None)
            arr = w.detach().cpu().numpy() if hasattr(w, "detach") else w
            chunks.append(np.asarray(arr, dtype=np.float32).reshape(-1))
        gap = np.zeros(int(sr * max(0, a.pause_ms) / 1000.0), dtype=np.float32)
        parts = []
        for i, c in enumerate(chunks):
            parts.append(c)
            if i < len(chunks) - 1:
                parts.append(gap)
        wav = np.concatenate(parts)
    else:
        wav, sr, _ = f5.infer(ref_file=a.ref, ref_text=a.ref_text,
                              gen_text=a.text, speed=a.speed,
                              show_info=lambda *x, **k: None)
    gen = time.time() - t1
    wav_np = wav.detach().cpu().numpy() if hasattr(wav, "detach") else wav
    dur = len(wav_np) / sr
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(out), wav_np, sr)
    print("音频完成：" + str(out))
    print("RESULT=" + str(out))
    print("META=" + json.dumps({
        "model": a.model, "sample_rate": sr, "duration_sec": round(dur, 2),
        "load_sec": round(load, 2), "gen_sec": round(gen, 2),
        "rtf": round(gen / max(dur, 0.01), 2),
        "sentences": len(sentences) if a.pause_ms > 0 else 1,
        "pause_ms": a.pause_ms,
        "speed": a.speed,
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
