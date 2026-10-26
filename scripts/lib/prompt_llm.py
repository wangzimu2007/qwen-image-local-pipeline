# -*- coding: utf-8 -*-
"""本地模型提示词扩写（图片/视频/音频/音效/音色）。

调用本机 Ollama（qwen3.5:9b，关闭思考），把一句话要求扩成可直接使用的提示词。
输出：
  PROMPT=<单行提示词>
  RESULT=<提示词文件路径>
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.request
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

OLLAMA = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434")
MODEL = os.environ.get("PROMPT_MODEL", "qwen3.5:9b")

SPECS = {
    "image": (
        "你是中文图像生成提示词工程师。把用户的简短要求扩写成可直接用于文生图模型的提示词。"
        "必须包含：主体与动作、画面构图、镜头与视角、光线、色彩、材质质感、风格。"
        "80~160 个汉字，只输出提示词正文，不要解释、不要分点、不要引号。"
    ),
    "video": (
        "你是图生视频（首帧已给定）的提示词工程师。用户已有一张图，需要补充动态描述。"
        "写清：主体动作、镜头运动（推拉摇移/环绕/跟随）、速度节奏、环境动态（风/水/光）、氛围变化。"
        "不要重复描述静态画面内容，60~120 个汉字，只输出提示词正文。"
    ),
    "audio": (
        "你是游戏/影视声音设计提示词工程师。把用户要求扩写成可直接用于文生音效/配乐模型的提示词。"
        "写清：声音类型（环境音/音效/配乐）、具体声源、空间感与距离、质感、情绪、节奏与起伏。"
        "60~140 个汉字，只输出提示词正文。"
    ),
    "sfx": (
        "你是音效设计提示词工程师。把要求扩写成单个音效的生成提示词。"
        "写清：声源、动作过程、空间与距离、质感（干湿/远近/冷暖）、时长感。"
        "30~80 个汉字，只输出提示词正文。"
    ),
    "voice": (
        "你是配音声音设计提示词工程师。把要求扩写成一句声音描述，用于 VoiceDesign 生成音色。"
        "写清：性别年龄、音色质感（低沉/明亮/沙哑/磁性）、口音或地域感（如需要）、情绪、语速、"
        "适合的内容类型（纪录片/广告/旁白/角色台词）。30~80 个汉字，只输出描述正文。"
    ),
}


def ollama_chat(system: str, user: str, timeout: int = 120) -> str:
    payload = {
        "model": MODEL,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": user}],
        "stream": False,
        "keep_alive": "10m",
        "think": False,
        "options": {"temperature": 0.7, "num_predict": 500},
    }
    req = urllib.request.Request(
        OLLAMA + "/api/chat",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = json.loads(r.read().decode("utf-8"))
    return ((data.get("message") or {}).get("content") or "").strip()


def clean(text: str) -> str:
    text = text.replace("/no_think", "").strip()
    text = re.sub(r"^[#*\-\s]+", "", text)
    text = text.replace("\r", " ").replace("\n", " ")
    text = re.sub(r"\s{2,}", " ", text)
    return text.strip().strip('"').strip("“”").strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", required=True)
    ap.add_argument("--kind", default="image", choices=list(SPECS.keys()))
    ap.add_argument("--style", default="")
    ap.add_argument("--out", default="")
    a = ap.parse_args()

    system = SPECS[a.kind] + "/no_think"
    user = a.text + (("\n额外风格要求：" + a.style) if a.style else "")
    t0 = time.time()
    prompt = clean(ollama_chat(system, user))
    if not prompt:
        raise SystemExit("本地模型没有返回提示词")
    out = Path(a.out) if a.out else (Path(os.environ.get("TEMP", ".")) /
                                     ("prompt_" + a.kind + "_" + time.strftime("%Y%m%d-%H%M%S") + ".txt"))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(prompt + "\n", encoding="utf-8")
    print("提示词（%s，%.1fs）：" % (a.kind, time.time() - t0))
    print(prompt)
    print("PROMPT=" + prompt)
    print("OUTVAR=prompt=" + prompt)
    print("RESULT=" + str(out))


if __name__ == "__main__":
    main()
