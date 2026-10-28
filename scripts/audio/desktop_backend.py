# -*- coding: utf-8 -*-
"""Audio workbench native backend: same scripts and VRAM gate as the Gradio app."""
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.request
from pathlib import Path

DESKTOP = Path(os.path.expanduser("~")) / "Desktop"
AUDIO = DESKTOP / "音频"
TEXT = AUDIO / "文字稿"
MIDI = AUDIO / "MIDI"
VIDEO = DESKTOP / "视频"
COMFY_OUT = DESKTOP / "ComfyUI 输出"
TOOLS = Path(r"D:\audio-tools")
QROOT = Path(r"D:\qwen-image-2.1")
PIPE = QROOT / "流水线.ps1"
VRAM_GATE = TOOLS / "音频显存门禁.ps1"
PS = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
FFMPEG = r"D:\tools\ffmpeg\bin\ffmpeg.exe"
FFPROBE = r"D:\tools\ffmpeg\bin\ffprobe.exe"
CFG = Path(os.path.expanduser("~")) / ".dsh" / "profiles" / "desktop" / "cordis.patch.yml"
OLLAMA = "http://127.0.0.1:11434"
TRANSLATE_MODEL = "qwen3.5:9b"
MASTER_PS = TOOLS / "母带匹配.ps1"
AUDIO_MODULE = TOOLS / "音频模块.ps1"
COLLECT = TOOLS / "游戏语音采集"
COLLECT_PS = COLLECT / "游戏语音采集.ps1"
COLLECT_PY = COLLECT / "venv" / "Scripts" / "python.exe"
SCAN_GAME = COLLECT / "扫描游戏.py"
WEB_AUDIO_PS = COLLECT / "网页视频转音频.ps1"
VOICE_ROOT = Path(r"C:\音频素材")
VOICE_LIBRARY = VOICE_ROOT / "voices.json"
KOKORO_VOICES = {
    "zf_001": "温柔女声",
    "zf_002": "沉稳女声",
    "zf_003": "年轻女声",
    "zm_009": "沉稳男声",
    "zm_010": "年轻男声",
}

AUDIO_EXTS = {".wav", ".mp3", ".flac", ".m4a", ".ogg", ".opus", ".aac"}
RESULT_EXTS = AUDIO_EXTS | {".srt", ".txt", ".json", ".mid", ".midi"}
VIDEO_EXTS = {".mp4", ".mov", ".mkv", ".webm", ".avi"}

VRAM_WHISPER = 5000
VRAM_DENOISE = 6000
VRAM_SEPARATE = 6000
VRAM_SR = 8000
VRAM_CLONE = 8000
VRAM_PIPELINE = 12000

ANSI = re.compile(r"\x1B\[[0-?]*[ -/]*[@-~]")


def clean(s: str) -> str:
    return ANSI.sub("", s or "").replace("\r", "")


def new_files(folder: Path, start: float, exts=None):
    exts = exts or RESULT_EXTS
    if not folder.exists():
        return []
    out = []
    for p in folder.rglob("*"):
        try:
            if p.is_file() and p.suffix.lower() in exts and p.stat().st_mtime >= start - 2:
                out.append(p)
        except OSError:
            pass
    return sorted(out, key=lambda p: p.stat().st_mtime)


def latest(folder: Path, patterns):
    if not folder.exists():
        return []
    hits = []
    for pat in patterns:
        hits += [p for p in folder.rglob(pat) if p.is_file() and p.suffix.lower() in RESULT_EXTS]
    return sorted(set(hits), key=lambda p: p.stat().st_mtime, reverse=True)


def files_out(paths):
    uniq, seen = [], set()
    for p in paths or []:
        p = Path(p)
        if p.exists() and str(p) not in seen:
            uniq.append(str(p))
            seen.add(str(p))
    return uniq


def product_of(log: str):
    """取日志里的成品路径；支持成品/视频完成/音频完成/RESULT= 等，优先最后一条存在的。"""
    patterns = [
        r"(?:成品|视频完成|音频完成|编辑完成|超分完成|输出文件|结果文件|输出|产物)[：:]\s*(.+?\.(?:png|jpg|jpeg|webp|mp4|mov|mkv|srt|wav|mp3|flac|m4a))",
        r"RESULT=([^\s\"']+\.(?:png|jpg|jpeg|webp|mp4|mov|mkv|srt|wav|mp3|flac|m4a))",
    ]
    found = []
    for rx in patterns:
        for m in re.finditer(rx, log or "", re.IGNORECASE):
            p = Path(m.group(1).strip().strip('"'))
            if p.exists():
                found.append(p)
    return found[-1] if found else None


