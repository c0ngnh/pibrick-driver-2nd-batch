#!/usr/bin/env python3
"""
piBrick Rotation Lock UI daemon.
Listens on localhost:9876 for HTTP POST commands and forwards them to autorotation-lock.
This replaces Qt.labs.process (not available in Qt6) by providing an HTTP API.

Commands:
  POST /lock?orientation=<normal|left|right|inverted>
  POST /unlock
  GET  /state        → returns current lock state from /var/lib/pibrick/autorotation.lock

Run as a systemd user service so it survives restarts.
"""
import http.server
import urllib.parse
import subprocess
import os
import sys

PORT = 9876
LOCK_FILE = "/var/lib/pibrick/autorotation.lock"
HELPER = "/usr/bin/autorotation-lock"
PIDFILE = "/run/user/1000/pibrick-rotation-ui.pid"


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stdout.write(f"[pibrick-rotation-ui] {fmt % args}\n")
        sys.stdout.flush()

    def do_GET(self):
        if self.path == "/state":
            try:
                state = open(LOCK_FILE).read().strip()
            except (IOError, OSError):
                state = ""
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(state.encode())
        else:
            self.send_error(404)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/lock":
            params = urllib.parse.parse_qs(parsed.query)
            ori = (params.get("orientation") or [""])[0]
            if ori not in ("normal", "left", "right", "inverted"):
                self.send_error(400, "Invalid orientation")
                return
            self._run([HELPER, ori])
            self._ok()
        elif parsed.path == "/unlock":
            self._run([HELPER, "auto"])
            self._ok()
        else:
            self.send_error(404)

    def _run(self, cmd):
        try:
            r = subprocess.run(cmd, capture_output=True, timeout=5)
            return r.returncode
        except Exception as e:
            self.log_message("ERROR running %s: %s", " ".join(cmd), e)
            return -1

    def _ok(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')


def write_pid(pidfile, pid):
    try:
        os.makedirs(os.path.dirname(pidfile), exist_ok=True)
        with open(pidfile, "w") as f:
            f.write(str(pid) + "\n")
    except Exception:
        pass


if __name__ == "__main__":
    # Single-instance: check pidfile
    if os.path.exists(PIDFILE):
        try:
            old = int(open(PIDFILE).read().strip())
            os.kill(old, 0)  # still alive?
            print(f"[pibrick-rotation-ui] Already running as PID {old}. Exiting.")
            sys.exit(0)
        except (ValueError, ProcessLookupError, PermissionError):
            pass  # stale pidfile, proceed

    write_pid(PIDFILE, os.getpid())
    print(f"[pibrick-rotation-ui] Starting on port {PORT}")

    server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    server.serve_forever()
