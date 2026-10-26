# -*- coding: utf-8 -*-
"""Image -> vision -> narration -> TTS -> still-image video (with optional burned subtitles)."""
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
import argparse, base64, json, os, re, subprocess, sys, time, urllib.request
from pathlib import Path

DESKTOP = Path(os.path.expanduser("~")) / "Desktop"
VIDEO_DIR = DESKTOP / "视频"
WB = Path(r"D:\audio-tools\音频工作台")
FFMPEG = r"D:\tools\ffmpeg\bin\ffmpeg.exe"
FFPROBE = r"D:\tools\ffmpeg\bin\ffprobe.exe"
OLLAMA = "http://127.0.0.1:11434"
VISION_MODEL = "qwen3-vl:8b"
TEXT_MODEL = "qwen3.5:9b"
KOKORO_VOICES = {}  # filled from backend

def ollama_chat(model, messages, timeout=600):
    payload = {"model": model, "messages": messages, "stream": False, "keep_alive": "2m", "think": False,
               "options": {"temperature": 0.3, "num_predict": 800}}
    req = urllib.request.Request(OLLAMA + "/api/chat",
                                data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                                headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return (json.loads(r.read().decode("utf-8")).get("message") or {}).get("content", "")

def unload(model):
    try:
        req = urllib.request.Request(OLLAMA + "/api/generate",
                                     data=json.dumps({"model": model, "keep_alive": 0}).encode(),
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=15).read()
    except Exception:
        pass

def probe_duration(path):
    try:
        p = subprocess.run([FFPROBE, "-v", "error", "-show_entries", "format=duration",
                            "-of", "default=nw=1:nk=1", str(path)],
                           capture_output=True, text=True, timeout=30)
        return float((p.stdout or "0").strip())
    except Exception:
        return 0.0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--prompt", default="")
    ap.add_argument("--seconds", type=float, default=8)
    ap.add_argument("--voice", default="")
    ap.add_argument("--language", default="zh")
    ap.add_argument("--burn-subtitles", action="store_true")
    ap.add_argument("--speed", type=float, default=1.0)
    a = ap.parse_args()
    img = Path(a.image)
    if not img.is_file():
        raise SystemExit(f"图片不存在：{img}")
    b64 = base64.b64encode(img.read_bytes()).decode("ascii")
    vision_sys = ("你是画面分析助手。看这张图，输出严格 JSON：summary、subjects、setting、mood、"
                  "suggested_narration（一句可直接朗读的中文旁白，20~40 字）。只输出 JSON。")
    try:
        raw = ollama_chat(VISION_MODEL, [{"role": "system", "content": vision_sys},
                                         {"role": "user", "content": "分析这张图，供配旁白使用。", "images": [b64]}])
    finally:
        unload(VISION_MODEL)
    m = re.search(r"\{.*\}", raw, re.S)
    try:
        vision = json.loads(m.group(0)) if m else {}
    except Exception:
        vision = {}
    narration = str(vision.get("suggested_narration") or "").strip()
    if not narration:
        narration = str(vision.get("summary") or "画面平静，适合舒缓旁白。")[:80]
    text_sys = ("你是视频旁白策划。根据画面信息与用户要求，写一段可直接朗读的中文旁白。/no_think"
                "只输出旁白正文，不要引号、标题或解释。旁白长度约为每秒 4 到 5 个汉字。")
    user = f"目标时长约 {a.seconds:.0f} 秒。画面：{json.dumps(vision, ensure_ascii=False)}\n用户要求：{a.prompt or '无'}"
    try:
        script = ollama_chat(TEXT_MODEL, [{"role": "system", "content": text_sys},
                                          {"role": "user", "content": user}]).strip()
    finally:
        unload(TEXT_MODEL)
    if not script:
        script = narration
    sys.path.insert(0, str(WB))
    from desktop_backend import AudioBackend, KOKORO_VOICES as KV
    be = AudioBackend()
    voice = a.voice or "zf_001"
    if KV and voice not in KV:
        voice = next(iter(KV))
    r = be.tts(script, voice, float(a.speed))
    auds = [p for p in r.get("files", []) if str(p).lower().endswith((".wav", ".mp3", ".flac"))]
    if not auds:
        print(r.get("log", "TTS 失败"))
        raise SystemExit(1)
    audio = Path(auds[0])
    adur = probe_duration(audio)
    VIDEO_DIR.mkdir(parents=True, exist_ok=True)
    n = 0
    for p in VIDEO_DIR.glob("video-*.mp4"):
        mm = re.match(r"^video-(\d{4,})-", p.name)
        if mm:
            n = max(n, int(mm.group(1)))
    out = VIDEO_DIR / f"video-{n + 1:04d}-imgdub-{time.strftime('%Y%m%d-%H%M%S')}.mp4"
    srt = None
    if a.burn_subtitles:
        try:
            r2 = be.align(str(audio), script, None, a.language)
            if r2 and r2.get("files"):
                for fp in r2["files"]:
                    if str(fp).lower().endswith(".srt"):
                        srt = fp
                        break
        except Exception as exc:
            print(f"字幕对齐失败（不烧录）：{exc}")
    vf = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    if srt:
        # 中文字幕路径 ffmpeg 滤镜不认，复制到 ASCII 临时路径再烧
        import shutil as _sh
        tmp_srt = Path(r"D:\audio-tools\gen-out\_imgdub_sub.srt")
        tmp_srt.parent.mkdir(parents=True, exist_ok=True)
        _sh.copyfile(srt, tmp_srt)
        vf += rf",subtitles='D\:/audio-tools/gen-out/_imgdub_sub.srt'"
    cmd = [FFMPEG, "-y", "-loop", "1", "-i", str(img), "-i", str(audio),
           "-vf", vf, "-c:v", "libx264", "-tune", "stillimage",
           "-pix_fmt", "yuv420p", "-shortest", "-c:a", "aac", "-b:a", "192k",
           str(out)]
    p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if not out.exists():
        print(p.stderr[-2000:])
        raise SystemExit("视频封装失败")
    print(f"旁白（{script}）")
    print(f"配音时长 {adur:.1f}s / 目标 {a.seconds:.0f}s")
    print("视频完成：" + str(out))
    print("RESULT=" + str(out))

if __name__ == "__main__":
    main()