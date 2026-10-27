# -*- coding: utf-8 -*-
"""CosyVoice2 本地配音（Windows 原生，venv2 + torch cu130）。

绕过 torchaudio.load 的 torchcodec 依赖：用 soundfile 读取参考音频。
用法：
  python _cosy_tts.py --text "台词" --out a.wav --instruct "沉稳男声，语速稍慢" [--reference ref16k.wav]
"""
import argparse
import os
import sys
import time

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

SRC = r"D:\audio-tools\cosyvoice\src\QwenAudio-CosyVoice-074ca6d"
sys.path.insert(0, SRC)
sys.path.insert(0, os.path.join(SRC, "third_party", "Matcha-TTS"))

import numpy as np  # noqa: E402
import soundfile as sf  # noqa: E402
import torch  # noqa: E402
import torch.nn.functional as F  # noqa: E402
import torchaudio  # noqa: E402


def _sf_load(path, **kw):
    """替换 torchaudio.load：torchcodec 在当前 torch 2.12 下 DLL 不兼容。"""
    data, sr = sf.read(str(path), dtype="float32", always_2d=True)
    wav = torch.from_numpy(data.T)
    if sr != 16000:
        wav = F.interpolate(wav.unsqueeze(0), scale_factor=16000.0 / sr,
                            mode="linear", align_corners=False).squeeze(0)
        sr = 16000
    return wav, sr


torchaudio.load = _sf_load

MODEL_DIR = r"D:\audio-tools\cosyvoice\pretrained_models\CosyVoice2-0.5B"
DEFAULT_REF = r"D:\audio-tools\cosyvoice\voices\default_16k.wav"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--instruct", default="")
    ap.add_argument("--reference", default="")
    ap.add_argument("--ref-text", default="")
    ap.add_argument("--speed", type=float, default=1.0)
    ap.add_argument("--model", default=MODEL_DIR)
    a = ap.parse_args()

    ref = a.reference or DEFAULT_REF
    if not os.path.exists(ref):
        raise SystemExit("缺少参考音频：" + ref)

    from cosyvoice.cli.cosyvoice import CosyVoice2

    t0 = time.time()
    m = CosyVoice2(a.model, load_jit=False, load_trt=False, fp16=False)
    load = time.time() - t0
    print("模型加载 %.1f 秒" % load)

    # ZERO_SHOT_FIX：CosyVoice2-0.5B 不支持 instruct2（会把指令念出来），改零样本
    t1 = time.time()
    ref_text = a.ref_text
    if not ref_text:
        import subprocess
        r = subprocess.run([r"D:\audio-tools\align-venv\Scripts\python.exe",
                            r"D:\audio-tools\_ref_asr.py", "--audio", ref, "--language", "zh"],
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
        for line in (r.stdout or "").splitlines():
            if line.startswith("TEXT="):
                import json as _json
                ref_text = _json.loads(line[5:])
    if not ref_text:
        raise SystemExit("参考音频转写失败")
    outs = []
    for out in m.inference_zero_shot(a.text, ref_text, ref, stream=False, speed=a.speed):
        outs.append(out["tts_speech"])
    instruct = a.instruct
    gen = time.time() - t1
    if not outs:
        raise SystemExit("合成没有输出")
    audio = torch.cat(outs, dim=1)
    dur = audio.shape[1] / 24000
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    sf.write(a.out, audio.squeeze(0).detach().cpu().numpy(), 24000)
    print("音频完成：" + a.out)
    print("RESULT=" + a.out)
    import json
    print("META=" + json.dumps({
        "sample_rate": 24000, "duration_sec": round(dur, 2),
        "load_sec": round(load, 2), "gen_sec": round(gen, 2),
        "rtf": round(gen / max(dur, 0.01), 2), "instruct": instruct,
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
