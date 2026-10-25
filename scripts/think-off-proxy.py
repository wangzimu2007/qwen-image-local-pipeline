# think-off-proxy.py — 给 DSH → Strata 之间塞一层，默认关掉 Qwen 的思考
#
# 背景：
#   Strata（llama.cpp 分支，8080）跑的是 Qwen3.8-Flash-Next，默认"思考模式"开。
#   实测：同一句话，思考开 → 34 个推理词 + 首字 0.70 秒；思考关 → 0 推理词 + 首字 0.06 秒。
#   DSH 自定义 provider 没有声明 reasoning 能力，所以不会主动关思考；服务端启动参数也没这开关。
#   解决办法：本代理监听 8081，把 /v1/chat/completions 请求补上
#       "chat_template_kwargs": {"enable_thinking": false}
#   再转发给 8080。其他路径原样转发（/v1/models 等）。
#
# 用法：
#   python think-off-proxy.py                 # 默认 8081 → 8080，关思考
#   python think-off-proxy.py --keep-thinking # 不注入（纯转发，便于对比）
#   python think-off-proxy.py --port 8081 --upstream 127.0.0.1:8080
#
# 然后把 DSH 里 strata-local 的 baseURL 改成 http://127.0.0.1:8081/v1
import argparse
import json
import socket
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG_PATH = None


def log(msg):
    line = "[%s] %s" % (time.strftime("%m-%d %H:%M:%S"), msg)
    if LOG_PATH:
        try:
            with open(LOG_PATH, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            pass
    try:
        print(line, flush=True)
    except Exception:
        pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream = "127.0.0.1:8080"
    inject_thinking_off = True

    def log_message(self, fmt, *args):  # 安静点
        return

    # ---- 通用转发 ----
    def _proxy(self, body=None):
        path = self.path
        url = "http://%s%s" % (self.upstream, path)
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in ("host", "content-length", "connection")}
        req = urllib.request.Request(url, data=body, headers=headers,
                                     method=self.command)
        try:
            resp = urllib.request.urlopen(req, timeout=1800)
        except urllib.error.HTTPError as e:
            resp = e
        payload = resp.read()
        self.send_response(getattr(resp, "status", 200) or resp.code)
        for k, v in resp.headers.items():
            if k.lower() in ("content-length", "transfer-encoding", "connection"):
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        t0 = time.time()
        self._proxy()
        if "/models" in self.path:
            log("GET %s  %.2fs" % (self.path, time.time() - t0))

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        body = self.rfile.read(n) if n else b""
        if self.inject_thinking_off and "/chat/completions" in self.path and body:
            try:
                data = json.loads(body.decode("utf-8"))
                changed = []
                if not data.get("chat_template_kwargs"):
                    data["chat_template_kwargs"] = {"enable_thinking": False}
                    changed.append("enable_thinking=false")
                if data.get("reasoning_effort") in (None, "high", "medium"):
                    data["reasoning_effort"] = "none"
                    changed.append("reasoning_effort=none")
                body = json.dumps(data, ensure_ascii=False).encode("utf-8")
                log("POST %s  注入 %s" % (self.path, ",".join(changed)))
            except Exception as e:
                log("注入失败（原样转发）：%s" % e)
        t0 = time.time()
        self._proxy(body)
        log("POST %s  完成 %.2fs" % (self.path, time.time() - t0))


def main():
    global LOG_PATH
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8081)
    ap.add_argument("--upstream", default="127.0.0.1:8080")
    ap.add_argument("--keep-thinking", action="store_true", help="不注入，纯转发")
    ap.add_argument("--log", default=None)
    args = ap.parse_args()

    LOG_PATH = args.log
    Handler.upstream = args.upstream
    Handler.inject_thinking_off = not args.keep_thinking

    # 上游没起来就等一会儿
    host, _, port = args.upstream.partition(":")
    for _ in range(30):
        try:
            with socket.create_connection((host, int(port)), timeout=2):
                break
        except OSError:
            time.sleep(1)

    log("代理启动：0.0.0.0:%d → %s  思考注入=%s"
        % (args.port, args.upstream, "关" if Handler.inject_thinking_off else "不注入"))
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log("代理退出")
        sys.exit(0)


if __name__ == "__main__":
    main()
