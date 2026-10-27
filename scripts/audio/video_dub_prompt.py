# -*- coding: utf-8 -*-
"""Video -> local vision understanding -> dubbing prompt -> optional audio workbench auto-dub."""
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

DESKTOP = Path(os.path.expanduser("~")) / "Desktop"
VIDEO_DIR = DESKTOP / "视频"
AUDIO_TOOLS = Path(r"D:\audio-tools")
WORKBENCH = AUDIO_TOOLS / "音频工作台"
FFMPEG = r"D:\tools\ffmpeg\bin\ffmpeg.exe"
FFPROBE = r"D:\tools\ffmpeg\bin\ffprobe.exe"
OLLAMA = "http://127.0.0.1:11434"
VISION_MODEL = "qwen3-vl:8b"
TEXT_MODEL = "qwen3.5:9b"


def probe_duration(video):
    try:
        p = subprocess.run(
            [FFPROBE, "-v", "error", "-show_entries", "format=duration",
             "-of", "default=nw=1:nk=1", str(video)],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30)
        return float((p.stdout or "0").strip())
    except Exception:
        return 0.0


def extract_frames(video, folder):
    folder.mkdir(parents=True, exist_ok=True)
    duration = probe_duration(video)
    times = [duration * 0.15, duration * 0.5, duration * 0.85] if duration > 0 else [0.0]
    paths = []
    for idx, ts in enumerate(times, 1):
        out = folder / f"frame-{idx:02d}.jpg"
        p = subprocess.run(
            [FFMPEG, "-y", "-ss", f"{max(0.0, ts):.2f}", "-i", str(video),
             "-frames:v", "1", "-vf", "scale=512:-1", str(out)],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120)
        if out.exists():
            paths.append(out)
    return paths


