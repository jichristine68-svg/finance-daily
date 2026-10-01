# -*- coding: utf-8 -*-
"""
财经新闻 · 手机预览服务（白名单版）

双击「启动手机预览.bat」即可运行；关掉这个窗口即停止服务。
只放行 index.html 和 data.js 两个文件，项目里其余文件一律 404，不外泄。
"""
import http.server
import os
import sys
import socket
import urllib.parse
import datetime

ROOT = os.path.dirname(os.path.abspath(__file__))
PORT = 8080
for _a in sys.argv[1:]:
    if _a.isdigit():
        PORT = int(_a)
        break
ALLOW = {
    "index.html": "text/html; charset=utf-8",
    "data.js": "text/javascript; charset=utf-8",
}


def lan_ips():
    """返回本机可能的局域网 IPv4（排除 127.* 和 169.254.*），主地址在前。"""
    ips = []
    primary = None
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))  # 不真的发包，只让内核挑一个出口网卡
        primary = s.getsockname()[0]
    except Exception:
        pass
    finally:
        s.close()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip not in ips and not ip.startswith("127.") and not ip.startswith("169.254."):
                ips.append(ip)
    except Exception:
        pass
    if primary and primary not in ips:
        ips.insert(0, primary)
    return ips


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "LanPreview/1.0"
    protocol_version = "HTTP/1.1"

    def _log(self, status, extra=""):
        ts = datetime.datetime.now().strftime("%H:%M:%S")
        try:
            print("[%s] %-15s %s %s" % (ts, self.client_address[0], status, extra), flush=True)
        except Exception:
            pass

    def _serve(self):
        path = urllib.parse.unquote(urllib.parse.urlparse(self.path).path)
        name = os.path.basename(path)
        if path in ("/", ""):
            name = "index.html"
        if name not in ALLOW:
            body = b"404"
            self.send_response(404)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command == "GET":
                self.wfile.write(body)
            self._log(404, "not-allowed")
            return
        try:
            with open(os.path.join(ROOT, name), "rb") as f:
                body = f.read()
        except OSError as e:
            self.send_response(500)
            self.send_header("Content-Length", "0")
            self.end_headers()
            self._log(500, str(e))
            return
        self.send_response(200)
        self.send_header("Content-Type", ALLOW[name])
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command == "GET":
            self.wfile.write(body)
        self._log(200, "%d bytes" % len(body))

    do_GET = _serve
    do_HEAD = _serve

    def log_message(self, fmt, *args):
        pass


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    if "--show" in sys.argv:
        for ip in (lan_ips() or ["<本机IP>"]):
            print("    http://%s:%d" % (ip, PORT))
        input("按回车退出...")
        sys.exit(0)
    print("=" * 46)
    print("  财经新闻 · 手机预览服务")
    print("=" * 46)
    print("手机和电脑连【同一个 Wi-Fi】后，用手机浏览器打开：")
    for ip in (lan_ips() or ["<本机IP>"]):
        print("    http://%s:%d" % (ip, PORT))
    print()
    print("关掉这个窗口 = 停止服务。")
    print("-" * 46)
    try:
        Server(("0.0.0.0", PORT), Handler).serve_forever()
    except OSError as e:
        print("启动失败：%s" % e)
        print("端口 %d 可能被占用，先关掉旧的服务窗口再试。" % PORT)
        input("按回车退出...")
