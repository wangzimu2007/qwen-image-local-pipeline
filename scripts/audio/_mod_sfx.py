# -*- coding: utf-8 -*-
"""Text-to-audio (SFX/BGM) using Stable Audio Open or AudioLDM2, whichever is installed."""
import argparse, os, sys, time
from pathlib import Path

ROOT = Path(r"D:\audio-tools")
SA_DIR = ROOT / "sa-model"
ALD_DIR = ROOT / "audioldm2-model"
OUT_DEFAULT = ROOT / "gen-out"

def gen_stable_audio(prompt, seconds, out_dir):
    import torch, torchaudio
    from stable_audio_tools import get_pretrained_model
    from stable_audio_tools.inference.generation import generate_diffusion_cond
    model, cfg = get_pretrained_model(str(SA_DIR))
    model = model.to("cuda").eval()
    sample_rate = cfg["sample_rate"]
    sample_size = int(cfg["sample_size"])
    steps = 100
    cond = [{"prompt": prompt, "seconds_start": 0, "seconds_total": max(1, int(seconds))}]
    audio = generate_diffusion_cond(
        model, steps=steps, cfg_scale=7, conditioning=cond,
        sample_size=sample_size, sigma_min=0.3, sigma_max=500,
        sampler_type="dpmpp-3m-sde", device="cuda")
    audio = audio.reshape(-1, audio.shape[-1])[:, : sample_size]
    out = out_dir / f"sfx-{time.strftime('%Y%m%d-%H%M%S')}.wav"
    torchaudio.save(str(out), audio.detach().cpu(), sample_rate)
    return out, sample_rate

def gen_audioldm2(prompt, seconds, out_dir):
    import torch, torchaudio
    from audioldm2 import text_to_audio, build_model, save_wave
    model = build_model(ckpt_path=str(ALD_DIR / "audioldm2-full.pth"), model_name="audioldm2-full",
                        device="cuda", config=None)
    wave = text_to_audio(model, prompt, duration=max(2.5, float(seconds)), batchsize=1,
                         guidance_scale=3.5, seed=0, n_candidate_gen_per_text=1)
    out = out_dir / f"sfx-{time.strftime('%Y%m%d-%H%M%S')}.wav"
    save_wave(wave, str(out))
    return out, 16000

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--seconds", type=float, default=8)
    ap.add_argument("--out", default=str(OUT_DEFAULT))
    a = ap.parse_args()
    out_dir = Path(a.out); out_dir.mkdir(parents=True, exist_ok=True)
    errors = []
    for name, fn in (("stable-audio", gen_stable_audio), ("audioldm2", gen_audioldm2)):
        try:
            out, sr = fn(a.prompt, a.seconds, out_dir)
            print(f"生成器：{name} / 采样率 {sr}")
            print("音频完成：" + str(out))
            return
        except Exception as exc:
            errors.append(f"{name}: {exc}")
    print("所有生成器都失败：\n" + "\n".join(errors))
    raise SystemExit(1)

if __name__ == "__main__":
    main()