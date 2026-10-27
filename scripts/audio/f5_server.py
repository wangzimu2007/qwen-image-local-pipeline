# -*- coding: utf-8 -*-
"""F5-TTS 常驻服务：模型只加载一次，通过本地 TCP 接受合成请求。

启动（f5-venv）：
  python f5_server.py --port 8766 --idle 600
协议：每行一个 JSON 请求/响应。
请求：{"ref": "...", "ref_text": "", "text": "...", "out": "...", "speed": 1.0, "pause_ms": 0}
响应：{"ok": true, "out": "...", "duration": 3.9, "gen_sec": 2.1, "load_sec": 0}
"""
import argparse
import json
import os
import re
import socket
import subprocess
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


def _sf_load(path, **kw):
    import soundfile as sf
    import torch
    data, sr = sf.read(str(path), dtype="float32", always_2d=True)
    wav = torch.from_numpy(data.T)
    if wav.shape[0] > 1:
        wav = wav.mean(0, keepdim=True)
    return wav, sr


_REF_CACHE = {}


def ref_text_for(path):
    try:
        key = (str(path), Path(path).stat().st_mtime_ns)
        if key in _REF_CACHE:
            return _REF_CACHE[key]
    except Exception:
        key = None
    try:
        r = subprocess.run(
            [r"D:\audio-tools\align-venv\Scripts\python.exe", r"D:\audio-tools\_ref_asr.py",
             "--audio", str(path), "--language", "zh"],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=300)
        for line in (r.stdout or "").splitlines():
            if line.startswith("TEXT="):
                text = json.loads(line[5:])
                if key is not None and text:
                    _REF_CACHE[key] = text
                return text
    except Exception:
        pass
    return ""


def synth(f5, np, sf, req):
    import time as _t
    t0 = _t.time()
    ref = str(req.get("ref", ""))
    text = str(req.get("text", "")).strip()
    out = str(req.get("out", ""))
    speed = float(req.get("speed", 1.0) or 1.0)
    pause_ms = int(req.get("pause_ms", 0) or 0)
    ref_text = str(req.get("ref_text", "") or "")
    if not ref or not text or not out:
        return {"ok": False, "error": "缺少 ref/text/out"}
    if not Path(ref).exists():
        return {"ok": False, "error": "参考音频不存在：" + ref}
    if not ref_text:
        ref_text = ref_text_for(ref)
    if not ref_text:
        return {"ok": False, "error": "参考音频转写失败"}
    sentences = []
    if pause_ms > 0:
        sentences = [x.strip() for x in re.split(r"(?<=[。！？!?；;])|\n+", text) if x.strip()]
    if pause_ms > 0 and len(sentences) > 1:
        chunks = []
        sr = 24000
        for sent in sentences:
            w, sr, _ = f5.infer(ref_file=ref, ref_text=ref_text, gen_text=sent,
                                speed=speed, show_info=lambda *a, **k: None)
            arr = w.detach().cpu().numpy() if hasattr(w, "detach") else w
            chunks.append(np.asarray(arr, dtype=np.float32).reshape(-1))
        gap = np.zeros(int(sr * pause_ms / 1000.0), dtype=np.float32)
        parts = []
        for i, c in enumerate(chunks):
            parts.append(c)
            if i < len(chunks) - 1:
                parts.append(gap)
        wav = np.concatenate(parts)
    else:
        wav, sr, _ = f5.infer(ref_file=ref, ref_text=ref_text, gen_text=text,
                              speed=speed, show_info=lambda *a, **k: None)
        wav = wav.detach().cpu().numpy() if hasattr(wav, "detach") else wav
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    sf.write(out, wav, sr)
    gen = _t.time() - t0
    return {"ok": True, "out": out, "duration": round(len(wav) / sr, 2),
            "sr": sr, "gen_sec": round(gen, 2), "sentences": len(sentences) if pause_ms > 0 else 1}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8766)
    ap.add_argument("--idle", type=int, default=600)
    ap.add_argument("--model", default="F5TTS_v1_Base")
    a = ap.parse_args()

    import numpy as np
    import soundfile as sf
    import torch
    import torchaudio
    torchaudio.load = _sf_load

    t0 = time.time()
    from f5_tts.api import F5TTS
    f5 = F5TTS(model=a.model, device="cuda")
    load_sec = time.time() - t0
    print(f"READY port={a.port} load_sec={load_sec:.1f}", flush=True)

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind(("127.0.0.1", a.port))
    except OSError:
        print("BIND_FAILED（已有服务在跑）", flush=True)
        return 0
    srv.listen(4)
    srv.settimeout(5)
    last = time.time()
    while True:
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            if time.time() - last > a.idle:
                print("IDLE_EXIT", flush=True)
                return 0
            continue
        with conn:
            try:
                conn.settimeout(3600)
                data = b""
                while not data.endswith(b"\n"):
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                req = json.loads(data.decode("utf-8"))
                last = time.time()
                resp = synth(f5, np, sf, req)
            except Exception as exc:
                resp = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
            conn.sendall((json.dumps(resp, ensure_ascii=False) + "\n").encode("utf-8"))
            last = time.time()


if __name__ == "__main__":
    sys.exit(main())