class AudioBackend:
    def __init__(self):
        self.lock = threading.Lock()
        self.active = 0
        self.last_activity = time.time()

    def touch(self):
        with self.lock:
            self.last_activity = time.time()

    def begin(self):
        with self.lock:
            self.active += 1
            self.last_activity = time.time()

    def end(self):
        with self.lock:
            self.active = max(0, self.active - 1)
            self.last_activity = time.time()

    def is_busy(self):
        with self.lock:
            return self.active > 0

    def _run_inner(self, script, args, timeout=3600, vram_mb=0, allow_self_unload=False):
        script = Path(script)
        if not script.exists():
            return 1, f"缺少脚本：{script}"
        tmp = None
        if vram_mb > 0:
            if not VRAM_GATE.exists():
                return 1, f"缺少显存门禁脚本：{VRAM_GATE}"
            job = {
                "script": str(script),
                "args": [str(a) for a in args],
                "needMiB": int(vram_mb),
                "allowSelfUnload": bool(allow_self_unload),
            }
            fd, tmp = tempfile.mkstemp(prefix="dsh-audio-vram-", suffix=".json")
            os.close(fd)
            Path(tmp).write_text(json.dumps(job, ensure_ascii=False), encoding="utf-8-sig")
            cmd = [PS, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(VRAM_GATE), "-Job", tmp]
            run_timeout = timeout + 900
        else:
            cmd = [PS, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script)] + [str(a) for a in args]
            run_timeout = timeout
        env = os.environ.copy()
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONUTF8"] = "1"
        env["HF_HUB_DISABLE_XET"] = "1"
        env["HF_ENDPOINT"] = "https://hf-mirror.com"
        env["PATH"] = r"D:\tools\ffmpeg\bin;" + env.get("PATH", "")
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                               errors="replace", timeout=run_timeout, env=env)
            return p.returncode, clean((p.stdout or "") + "\n" + (p.stderr or ""))
        except subprocess.TimeoutExpired:
            return 124, f"超时（{run_timeout} 秒）：{script.name}"
        finally:
            if tmp:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass

    def run(self, script, args, timeout=3600, vram_mb=0, allow_self_unload=False):
        self.begin()
        try:
            return self._run_inner(script, args, timeout=timeout, vram_mb=vram_mb,
                                   allow_self_unload=allow_self_unload)
        finally:
            self.end()

    def _collect(self, script, args, folder, start, patterns, timeout=3600, vram_mb=0):
        code, log = self.run(script, args, timeout=timeout, vram_mb=vram_mb, allow_self_unload=bool(vram_mb))
        product = product_of(log)
        paths = []
        if product:
            paths.append(product)
        # 只用本次任务开始后新生成的文件，避免把历史文件当成本次产物
        if code == 0:
            paths += [p for p in new_files(folder, start) if p not in paths][:6]
        return {"log": log + f"\n\n退出码：{code}", "files": files_out(paths),
                "preview": None, "ok": code == 0}

    def subtitle(self, file, model, language, formats):
        p = Path(file)
        key = "-Video" if p.suffix.lower() in VIDEO_EXTS else "-Audio"
        start = time.time()
        r = self._collect(TOOLS / "录音转字幕.ps1",
                          [key, str(p), "-Model", model, "-Language", language,
                           "-Formats", formats, "-NoPause"],
                          TEXT, start, ["*.srt", "*.txt", "*.json"], 2400, VRAM_WHISPER)
        if not r["files"]:
            r["files"] = files_out(new_files(AUDIO, start))
        return r

    def split(self, audio):
        start = time.time()
        return self._collect(TOOLS / "分离音频.ps1", ["-Audio", audio, "-NoPause"],
                             AUDIO, start, ["audio-*-stems-*"], 2400, VRAM_SEPARATE)

    def denoise(self, audio, enhance=False):
        start = time.time()
        args = ["-Audio", audio, "-NoPause"] + (["-Enhance"] if enhance else [])
        return self._collect(TOOLS / "降噪增强.ps1", args, AUDIO, start,
                             ["audio-*-enhanced-*"], 2400, VRAM_DENOISE)

    def sr(self, audio, steps):
        start = time.time()
        return self._collect(TOOLS / "音频超分.ps1", ["-Audio", audio, "-Steps", int(steps), "-NoPause"],
                             AUDIO, start, ["audio-*-audiosr-*"], 2400, VRAM_SR)

    def clone(self, ref, text, language, speed=1.0, pause_ms=0, engine="f5"):
        start = time.time()
        if engine == "chatterbox":
            return self._collect(TOOLS / "声音克隆.ps1",
                                 ["-Reference", ref, "-Text", text, "-Language", language, "-NoPause"],
                                 AUDIO, start, ["audio-*-ttsclone-*"], 2400, VRAM_CLONE)
        AUDIO.mkdir(parents=True, exist_ok=True)
        out = AUDIO / ("audio-clone-" + time.strftime("%Y%m%d-%H%M%S") + "-f5.wav")
        clean_text = (text or "").replace(";", "，")
        params = ("Text=" + clean_text + ";Reference=" + str(ref) +
                  ";Language=" + str(language) + ";Speed=" + ("%.2f" % float(speed)))
        if int(pause_ms or 0) > 0:
            params += ";PauseMs=" + str(int(pause_ms))
        try:
            audio, log = self._audio_module("clone", None, out, params, timeout=2400)
            return {"log": log + "\n\n音频完成：" + audio, "files": [audio], "preview": audio}
        except Exception as exc:
            r = self._collect(TOOLS / "声音克隆.ps1",
                              ["-Reference", ref, "-Text", text, "-Language", language, "-NoPause"],
                              AUDIO, start, ["audio-*-ttsclone-*"], 2400, VRAM_CLONE)
            r["log"] = "F5 克隆失败，回退 Chatterbox：" + str(exc) + "\n" + r.get("log", "")
            return r

    def tts(self, text, voice, speed=1.0):
        start = time.time()
        return self._collect(r"D:\speech\语音合成.ps1",
                             ["-Text", text, "-Voice", voice, "-Speed", f"{speed:.2f}", "-NoPause"],
                             AUDIO, start, ["audio-*-tts-*"], 1200, 0)

    def diarize(self, audio):
        start = time.time()
        return self._collect(TOOLS / "说话人分离.ps1", ["-Audio", audio, "-NoPause"],
                             TEXT, start, ["*.txt", "*.srt", "*.json"], 1800, 0)

    def midi(self, audio):
        start = time.time()
        return self._collect(TOOLS / "音频转MIDI.ps1", ["-Audio", audio, "-NoPause"],
                             MIDI, start, ["*.mid", "*.midi"], 2400, 0)

    def pipeline(self, audio, preset, language):
        start = time.time()
        logs, outputs = [], []
        if preset == "完整音频链：分离 + 降噪 + 字幕 + MIDI":
            code, log = self.run(PIPE, ["-Recipe", "音频处理链", "-Set",
                                         f"Audio={audio};Language={language}", "-NoPause"],
                                 timeout=3600, vram_mb=VRAM_PIPELINE, allow_self_unload=True)
            logs.append(log)
            m = re.search(r"任务目录[：:]\s*(.+?)(?:\r?\n|$)", log)
            task = Path(m.group(1).strip()) if m else None
            if task and task.exists():
                outputs += [p for p in task.rglob("*") if p.is_file() and p.suffix.lower() in RESULT_EXTS]
                outputs.append(task / "manifest.json")
            outputs += new_files(AUDIO, start) + new_files(TEXT, start) + new_files(MIDI, start)
        elif preset == "降噪 + 字幕":
            code, log = self.run(TOOLS / "降噪增强.ps1", ["-Audio", audio, "-NoPause"],
                                 timeout=1800, vram_mb=VRAM_DENOISE, allow_self_unload=True)
            logs.append(log)
            p = product_of(log) or next(iter(latest(AUDIO, ["audio-*-enhanced-*"])), None)
            if p:
                code2, log2 = self.run(TOOLS / "录音转字幕.ps1",
                                       ["-Audio", str(p), "-Language", language, "-NoPause"],
                                       timeout=1800, vram_mb=VRAM_WHISPER, allow_self_unload=True)
                logs.append(log2)
            outputs += new_files(AUDIO, start) + new_files(TEXT, start)
        elif preset == "超分 + 字幕":
            code, log = self.run(TOOLS / "音频超分.ps1", ["-Audio", audio, "-NoPause"],
                                 timeout=1800, vram_mb=VRAM_SR, allow_self_unload=True)
            logs.append(log)
            p = product_of(log) or next(iter(latest(AUDIO, ["audio-*-audiosr-*"])), None)
            if p:
                code2, log2 = self.run(TOOLS / "录音转字幕.ps1",
                                       ["-Audio", str(p), "-Language", language, "-NoPause"],
                                       timeout=1800, vram_mb=VRAM_WHISPER, allow_self_unload=True)
                logs.append(log2)
            outputs += new_files(AUDIO, start) + new_files(TEXT, start)
        elif preset == "说话人分离 + 字幕":
            code1, log1 = self.run(TOOLS / "说话人分离.ps1", ["-Audio", audio, "-NoPause"], timeout=1200)
            code2, log2 = self.run(TOOLS / "录音转字幕.ps1",
                                   ["-Audio", audio, "-Language", language, "-NoPause"],
                                   timeout=1800, vram_mb=VRAM_WHISPER, allow_self_unload=True)
            logs += [log1, log2]
            outputs += new_files(AUDIO, start) + new_files(TEXT, start)
        else:
            return {"log": f"未知预设：{preset}", "files": [], "preview": None}
        return {"log": "\n".join(logs), "files": files_out(outputs), "preview": None}

    def video_dub(self, video, text, voice, reference, language,
                  pitch=0, formant="preserved", tone="original"):
        logs = []
        if reference:
            # 默认 F5 克隆（音色更像）；失败再回退 Chatterbox
            AUDIO.mkdir(parents=True, exist_ok=True)
            out_f5 = AUDIO / ("audio-" + time.strftime("%Y%m%d-%H%M%S") + "-f5.wav")
            f5_text = (text or "").replace(";", "，").replace("\n", " ")
            params = "Text=" + f5_text + ";Language=" + language + ";Reference=" + str(reference)
            try:
                audio_path, flog = self._audio_module("clone", None, out_f5, params, timeout=2400)
                logs.append("配音：F5 克隆\n" + flog[-3000:])
                audio = [audio_path]
                code = 0
            except Exception as exc:
                logs.append("F5 克隆失败，回退 Chatterbox：" + str(exc))
                code, log = self.run(TOOLS / "声音克隆.ps1",
                                     ["-Reference", reference, "-Text", text, "-Language", language, "-NoPause"],
                                     timeout=2400, vram_mb=VRAM_CLONE, allow_self_unload=True)
                logs.append("配音：Chatterbox\n" + log)
                audio = latest(AUDIO, ["audio-*-ttsclone-*"])
        else:
            code, log = self.run(r"D:\speech\语音合成.ps1",
                                 ["-Text", text, "-Voice", voice, "-NoPause"], timeout=1200)
            logs.append("配音：Kokoro\n" + log)
            audio = latest(AUDIO, ["audio-*-tts-*"])
        if code != 0 or not audio:
            return {"log": "\n".join(logs) + "\n\n配音生成失败。", "files": [], "preview": None}
        audio_path, fxlog = self._process_voice(audio[0], pitch, formant, tone)
        logs.append(fxlog)
        VIDEO.mkdir(parents=True, exist_ok=True)
        maxn = 0
        for p in VIDEO.glob("video-*.mp4"):
            m = re.match(r"^video-(\d{4,})-", p.name)
            if m:
                maxn = max(maxn, int(m.group(1)))
        out = VIDEO / f"video-{maxn + 1:04d}-dub-{time.strftime('%Y%m%d-%H%M%S')}.mp4"
        cmd = [FFMPEG, "-y", "-i", video, "-i", audio_path, "-map", "0:v:0", "-map", "1:a:0",
               "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-af", "apad", "-shortest", str(out)]
        p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=1800)
        logs.append(clean((p.stdout or "") + "\n" + (p.stderr or "")))
        if p.returncode != 0 or not out.exists():
            return {"log": "\n".join(logs) + "\n\n视频合成失败。", "files": [], "preview": None}
        return {"log": "\n".join(logs) + f"\n\n成品：{out}", "files": files_out([out, audio_path]), "preview": str(out)}

    def _probe_duration(self, video):
        try:
            p = subprocess.run(
                [FFPROBE, "-v", "error", "-show_entries", "format=duration",
                 "-of", "default=nw=1:nk=1", str(video)],
                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30)
            return float((p.stdout or "0").strip())
        except Exception:
            return 0.0

    def _mux_video(self, video, audio, out, subtitle=None, keep_original=False):
        # 原视频有音轨且要求保留时，把原声压到 25% 与配音混合
        has_orig = False
        if keep_original:
            try:
                pr = subprocess.run([FFPROBE, "-v", "error", "-select_streams", "a",
                                     "-show_entries", "stream=index", "-of", "csv=p=0", str(video)],
                                    capture_output=True, text=True, encoding="utf-8",
                                    errors="replace", timeout=30)
                has_orig = bool(re.search(r"\d", (pr.stdout or "").strip()))
            except Exception:
                has_orig = False
        subdir = None
        if subtitle and Path(subtitle).exists():
            subdir = Path(tempfile.mkdtemp(prefix="dubsub_"))
            shutil.copyfile(str(subtitle), str(subdir / "sub.srt"))
        if subdir or has_orig:
            cmd = [FFMPEG, "-y", "-i", str(video), "-i", str(audio)]
            chains = []
            if subdir:
                chains.append("[0:v]subtitles='sub.srt'[vout]")
            if has_orig:
                chains.append("[0:a]volume=0.25[a0]")
                chains.append("[1:a]volume=1.0[a1]")
                chains.append("[a0][a1]amix=inputs=2:duration=first:dropout_transition=0[aout]")
            fc = ";".join(chains)
            cmd += ["-filter_complex", fc]
            cmd += ["-map", "[vout]" if subdir else "0:v:0"]
            cmd += ["-map", "[aout]" if has_orig else "1:a:0"]
            cmd += ["-c:v", "libx264", "-preset", "medium", "-crf", "20",
                    "-pix_fmt", "yuv420p"] if subdir else ["-c:v", "copy"]
            cmd += ["-c:a", "aac", "-b:a", "192k", "-shortest", str(out)]
        else:
            cmd = [FFMPEG, "-y", "-i", str(video), "-i", str(audio),
                   "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy",
                   "-c:a", "aac", "-b:a", "192k", "-af", "apad", "-shortest", str(out)]
        p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=1800,
                           cwd=str(subdir) if subdir else None)
        if subdir:
            try:
                shutil.rmtree(subdir, ignore_errors=True)
            except Exception:
                pass
        return p.returncode, clean((p.stdout or "") + "\n" + (p.stderr or ""))

    def _process_voice(self, audio, pitch=0, formant="preserved", tone="original"):
        """音调/共振峰/音色明暗后期；不改写台词。"""
        try:
            pitch = max(-12.0, min(12.0, float(pitch)))
        except Exception:
            pitch = 0.0
        formant = "preserved" if formant not in ("preserved", "shifted") else formant
        tone = tone if tone in ("original", "bright", "warm") else "original"
        if abs(pitch) < 0.05 and formant == "preserved" and tone == "original":
            return str(audio), "音调/音色处理：原始"
        factor = 2 ** (pitch / 12.0)
        flt = f"rubberband=pitch={factor:.6f}:formant={formant}"
        if tone == "bright":
            flt += ",treble=g=3"
        elif tone == "warm":
            flt += ",bass=g=3"
        AUDIO.mkdir(parents=True, exist_ok=True)
        out = AUDIO / f"audio-voicefx-{time.time_ns()}.wav"
        cmd = [FFMPEG, "-y", "-i", str(audio), "-af", flt, "-ar", "44100",
               "-c:a", "pcm_s16le", str(out)]
        p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=600)
        if p.returncode != 0 or not out.exists():
            return str(audio), "音调/音色处理失败，使用原始音频：\n" + clean(p.stderr or "")[-500:]
        parts = [f"音调 {pitch:+.1f} 半音"]
        if formant == "shifted":
            parts.append("共振峰跟随音调")
        else:
            parts.append("保留共振峰")
        parts.append({"original": "原始音色", "bright": "更明亮", "warm": "更低沉"}[tone])
        return str(out), "音调/音色处理：" + "，".join(parts) + f" -> {out}"

    def _audio_module(self, action, input_path, out_file, params, timeout=2400):
        """调用音频模块，返回 (产物路径, 日志)；对产物路径做容错校验。"""
        start = time.time()
        args = [PS, "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", str(AUDIO_MODULE), "-Action", action,
                "-Out", str(out_file), "-Params", params, "-Json", "-NoPause"]
        if input_path:
            args += ["-Input", str(input_path)]
        p = subprocess.run(args, capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=timeout)
        text = clean((p.stdout or "") + "\n" + (p.stderr or ""))
        payload = None
        for line in reversed(text.splitlines()):
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                payload = json.loads(line)
                break
            except Exception:
                continue
        if p.returncode != 0 or not payload or not payload.get("ok"):
            raise RuntimeError((payload or {}).get("error") or text[-1200:])
        files = payload.get("files") or []
        raw = str(files[0]).strip() if files else ""
        # 容错：日志/路径可能被拼接成 "...wavRESULT=..." 或带引号
        if "RESULT=" in raw:
            raw = raw.split("RESULT=")[0].strip()
        raw = raw.strip().strip('"').strip("'")
        cand = Path(raw) if raw else None
        if cand is not None:
            for _ in range(10):
                if cand.is_file():
                    break
                time.sleep(0.2)
        if (cand is None or not cand.is_file()) and raw:
            parent = Path(raw).parent
            if parent.is_dir():
                fresh = [x for x in parent.glob("*") if x.is_file()
                         and x.suffix.lower() in (".wav", ".flac")
                         and x.stat().st_mtime >= start - 1]
                fresh.sort(key=lambda x: x.stat().st_mtime, reverse=True)
                if fresh:
                    cand = fresh[0]
        if cand is None or not cand.is_file():
            raise RuntimeError("音频模块没有返回产物：" + text[-1000:])
        return str(cand), text

    def _fit_audio_to_video(self, video, audio, max_speed=1.8):
        """把明显长于视频的配音压到视频时长；到上限时截断并淡出。"""
        vdur = self._probe_duration(video)
        adur = self._probe_duration(audio)
        if vdur <= 0 or adur <= 0 or adur <= vdur * 1.03:
            return str(audio), f"音画时长：音频 {adur:.2f}s / 视频 {vdur:.2f}s，无需压缩"
        factor = min(max_speed, adur / vdur)
        AUDIO.mkdir(parents=True, exist_ok=True)
        out = AUDIO / f"audio-promptdub-{time.time_ns()}-fit.wav"
        cmd = [FFMPEG, "-y", "-i", str(audio)]
        if factor >= max_speed - 0.001:
            fade_start = max(0.0, vdur - 0.15)
            cmd += ["-filter:a", f"atempo={factor:.5f},afade=t=out:st={fade_start:.3f}:d=0.15",
                    "-ar", "44100", "-c:a", "pcm_s16le", "-t", f"{vdur:.3f}"]
        else:
            cmd += ["-filter:a", f"atempo={factor:.5f}", "-ar", "44100", "-c:a", "pcm_s16le"]
        cmd += [str(out)]
        p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=600)
        if p.returncode != 0 or not out.exists():
            return str(audio), f"音画时长适配失败，保留原音频：{clean(p.stderr or '')[-300:]}"
        msg = f"音画时长：音频 {adur:.2f}s / 视频 {vdur:.2f}s，已加速 {factor:.2f}x"
        if factor >= max_speed - 0.001:
            msg += "（已达 1.8x 上限，尾部按视频时长截断并淡出）"
        return str(out), msg


    # 各引擎中文语速估算（字/秒，speed=1.0 时）；用于按视频时长定旁白长度
    _CHARS_PER_SEC = {"qwen": 1.7, "qwen-fast": 1.6, "cosyvoice": 2.0,
                      "chatterbox": 1.9, "kokoro": 3.6, "seedvc": 3.6, "f5": 3.2}

    @staticmethod
    def _sanitize_instruct(text):
        """只保留音色/语气/语速/情绪，去掉字幕、字体、位置等无关要求。"""
        if not text:
            return ""
        keep = []
        drop_words = ("字幕", "字体", "字号", "颜色", "位置", "画面", "镜头", "分镜",
                      "文案", "标题", "排版", "描边", "居", "背景", "时长", "段落")
        parts = re.split("[。；;\n]", str(text))
        for seg in parts:
            seg = seg.strip()
            if not seg or any(w in seg for w in drop_words):
                continue
            keep.append(seg)
        out = "；".join(keep[:3])[:120]
        return out or "自然、清晰的中文配音，语速平稳"

    def prompt_dub(self, video, prompt, reference, language, burn_subtitles,
                   pitch=0, formant="preserved", tone="original", engine="auto", speaker="", voice_query="",
                   keep_original=False):
        logs = []
        engine = (engine or "auto").strip()
        if engine not in ("auto", "kokoro", "chatterbox", "cosyvoice",
                          "seedvc", "cosyvoice+seedvc", "qwen", "qwen-fast", "f5"):
            engine = "auto"
        auto_engine = engine == "auto"
        # 声音库：-Voice 阮梅 → 自动解析参考音（F5 克隆音色）
        if voice_query and not reference:
            try:
                hits = self.search_voices(voice_query)
                if hits:
                    prof = hits[0]
                    reference = str(prof.get("reference") or "")
                    logs.append("音色库：%s / %s -> %s" % (
                        prof.get("game", ""), prof.get("character", ""), reference))
                else:
                    logs.append("音色库未找到“%s”，改用默认引擎。" % voice_query)
            except Exception as exc:
                logs.append("音色库查询失败：%s" % exc)
        if auto_engine:
            engine = "f5" if reference else "qwen-fast"
        if engine in ("seedvc", "cosyvoice+seedvc") and not reference:
            return {"log": "Seed-VC 需要目标音色参考音频，请先在“参考人声”里选文件。",
                    "files": [], "preview": None}
        duration = self._probe_duration(video)
        _rate = self._CHARS_PER_SEC.get(engine, 3.5)
        _limit = int(max(8, duration * _rate * 1.35))
        voice_list = "；".join(f"{k} = {v}" for k, v in KOKORO_VOICES.items())
        system = (
            "你是视频旁白策划。根据用户提示，为视频写一段可直接朗读的旁白，并选择最合适的音色。"
            "只输出一个合法 JSON 对象，字段为 script、voice、speed："
            "script 是旁白正文，不包含标题、时间码、解释或 Markdown；"
            f"voice 只能从这些值中选择：{voice_list}；speed 是 0.85 到 1.15 的数字。"
        )
        user = (
            f"视频时长约 {duration:.1f} 秒。目标语言：{language}。"
            f"旁白总字数必须控制在 {max(8, _limit - 2)} 到 {_limit} 个汉字之间，必须是通顺、完整的一句话，不能是残句或生造词，结尾用句号。用户提示：{prompt}"
        )
        _cache_file = None
        _cached = None
        try:
            import hashlib as _hashlib
            _key = _hashlib.sha1(
                "|".join([str(prompt), f"{duration:.2f}", str(engine), str(language), str(_limit)]).encode("utf-8")
            ).hexdigest()[:16]
            _cache_dir = WORKBENCH / "cache"
            _cache_dir.mkdir(parents=True, exist_ok=True)
            _cache_file = _cache_dir / f"narration-{_key}.json"
            if _cache_file.exists():
                _cached = _cache_file.read_text(encoding="utf-8").strip()
        except Exception:
            _cached = None
        if _cached:
            content = _cached
            logs.append("旁白缓存命中（跳过 LLM）")
        else:
            try:
                content = self._ollama_chat(system, user)
            except Exception as exc:
                logs.append("本地 Qwen 生成旁白失败：" + str(exc))
                return {"log": "\n".join(logs), "files": [], "preview": None}
            finally:
                self._ollama_unload()
            try:
                if _cache_file is not None and (content or "").strip():
                    _cache_file.write_text(content, encoding="utf-8")
            except Exception:
                pass
        plan = {}
        try:
            m = re.search(r"\{.*\}", content, re.S)
            plan = json.loads(m.group(0)) if m else {}
        except Exception:
            plan = {}
        script = str(plan.get("script") or "").strip()
        # 收尾标点规范化：去掉末尾逗号/顿号，确保以句号等收尾
        while script and script[-1] in "，、；：,;:":
            script = script[:-1].rstrip()
        if script and script[-1] not in "。！？!?":
            script += "。"
        if not script:
            logs.append("Qwen 没有返回可用旁白，原始输出：\n" + content[:2000])
            return {"log": "\n".join(logs), "files": [], "preview": None}
        # NARRATION_CAP_APPLIED: LLM 已按目标字数写；这里只做兜底截断
        if len(script) > _limit:
            _cut = script[:_limit]
            for _p in "。！？；，":
                _i = _cut.rfind(_p)
                if _i >= int(_limit * 0.5):
                    _cut = _cut[:_i + 1]
                    break
            script = _cut
            logs.append("旁白过长，已截到 %d 字（目标 %d 字 / %.1fs）" % (len(script), _limit, duration))
        voice = str(plan.get("voice") or "zf_001").strip()
        if voice not in KOKORO_VOICES:
            voice = "zf_001"
        try:
            speed = max(0.85, min(1.15, float(plan.get("speed", 1.0))))
        except Exception:
            speed = 1.0
        logs.append(f"旁白（约 {duration:.1f}s，音色 {voice} / {KOKORO_VOICES[voice]}，语速 {speed:.2f}）：\n{script}")

        if engine == "cosyvoice" or engine == "cosyvoice+seedvc":
            voice_desc = KOKORO_VOICES.get(voice, "自然")
            instruct = self._sanitize_instruct(prompt) if prompt else "自然、清晰的中文配音，语速平稳"
            params = "Text=" + script.replace(";", "，") + ";Instruct=" + instruct
            if reference:
                params += ";Reference=" + str(reference)
            out_cosy = AUDIO / f"audio-promptdub-{time.strftime('%Y%m%d-%H%M%S')}-cosy.wav"
            AUDIO.mkdir(parents=True, exist_ok=True)
            try:
                audio, alog = self._audio_module("tts-cosy", None, out_cosy, params)
                logs.append("配音引擎：CosyVoice2（参考音色：%s）\n%s" % (
                    ("有" if reference else "默认"), alog[-3000:]))
            except Exception as exc:
                logs.append("CosyVoice2 配音失败：" + str(exc))
                return {"log": "\n".join(logs), "files": [], "preview": None}
        elif engine == "seedvc":
            r = self.tts(script, voice, speed)
            logs.append("配音引擎：Kokoro %s（Seed-VC 前置）\n%s" % (voice, r.get("log", "")))
            audio_files = [p for p in r.get("files", []) if Path(p).suffix.lower() in AUDIO_EXTS]
            if not audio_files:
                return {"log": "\n".join(logs) + "\n\n配音生成失败。", "files": [], "preview": None}
            audio = audio_files[0]
        elif engine == "qwen-fast":
            LANG_MAP_QWEN_FAST = {"zh": "Chinese", "en": "English", "ja": "Japanese",
                                  "ko": "Korean", "de": "German", "fr": "French",
                                  "ru": "Russian", "pt": "Portuguese", "es": "Spanish",
                                  "it": "Italian"}
            qlang2 = LANG_MAP_QWEN_FAST.get(str(language).lower(), "Auto")
            tfile2 = Path(tempfile.gettempdir()) / ("qwen_fast_text_" + time.strftime("%Y%m%d%H%M%S") + ".txt")
            tfile2.write_text(script, encoding="utf-8")
            iparams = "TextFile=" + str(tfile2) + ";Language=" + qlang2
            if prompt:
                ifile2 = Path(tempfile.gettempdir()) / ("qwen_fast_instr_" + time.strftime("%Y%m%d%H%M%S") + ".txt")
                ifile2.write_text(self._sanitize_instruct(prompt), encoding="utf-8")
                iparams += ";InstructFile=" + str(ifile2)
            if speaker:
                iparams += ";Speaker=" + str(speaker)
            out_qf = AUDIO / ("audio-promptdub-" + time.strftime("%Y%m%d-%H%M%S") + "-qwenfast.wav")
            AUDIO.mkdir(parents=True, exist_ok=True)
            try:
                audio, qlog2 = self._audio_module("customvoice", None, out_qf, iparams)
                logs.append("配音引擎：Qwen3-TTS 0.6B CustomVoice\n" + qlog2[-2000:])
            except Exception as exc:
                if auto_engine:
                    logs.append("Qwen3-TTS(0.6B) 失败，回退 Kokoro：" + str(exc))
                    r = self.tts(script, voice, speed)
                    logs.append("配音引擎：Kokoro %s\n%s" % (voice, r.get("log", "")))
                    audio_files = [p for p in r.get("files", []) if Path(p).suffix.lower() in AUDIO_EXTS]
                    if not audio_files:
                        return {"log": "\n".join(logs) + "\n\n配音生成失败。", "files": [], "preview": None}
                    audio = audio_files[0]
                else:
                    logs.append("Qwen3-TTS(0.6B) 配音失败：" + str(exc))
                    return {"log": "\n".join(logs), "files": [], "preview": None}
        elif engine == "qwen":
            LANG_MAP_QWEN = {"zh": "Chinese", "en": "English", "ja": "Japanese",
                             "ko": "Korean", "de": "German", "fr": "French",
                             "ru": "Russian", "pt": "Portuguese", "es": "Spanish",
                             "it": "Italian"}
            qlang = LANG_MAP_QWEN.get(str(language).lower(), "Auto")
            tfile = Path(tempfile.gettempdir()) / ("qwen_dub_text_" + time.strftime("%Y%m%d%H%M%S") + ("%06d" % (int(time.time() * 1000000) % 1000000)) + ".txt")
            tfile.write_text(script, encoding="utf-8")
            params = "TextFile=" + str(tfile) + ";Language=" + qlang
            if prompt:
                ifile = Path(tempfile.gettempdir()) / ("qwen_dub_instr_" + time.strftime("%Y%m%d%H%M%S") + ("%06d" % (int(time.time() * 1000000) % 1000000)) + ".txt")
                ifile.write_text(self._sanitize_instruct(prompt), encoding="utf-8")
                params += ";InstructFile=" + str(ifile)
            out_q = AUDIO / ("audio-promptdub-" + time.strftime("%Y%m%d-%H%M%S") + "-qwen.wav")
            AUDIO.mkdir(parents=True, exist_ok=True)
            try:
                audio, qlog = self._audio_module("voicedesign", None, out_q, params)
                logs.append("配音引擎：Qwen3-TTS VoiceDesign\n" + qlog[-2000:])
            except Exception as exc:
                logs.append("Qwen3-TTS 配音失败：" + str(exc))
                return {"log": "\n".join(logs), "files": [], "preview": None}
        elif engine == "kokoro":
            r = self.tts(script, voice, speed)
            logs.append("配音引擎：Kokoro %s\n%s" % (voice, r.get("log", "")))
            audio_files = [p for p in r.get("files", []) if Path(p).suffix.lower() in AUDIO_EXTS]
            if not audio_files:
                return {"log": "\n".join(logs) + "\n\n配音生成失败。", "files": [], "preview": None}
            audio = audio_files[0]
        elif engine == "chatterbox":
            if not reference:
                return {"log": "Chatterbox 需要参考人声文件。", "files": [], "preview": None}
            r = self.clone(reference, script, language)
            logs.append("配音引擎：Chatterbox 克隆\n" + r.get("log", ""))
            audio_files = [p for p in r.get("files", []) if Path(p).suffix.lower() in AUDIO_EXTS]
            if not audio_files:
                return {"log": "\n".join(logs) + "\n\n配音生成失败。", "files": [], "preview": None}
            audio = audio_files[0]
        elif engine == "f5":
            AUDIO.mkdir(parents=True, exist_ok=True)
            out_f5 = AUDIO / ("audio-promptdub-" + time.strftime("%Y%m%d-%H%M%S") + "-f5.wav")
            f5_text = script.replace(";", "，").replace("\n", " ")
            f5_params = "Text=" + f5_text + ";Language=" + language + ";Reference=" + str(reference)
            try:
                audio, flog = self._audio_module("clone", None, out_f5, f5_params, timeout=2400)
                logs.append("配音引擎：F5 声音克隆\n" + flog[-3000:])
            except Exception as exc:
                logs.append("F5 克隆失败，回退 Chatterbox：" + str(exc))
                r = self.clone(reference, script, language)
                logs.append("配音引擎：Chatterbox 克隆\n" + r.get("log", ""))
                audio_files = [p for p in r.get("files", []) if Path(p).suffix.lower() in AUDIO_EXTS]
                if not audio_files:
                    return {"log": "\n".join(logs) + "\n\n配音生成失败。", "files": [], "preview": None}
                audio = audio_files[0]
        elif reference:
            r = self.clone(reference, script, language)
            logs.append("配音引擎：Chatterbox 克隆\n" + r.get("log", ""))
            audio_files = [p for p in r.get("files", []) if Path(p).suffix.lower() in AUDIO_EXTS]
            if not audio_files:
                return {"log": "\n".join(logs) + "\n\n配音生成失败。", "files": [], "preview": None}
            audio = audio_files[0]
        else:
            r = self.tts(script, voice, speed)
            logs.append("配音引擎：Kokoro %s\n%s" % (voice, r.get("log", "")))
            audio_files = [p for p in r.get("files", []) if Path(p).suffix.lower() in AUDIO_EXTS]
            if not audio_files:
                return {"log": "\n".join(logs) + "\n\n配音生成失败。", "files": [], "preview": None}
            audio = audio_files[0]

        if engine in ("seedvc", "cosyvoice+seedvc"):
            try:
                seed_out = AUDIO / f"audio-promptdub-{time.strftime('%Y%m%d-%H%M%S')}-seedvc.wav"
                params = "Reference=" + str(reference) + ";Steps=10"
                audio, slog = self._audio_module("vc-seed", audio, seed_out, params)
                logs.append("Seed-VC 变声：\n" + slog[-3000:])
            except Exception as exc:
                logs.append("Seed-VC 变声失败：" + str(exc))
                return {"log": "\n".join(logs), "files": [str(audio)], "preview": None}

        audio, fxlog = self._process_voice(audio, pitch, formant, tone)
        logs.append(fxlog)
        audio, fitlog = self._fit_audio_to_video(video, audio)
        logs.append(fitlog)

        stamp = time.strftime("%Y%m%d-%H%M%S")
        srt = TEXT / f"promptdub-{stamp}.srt"
        script_file = TOOLS / f"_promptdub-{stamp}.txt"
        srt_ok = False
        try:
            TEXT.mkdir(parents=True, exist_ok=True)
            script_file.write_text(script, encoding="utf-8")
            code, alog = self.run(TOOLS / "字幕对齐.ps1",
                                  ["-Audio", audio, "-Text", str(script_file),
                                   "-Language", language, "-Output", str(srt), "-NoPause"],
                                  timeout=1800)
            logs.append(alog)
            srt_ok = srt.exists()
        except Exception as exc:
            logs.append("字幕对齐失败：" + str(exc))
        finally:
            try:
                script_file.unlink()
            except OSError:
                pass

        VIDEO.mkdir(parents=True, exist_ok=True)
        n = 0
        for p in VIDEO.glob("video-*.mp4"):
            m = re.match(r"^video-(\d{4,})-", p.name)
            if m:
                n = max(n, int(m.group(1)))
        out = VIDEO / f"video-{n + 1:04d}-promptdub-{stamp}.mp4"
        subtitle_arg = srt if (burn_subtitles and srt_ok) else None
        if burn_subtitles and not srt_ok:
            logs.append("烧录字幕已跳过：SRT 未生成。")
        code, mlog = self._mux_video(video, audio, out, subtitle_arg, keep_original)
        logs.append(mlog)
        if code != 0 or not out.exists():
            return {"log": "\n".join(logs) + "\n\n视频封装失败。", "files": files_out([audio]), "preview": None}
        logs.append(f"成品：{out}")
        return {"log": "\n".join(logs), "files": files_out([out, audio, str(srt)]), "preview": str(out)}


    def scan_game(self, game_dir):
        path = Path(game_dir)
        if not path.is_dir():
            return {"log": f"游戏目录不存在：{path}", "files": [], "preview": None}
        if not Path(COLLECT_PY).is_file() or not Path(SCAN_GAME).is_file():
            return {"log": "游戏采集器未安装完整。", "files": [], "preview": None}
        p = subprocess.run([str(COLLECT_PY), str(SCAN_GAME), "--path", str(path), "--json"],
                           capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=600)
        text = clean((p.stdout or "") + "\n" + (p.stderr or ""))
        payload = None
        try:
            start = text.find("{")
            end = text.rfind("}")
            if start >= 0 and end > start:
                payload = json.loads(text[start:end + 1])
        except Exception:
            payload = None
        if not payload:
            return {"log": text[-4000:], "files": [], "preview": None}
        log = (
            f"目录：{payload.get('path')}\n"
            f"引擎：{payload.get('engine')}\n"
            f"音频资源：{payload.get('audio_gb')} GB {payload.get('audio')}\n"
            f"推荐工具：{payload.get('recommended_tool')} -> {payload.get('tool_path')}\n"
            f"说明：{payload.get('note')}\n"
            + "\n".join("  " + x for x in payload.get("evidence", []))
        )
        if payload.get("recommended_tool") == "fmodel" and not payload.get("tool_available"):
            log += "\n\nFModel 未安装或路径不对。"
        return {"log": log, "files": [], "preview": None}

    def web_audio(self, url, out_dir=""):
        if not url.strip():
            return {"log": "缺少网页视频 URL。", "files": [], "preview": None}
        if not Path(WEB_AUDIO_PS).is_file():
            return {"log": "网页视频转音频脚本不存在。", "files": [], "preview": None}
        out = Path(out_dir) if out_dir else COLLECT / "网页音频"
        out.mkdir(parents=True, exist_ok=True)
        p = subprocess.run([PS, "-NoProfile", "-ExecutionPolicy", "Bypass",
                            "-File", str(WEB_AUDIO_PS), "-Url", url,
                            "-OutDir", str(out), "-Format", "wav", "-NoPause"],
                           capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=7200)
        text = clean((p.stdout or "") + "\n" + (p.stderr or ""))
        product = product_of(text)
        files = files_out([product] if product else [p for p in new_files(out, time.time() - 7200) if p.suffix.lower() == ".wav"])
        if p.returncode != 0 or not files:
            return {"log": text[-5000:] + "\n\n网页音频提取失败。", "files": [], "preview": None}
        return {"log": text, "files": files, "preview": files[0]}

    def open_collector(self, action="anime"):
        if not Path(COLLECT_PS).is_file():
            return {"log": "游戏采集台不存在。", "files": [], "preview": None}
        subprocess.Popen([PS, "-NoProfile", "-ExecutionPolicy", "Bypass",
                          "-File", str(COLLECT_PS), "-Action", action],
                         cwd=str(COLLECT))
        return {"log": f"已启动游戏采集台：{action}", "files": [], "preview": None}

    def voice_profiles(self):
        if not VOICE_LIBRARY.is_file():
            return []
        try:
            data = json.loads(VOICE_LIBRARY.read_text(encoding="utf-8"))
            return [p for p in data.get("profiles", []) if p.get("reference") and Path(p["reference"]).is_file()]
        except Exception:
            return []

    def search_voices(self, query=""):
        q = (query or "").strip().lower()
        profiles = self.voice_profiles()
        if not q:
            return profiles
        out = []
        for p in profiles:
            fields = [p.get("game", ""), p.get("character", ""), p.get("source", "")]
            fields += list(p.get("aliases", []) or []) + list(p.get("tags", []) or [])
            if any(q in str(x).lower() for x in fields):
                out.append(p)
        return out

    def generate_voice(self, profile_id, text, instruct=""):
        text = (text or "").strip()
        if not text:
            return {"log": "缺少要生成的台词。", "files": [], "preview": None}
        profile = next((p for p in self.voice_profiles() if p.get("id") == profile_id), None)
        if not profile:
            return {"log": "声音库找不到该角色。", "files": [], "preview": None}
        reference = str(profile["reference"])
        out_dir = Path(reference).parent
        out_file = out_dir / f"生成-{time.strftime('%Y%m%d-%H%M%S')}.wav"
        instruction = (instruct or f"用{profile.get('character', '这个角色')}的声线，自然、清晰地说").replace(";", "，")
        params = "Text=" + text.replace(";", "，") + ";Instruct=" + instruction + ";Reference=" + reference
        start = time.time()
        try:
            audio, log = self._audio_module("tts-cosy", None, out_file, params, timeout=1800)
        except Exception as exc:
            fresh = [x for x in out_dir.glob("audio-cosy-*.wav")
                     if x.is_file() and x.stat().st_mtime >= start - 1]
            fresh.sort(key=lambda x: x.stat().st_mtime, reverse=True)
            if fresh:
                return {"log": "模块校验失败，但已找到刚生成的产物：\n" + str(exc) +
                        f"\n\n音频完成：{fresh[0]}", "files": [str(fresh[0])], "preview": None}
            return {"log": "声音库生成失败：" + str(exc), "files": [], "preview": None}
        return {"log": log + f"\n\n音频完成：{audio}", "files": [audio], "preview": None}

    def mr(self, audio):
        start = time.time()
        return self._collect(TOOLS / "分离音频MR.ps1", ["-Audio", audio, "-NoPause"],
                             AUDIO, start, ["audio-*-stems-*"], 3600, 0)

    def dfn(self, audio):
        start = time.time()
        return self._collect(TOOLS / "降噪DFN.ps1", ["-Audio", audio, "-NoPause"],
                             AUDIO, start, ["audio-*-dfn-*"], 1800, 0)

    def align(self, audio, text, txt_file, language):
        out = TEXT / (Path(audio).stem + ".aligned.srt")
        TEXT.mkdir(parents=True, exist_ok=True)
        text_arg = txt_file or text
        code, log = self.run(TOOLS / "字幕对齐.ps1",
                             ["-Audio", audio, "-Text", text_arg, "-Language", language,
                              "-Output", str(out), "-NoPause"], timeout=3600)
        return {"log": log + f"\n\n退出码：{code}", "files": files_out([str(out)]), "preview": None}

    def lipsync(self, video, audio):
        code, log = self.run(TOOLS / "口型同步.ps1", ["-Video", video, "-Audio", audio, "-NoPause"], timeout=7200)
        files = files_out(latest(VIDEO, ["video-*-lipsync-*.mp4"]))
        return {"log": log + f"\n\n退出码：{code}", "files": files, "preview": files[0] if files else None}

    def batch(self, files, preset, language):
        logs, outputs = [], []
        files = [Path(f) for f in files if Path(f).is_file()]
        total = len(files)
        for i, p in enumerate(files, 1):
            logs.append(f"\n===== [{i}/{total}] {p.name} =====")
            if p.suffix.lower() in VIDEO_EXTS or preset == "仅转写 / 字幕":
                r = self.subtitle(str(p), "large-v3-turbo", language, "srt,txt")
            elif preset == "降噪 + 字幕":
                r = self.pipeline(str(p), "降噪 + 字幕", language)
            elif preset == "完整音频链":
                r = self.pipeline(str(p), "完整音频链：分离 + 降噪 + 字幕 + MIDI", language)
            elif preset == "说话人 + 字幕":
                r = self.pipeline(str(p), "说话人分离 + 字幕", language)
            else:
                r = self.subtitle(str(p), "large-v3-turbo", language, "srt,txt")
            logs.append(r.get("log", ""))
            outputs += r.get("files", [])
        return {"log": "\n".join(logs), "files": files_out(outputs), "preview": None}

    def mastering(self, target, reference):
        AUDIO.mkdir(parents=True, exist_ok=True)
        n = 0
        for p in AUDIO.glob("audio-*.wav"):
            m = re.match(r"^audio-(\d{4,})-", p.name)
            if m:
                n = max(n, int(m.group(1)))
        out = AUDIO / f"audio-{n + 1:04d}-master-{time.strftime('%Y%m%d-%H%M%S')}.wav"
        code, log = self.run(MASTER_PS,
                             ["-Target", target, "-Reference", reference,
                              "-Output", str(out), "-NoPause"], timeout=1800)
        return {"log": log + f"\n\n退出码：{code}",
                "files": files_out([str(out)]), "preview": str(out) if out.exists() else None}

    def _ollama_chat(self, system, user, timeout=600):
        payload = {
            "model": TRANSLATE_MODEL,
            "messages": [{"role": "system", "content": system},
                         {"role": "user", "content": user}],
            "stream": False,
            "keep_alive": "2m",
            "think": False,
            "options": {"temperature": 0.1, "num_predict": 800},
        }
        req = urllib.request.Request(
            OLLAMA + "/api/chat",
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.loads(r.read().decode("utf-8"))
        return (data.get("message") or {}).get("content", "")

    def _ollama_unload(self):
        try:
            payload = {"model": TRANSLATE_MODEL, "keep_alive": 0}
            req = urllib.request.Request(
                OLLAMA + "/api/generate",
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
            )
            urllib.request.urlopen(req, timeout=15).read()
        except Exception:
            pass

    def translate(self, source_path, source_lang, target_lang):
        src = Path(source_path)
        if not src.is_file():
            return {"log": f"文件不存在：{src}", "files": [], "preview": None}
        raw = src.read_text(encoding="utf-8", errors="replace").lstrip("\ufeff")
        is_srt = src.suffix.lower() == ".srt"
        units = []
        if is_srt:
            for block in re.split(r"\r?\n\s*\r?\n", raw.strip()):
                lines = block.splitlines()
                if len(lines) >= 3 and "-->" in lines[1]:
                    units.append((lines[0].strip(), lines[1].strip(),
                                  " ".join(x.strip() for x in lines[2:] if x.strip())))
        if not units:
            units = [(str(i + 1), "", line.strip())
                     for i, line in enumerate(raw.splitlines()) if line.strip()]
        if not units:
            return {"log": "没有可翻译文本。", "files": [], "preview": None}

        lang_names = {"auto": "自动识别", "zh": "中文", "en": "English", "ja": "日本語"}
        src_name = lang_names.get(source_lang, source_lang)
        dst_name = lang_names.get(target_lang, target_lang)
        logs = [f"本地翻译模型：{TRANSLATE_MODEL}", f"{src_name} → {dst_name}，共 {len(units)} 段"]
        translated = {}
        chunk_size = 20
        for start in range(0, len(units), chunk_size):
            chunk = units[start:start + chunk_size]
            items = {str(i): text for i, (_idx, _time, text) in enumerate(chunk, start + 1)}
            system = (
                "你是专业字幕翻译。"
                f"把编号文本从{src_name}翻译成{dst_name}，保留人名、数字和专有名词。"
                "只输出一个合法 JSON 对象，键是编号字符串，值是译文；不要 Markdown、不要解释。"
            )
            user = json.dumps(items, ensure_ascii=False)
            try:
                content = self._ollama_chat(system, user)
            except Exception as exc:
                self._ollama_unload()
                logs.append(f"第 {start // chunk_size + 1} 批失败：{exc}")
                return {"log": "\n".join(logs), "files": [], "preview": None}
            mapping = None
            try:
                m = re.search(r"\{.*\}", content, re.S)
                mapping = json.loads(m.group(0)) if m else None
            except Exception:
                mapping = None
            if not isinstance(mapping, dict):
                logs.append("模型返回格式无法解析，保留原文。")
                mapping = {}
            for key, text in items.items():
                translated[str(key)] = str(mapping.get(key, text)).strip()
            logs.append(f"已翻译 {min(start + chunk_size, len(units))}/{len(units)} 段")

        if is_srt:
            out = TEXT / f"{src.stem}.{target_lang}.srt"
            TEXT.mkdir(parents=True, exist_ok=True)
            blocks = []
            for n, (idx, timeline, _text) in enumerate(units, 1):
                blocks.append(f"{idx}\n{timeline}\n{translated.get(str(n), '')}")
            out.write_text("\n\n".join(blocks) + "\n", encoding="utf-8")
        else:
            TEXT.mkdir(parents=True, exist_ok=True)
            out = TEXT / f"{src.stem}.{target_lang}.txt"
            lines = [translated.get(str(n), text) for n, (_idx, _time, text) in enumerate(units, 1)]
            out.write_text("\n".join(lines) + "\n", encoding="utf-8")
        logs.append(f"成品：{out}")
        self._ollama_unload()
        return {"log": "\n".join(logs), "files": files_out([str(out)]), "preview": None}


    def music(self, tags, lyrics, duration, bpm, steps, seed):
        started = False
        logs = []
        try:
            up = False
            try:
                urllib.request.urlopen("http://127.0.0.1:8189/system_stats", timeout=3)
                up = True
            except Exception:
                up = False
            if not up:
                code, log = self.run(Path(r"D:\ComfyUI-aki-v3.2\start-aki.ps1"),
                                     ["-Port", "8189", "-NoBrowser", "-NoPause"], timeout=420)
                logs.append(log)
                if code != 0:
                    return {"log": "启动 ComfyUI 失败。\n\n" + "\n".join(logs), "files": [], "preview": None}
                started = True
            wf = json.loads(Path(r"D:\ComfyUI-aki-v3.2\workflows\ace15_xl_turbo_api.json").read_text(encoding="utf-8"))
            for node in wf.values():
                ct, inp = node.get("class_type"), node.get("inputs", {})
                if ct == "TextEncodeAceStepAudio1.5":
                    inp.update(tags=tags, lyrics=lyrics or "[instrumental]", language="zh",
                               bpm=int(bpm), duration=float(duration), timesignature="4",
                               keyscale="C major", generate_audio_codes=True, cfg_scale=2.0,
                               temperature=0.85, top_p=0.9, top_k=0, min_p=0)
                elif ct == "EmptyAceStep1.5LatentAudio":
                    inp["seconds"] = float(duration)
                elif ct == "PrimitiveInt":
                    inp["value"] = int(seed)
                elif ct == "KSampler":
                    inp["steps"] = int(steps)
                    inp["cfg"] = 1.0
                elif ct in ("SaveAudioAdvanced", "SaveAudioMP3"):
                    inp["filename_prefix"] = "audio/ACE_Qt"
            data = json.dumps({"prompt": wf, "client_id": "audio-qt"}).encode("utf-8")
            req = urllib.request.Request("http://127.0.0.1:8189/prompt", data=data,
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=60) as r:
                pid = json.loads(r.read().decode("utf-8")).get("prompt_id")
            logs.append("提交 ACE-Step 任务…")
            item = None
            deadline = time.time() + 600
            while time.time() < deadline:
                time.sleep(2)
                try:
                    with urllib.request.urlopen("http://127.0.0.1:8189/history/" + pid, timeout=10) as r:
                        hist = json.loads(r.read().decode("utf-8"))
                    if pid in hist:
                        item = hist[pid]
                        break
                except Exception:
                    pass
            if not item:
                return {"log": "\n".join(logs) + "\n生成超时", "files": [], "preview": None}
            saved = []
            for node in item.get("outputs", {}).values():
                for a in node.get("audio", []):
                    src = COMFY_OUT / Path(a.get("subfolder", "")) / a.get("filename", "")
                    if src.exists():
                        saved.append(src)
            if not saved:
                return {"log": "\n".join(logs) + "\n没有音频输出", "files": [], "preview": None}
            stage = TOOLS / "music-stage-qt"
            if stage.exists():
                shutil.rmtree(stage, ignore_errors=True)
            stage.mkdir(parents=True, exist_ok=True)
            for src in saved:
                shutil.copy2(src, stage / src.name)
            code, olog = self.run(QROOT / "整理音频.ps1", ["-SourceDir", str(stage), "-Kind", "music"], timeout=120)
            logs.append(olog)
            shutil.rmtree(stage, ignore_errors=True)
            files = files_out(latest(AUDIO, ["audio-*-music-*"]))
            return {"log": "\n".join(logs), "files": files, "preview": files[0] if files else None}
        except Exception as e:
            logs.append("音乐生成失败：" + repr(e))
            return {"log": "\n".join(logs), "files": [], "preview": None}
        finally:
            if started:
                try:
                    code, slog = self.run(Path(r"D:\ComfyUI-aki-v3.2\stop-aki.ps1"), ["-NoPause"], timeout=600)
                    logs.append("\n" + slog)
                except Exception:
                    pass

    def status(self):
        lines = ["## 运行状态"]
        try:
            gpu = subprocess.run(["nvidia-smi", "--query-gpu=name,memory.used,memory.free",
                                  "--format=csv,noheader"], capture_output=True, text=True, timeout=5)
            lines += ["### GPU", "```", (gpu.stdout or gpu.stderr).strip(), "```"]
        except Exception as e:
            lines += [f"GPU 查询失败：{e}"]
        lines.append("**脚本**：" + " · ".join(
            ("✅" if p.exists() else "❌") + n for n, p in [
                ("转写", TOOLS / "录音转字幕.ps1"), ("分离", TOOLS / "分离音频.ps1"),
                ("降噪", TOOLS / "降噪增强.ps1"), ("超分", TOOLS / "音频超分.ps1"),
                ("克隆", TOOLS / "声音克隆.ps1"), ("DFN", TOOLS / "降噪DFN.ps1"),
                ("MelBand", TOOLS / "分离音频MR.ps1"), ("对齐", TOOLS / "字幕对齐.ps1"),
                ("口型", TOOLS / "口型同步.ps1")]))
        return "\n\n".join(lines)