def ollama_chat(model, messages, timeout=600):
    payload = {
        "model": model,
        "messages": messages,
        "stream": False,
        "keep_alive": "2m", "think": False,
        "options": {"temperature": 0.2, "num_predict": 800},
    }
    req = urllib.request.Request(
        OLLAMA + "/api/chat",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = json.loads(r.read().decode("utf-8"))
    return (data.get("message") or {}).get("content", "")


def unload(model):
    try:
        payload = {"model": model, "keep_alive": 0}
        req = urllib.request.Request(
            OLLAMA + "/api/generate",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        urllib.request.urlopen(req, timeout=15).read()
    except Exception:
        pass


def parse_json_object(text):
    try:
        m = re.search(r"\{.*\}", text, re.S)
        return json.loads(m.group(0)) if m else {}
    except Exception:
        return {}


def build_prompt(video, user_prompt, out_dir):
    duration = probe_duration(video)
    video_dir = out_dir / f"video-dub-prompt-{time.strftime('%Y%m%d-%H%M%S')}"
    video_dir.mkdir(parents=True, exist_ok=True)
    frames = extract_frames(video, video_dir / "frames")
    if not frames:
        raise RuntimeError("无法从视频抽帧")
    images = [base64.b64encode(p.read_bytes()).decode("ascii") for p in frames]
    vision_system = (
        "你是视频画面分析助手。看给定的关键帧，输出严格 JSON："
        "summary（画面内容）、subjects（主体/动作）、setting（场景）、mood（氛围）、"
        "suggested_voice（适合的旁白音色）、suggested_narration（建议旁白内容）。"
        "只输出 JSON，不要 Markdown。"
    )
    vision_user = (
        f"这是一个约 {duration:.1f} 秒的视频的关键帧。"
        "请分析画面，供后续写配音旁白使用。"
        + (f"用户额外要求：{user_prompt}" if user_prompt else "")
    )
    try:
        vision_raw = ollama_chat(
            VISION_MODEL,
            [{"role": "system", "content": vision_system},
             {"role": "user", "content": vision_user, "images": images}],
        )
    finally:
        unload(VISION_MODEL)
    vision = parse_json_object(vision_raw)
    if not vision:
        vision = {"summary": vision_raw[:1000]}
    (video_dir / "vision.json").write_text(
        json.dumps(vision, ensure_ascii=False, indent=2), encoding="utf-8")

    text_system = (
        "你是视频配音策划。根据画面分析和用户要求，写一段可以直接粘贴到音频工作台的配音提示词。"
        "提示词必须包含：旁白内容（具体可朗读的文案）、音色、语速、情绪/语气、字幕要求。"
        "只输出提示词正文，不要 JSON、Markdown、解释或前后缀。"
        "旁白长度要匹配视频时长，约为每秒 4 到 5 个汉字。"
    )
    text_user = (
        f"视频时长约 {duration:.1f} 秒。\n"
        f"画面分析：{json.dumps(vision, ensure_ascii=False)}\n"
        f"用户要求：{user_prompt or '无，按画面自动决定'}"
    )
    try:
        dub_prompt = ollama_chat(
            TEXT_MODEL,
            [{"role": "system", "content": text_system},
             {"role": "user", "content": text_user}],
        ).strip()
    finally:
        unload(TEXT_MODEL)
    if not dub_prompt:
        raise RuntimeError("本地 Qwen 没有生成配音提示词")
    prompt_file = video_dir / "配音提示词.txt"
    prompt_file.write_text(dub_prompt + "\n", encoding="utf-8")
    return video_dir, frames, vision, dub_prompt, prompt_file


def auto_dub(video, prompt, reference, language, burn, pitch, formant, tone, engine="auto", speaker="", voice="", keep_original=False):
    sys.path.insert(0, str(WORKBENCH))
    from desktop_backend import AudioBackend
    backend = AudioBackend()
    return backend.prompt_dub(
        str(video), prompt, reference or "", language, bool(burn),
        float(pitch), formant, tone, engine, speaker, voice, keep_original)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", required=True)
    ap.add_argument("--prompt", default="")
    ap.add_argument("--mode", choices=["prompt", "auto"], default="prompt")
    ap.add_argument("--reference", default="")
    ap.add_argument("--language", default="zh")
    ap.add_argument("--burn-subtitles", action="store_true")
    ap.add_argument("--pitch", type=float, default=0.0)
    ap.add_argument("--formant", choices=["preserved", "shifted"], default="preserved")
    ap.add_argument("--tone", choices=["original", "bright", "warm"], default="original")
    ap.add_argument("--engine", choices=["auto", "kokoro", "chatterbox", "cosyvoice", "qwen",
                                         "qwen-fast", "seedvc", "cosyvoice+seedvc"], default="auto")
    ap.add_argument("--speaker", default="", help="Qwen CustomVoice 音色，如 uncle_fu/serena")
    ap.add_argument("--voice", default="", help="声音库角色名，如 阮梅；自动解析参考音并用 F5 克隆")
    ap.add_argument("--keep-original", action="store_true", help="保留原视频音轨并压到 25% 与配音混合")
    args = ap.parse_args()

    video = Path(args.video)
    if not video.is_file():
        raise SystemExit(f"视频不存在：{video}")
    video_dir, frames, vision, dub_prompt, prompt_file = build_prompt(
        video, args.prompt.strip(), VIDEO_DIR)
    manifest = {
        "video": str(video),
        "duration": probe_duration(video),
        "mode": args.mode,
        "engine": args.engine,
        "frames": [str(p) for p in frames],
        "vision": vision,
        "dub_prompt": dub_prompt,
        "prompt_file": str(prompt_file),
        "auto_dub": None,
    }
    print(f"提示词文件：{prompt_file}")
    print("配音提示词：")
    print(dub_prompt)
    if args.mode == "auto":
        result = auto_dub(video, dub_prompt, args.reference, args.language,
                          args.burn_subtitles, args.pitch, args.formant, args.tone,
                          args.engine, args.speaker, args.voice, args.keep_original)
        manifest["auto_dub"] = result
        # 时长校验（2026-10-26 加）：配音比视频长会被截断，明显短会留白
        try:
            _auds = [p for p in result.get("files", [])
                     if str(p).lower().endswith((".wav", ".mp3", ".flac", ".m4a"))]
            _vdur = manifest.get("duration") or probe_duration(video)
            if _auds and _vdur > 0:
                _adur = probe_duration(_auds[0])
                _fit = {"video_duration": round(_vdur, 2),
                        "audio_duration": round(_adur, 2),
                        "delta": round(_adur - _vdur, 2)}
                if _adur > _vdur + 0.8:
                    _fit["warning"] = "audio_longer_than_video"
                    print(f"警告：配音比视频长 {_adur - _vdur:.1f} 秒，封装时尾部会被截断；建议缩短文案或降低语速。")
                elif _adur < _vdur * 0.7:
                    _fit["warning"] = "audio_shorter_than_video"
                    print(f"警告：配音明显短于视频（{_adur:.1f}s vs {_vdur:.1f}s），会有较长留白。")
                manifest["duration_fit"] = _fit
        except Exception as _exc:
            print(f"提示：时长校验跳过（{_exc}）")
        (video_dir / "result.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        print("\n自动配音日志：")
        print(result.get("log", ""))
        for p in result.get("files", []):
            print(f"视频完成：{p}")
            print(f"RESULT={p}")
        if not result.get("files"):
            print("自动配音失败（见上方日志）")
            print("auto_dub_failed")
            sys.exit(2)
    (video_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n任务目录：{video_dir}")


EXIT_ON_DUB_FAIL = True

if __name__ == "__main__":
    main()
