#!/usr/bin/env python3
"""
llm-usage-bridge.py — Localhost-only listener that turns claude.ai web-UI
usage readings into logged observations for llm-usage-fit.py.

Why this exists: chatting on claude.ai shares the same 5h/weekly usage pool
as Claude Code, but its token cost isn't visible in our local transcripts —
so every web session throws our token-based estimate off. Rather than the
slow "go to /settings/usage, run llm-usage-log.sh by hand" loop, a userscript
(llm-usage-userscript.user.js) reads the % already rendered on the page you're
looking at and POSTs it here. No credentials, no API calls, no cookies — it's
just automating "I read the number off my own screen and typed it in".

Binds 127.0.0.1 ONLY. Never exposed beyond the loopback interface.

Endpoint:
    POST /log   {"window": "5h" | "week", "pct": <number>}
    → shells out to llm-usage-log.sh <window> <pct>, which captures the
      current per-model token breakdown alongside the observed %.

Run via Hyprland autostart (see conf.d/autostart.conf):
    exec-once = python3 ~/.config/waybar/scripts/llm-usage-bridge.py
"""

import json
import subprocess
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

HOST = "127.0.0.1"
PORT = 8765

SCRIPT_DIR = __file__.rsplit("/", 1)[0]
LOG_SCRIPT = f"{SCRIPT_DIR}/llm-usage-log.sh"

ALLOWED_ORIGIN = "https://claude.ai"
COOLDOWN_S = 90  # ignore repeat readings of the same window within this long

_last_logged = {}  # window -> (pct, monotonic_time)


def should_log(window: str, pct: float) -> bool:
    prev = _last_logged.get(window)
    now = time.monotonic()
    if prev and prev[0] == pct and (now - prev[1]) < COOLDOWN_S:
        return False
    _last_logged[window] = (pct, now)
    return True


class Handler(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", ALLOWED_ORIGIN)
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self._cors()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_POST(self):
        if self.path != "/log":
            return self._json(404, {"error": "not found"})

        try:
            length = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            return self._json(400, {"error": "invalid JSON body"})

        window = data.get("window")
        pct = data.get("pct")
        web_used = bool(data.get("web_used", False))

        if window not in ("5h", "week"):
            return self._json(400, {"error": "window must be '5h' or 'week'"})
        try:
            pct = float(pct)
            assert 0 <= pct <= 100
        except (TypeError, ValueError, AssertionError):
            return self._json(400, {"error": "pct must be a number 0-100"})

        if not should_log(window, pct):
            return self._json(200, {"ok": True, "skipped": "duplicate within cooldown"})

        cmd = [LOG_SCRIPT, window, str(pct)]
        if web_used:
            cmd.append("--web")
        try:
            result = subprocess.run(
                cmd,
                capture_output=True, text=True, timeout=30, check=True,
            )
        except (subprocess.CalledProcessError, OSError) as e:
            return self._json(500, {"error": f"logging failed: {e}"})

        return self._json(200, {"ok": True, "logged": result.stdout.strip()})

    def log_message(self, fmt, *args):
        pass  # quiet — this runs as a background daemon


def main():
    server = HTTPServer((HOST, PORT), Handler)
    print(f"llm-usage-bridge listening on http://{HOST}:{PORT}/log (loopback only)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
