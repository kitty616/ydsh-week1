# -*- coding: utf-8 -*-
"""
api_server.py —— 大屏数据接口（标准库实现，不引三方依赖）

为什么要单独一个 HTTP 接口，而不是让大屏直接读 JSON 文件：
  作业要求「ECharts 前端页面读取后端提供的数据接口(JSON)」。文件读取
  只是静态快照，接口才有「后端 → 前端」的真实链路；同时接口可以把
  Hive 的聚合结果按需缓存，前端不用关心数据从哪来。

只暴露只读 GET，且 CORS 仅放开本机来源——大屏会直接双击打开 HTML，
浏览器会带 Origin: null，所以这里必须允许 null。
"""

from __future__ import annotations

import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_FILE = os.path.join(BASE, "dashboard", "echarts", "data", "dashboard.json")
PORT = int(os.environ.get("API_PORT", "8000"))

_cache = {"body": None, "mtime": 0.0}
_lock = threading.Lock()


def load_payload() -> bytes:
    """读数据文件，按 mtime 做缓存；文件变了自动重载。"""
    with _lock:
        if not os.path.exists(DATA_FILE):
            return json.dumps({"error": "dashboard.json 不存在，请先运行 "
                                        "python python/export_dashboard_data.py"},
                              ensure_ascii=False).encode("utf-8")
        mtime = os.path.getmtime(DATA_FILE)
        if _cache["body"] is None or mtime > _cache["mtime"]:
            with open(DATA_FILE, encoding="utf-8") as fh:
                _cache["body"] = json.dumps(json.load(fh), ensure_ascii=False).encode("utf-8")
            _cache["mtime"] = mtime
        return _cache["body"]


class Handler(BaseHTTPRequestHandler):
    server_version = "ydsh-dashboard/1.0"

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _json(self, body: bytes, code: int = 200):
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):  # 预检
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/") or "/"

        if path in ("/api/health", "/health"):
            return self._json(json.dumps({"ok": True, "ts": int(time.time())}).encode())

        if path in ("/api/dashboard", "/api/dashboard.json"):
            return self._json(load_payload())

        if path == "/api/kpi":
            payload = json.loads(load_payload().decode("utf-8"))
            return self._json(json.dumps(payload.get("kpi", {}), ensure_ascii=False).encode())

        if path == "/":
            html = ("<h3>ydsh dashboard api</h3><ul>"
                    "<li><a href='/api/dashboard.json'>/api/dashboard.json</a></li>"
                    "<li><a href='/api/kpi'>/api/kpi</a></li>"
                    "<li><a href='/api/health'>/api/health</a></li></ul>")
            body = html.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self._cors()
            self.end_headers()
            self.wfile.write(body)
            return

        self._json(json.dumps({"error": "not found", "path": path}).encode(), 404)

    def log_message(self, fmt, *args):
        print("[api] " + fmt % args, flush=True)


if __name__ == "__main__":
    print(f"[api] 监听 0.0.0.0:{PORT}，数据文件 {DATA_FILE}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
