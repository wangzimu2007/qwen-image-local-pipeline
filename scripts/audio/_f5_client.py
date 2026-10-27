# -*- coding: utf-8 -*-
"""F5 常驻服务客户端：发一个合成请求，打印结果。"""
import argparse
import json
import socket
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8766)
    ap.add_argument("--ref", required=True)
    ap.add_argument("--ref-text", default="")
    ap.add_argument("--text", default="")
    ap.add_argument("--text-file", default="")
    ap.add_argument("--out", required=True)
    ap.add_argument("--speed", type=float, default=1.0)
    ap.add_argument("--pause-ms", type=int, default=0)
    a = ap.parse_args()
    text = a.text
    if a.text_file:
        text = Path(a.text_file).read_text(encoding="utf-8").strip()
    req = {
        "ref": str(a.ref), "ref_text": a.ref_text, "text": text,
        "out": str(a.out), "speed": a.speed, "pause_ms": a.pause_ms,
    }
    s = socket.create_connection(("127.0.0.1", a.port), timeout=30)
    s.settimeout(3600)
    with s:
        s.sendall((json.dumps(req, ensure_ascii=False) + "\n").encode("utf-8"))
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    try:
        resp = json.loads(data.decode("utf-8"))
    except Exception as exc:
        print("客户端解析失败：" + str(exc))
        return 1
    if not resp.get("ok"):
        print("服务端合成失败：" + str(resp.get("error")))
        return 1
    out = resp.get("out")
    print("音频完成：" + str(out))
    print("RESULT=" + str(out))
    print("META=" + json.dumps({k: resp.get(k) for k in ("duration", "sr", "gen_sec", "sentences")},
                               ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
