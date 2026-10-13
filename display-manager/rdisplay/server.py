"""Local web editor backend. Binds 127.0.0.1 only. Stdlib only.
Apply is tentative: a revert timer restores the prior layout unless /api/confirm arrives."""
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import core, profiles

WEB = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "web")
AETHER = os.path.expanduser("~/RaBbLE-Collective/RaBbLE-Aether/dist/aether.css")
REVERT_SECONDS = 15

_lock = threading.Lock()
_pending = {"timer": None, "prev": None, "deadline": 0}


def _revert():
    with _lock:
        prev, _pending["prev"], _pending["timer"] = _pending["prev"], None, None
    if prev:
        core.apply_layout(prev)


def _apply(layout):
    with _lock:
        if _pending["timer"]:
            _pending["timer"].cancel()
        else:
            _pending["prev"] = core.snapshot()
        core.apply_layout(layout)
        t = threading.Timer(REVERT_SECONDS, _revert)
        t.daemon = True
        t.start()
        _pending["timer"] = t


def _confirm():
    with _lock:
        if _pending["timer"]:
            _pending["timer"].cancel()
        _pending["timer"] = _pending["prev"] = None


def _state():
    mons = core.list_monitors()
    return {"monitors": mons, "profiles": profiles.list_profiles(),
            "matched": profiles.match(mons), "pending": _pending["timer"] is not None,
            "revert_seconds": REVERT_SECONDS}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/api/state":
            return self._send(200, _state())
        if self.path == "/aether.css" and os.path.exists(AETHER):
            return self._send(200, open(AETHER, "rb").read(), "text/css")
        if self.path in ("/", "/index.html"):
            return self._send(200, open(os.path.join(WEB, "index.html"), "rb").read(), "text/html; charset=utf-8")
        self._send(404, {"error": "not found"})

    def do_POST(self):
        # same-origin only: block cross-site pages from driving the local API
        host = self.headers.get("Host", "")
        origin = self.headers.get("Origin")
        if not host.startswith(("127.0.0.1:", "localhost:")) or (origin and origin.split("//")[-1] != host):
            return self._send(403, {"error": "forbidden"})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            if self.path == "/api/apply":
                _apply(body["monitors"])
            elif self.path == "/api/confirm":
                _confirm()
            elif self.path == "/api/revert":
                _revert()
            elif self.path == "/api/profile/save":
                profiles.save(body["name"], body.get("monitors"))
            elif self.path == "/api/profile/apply":
                layout = profiles.to_layout(profiles.load(body["name"]), core.list_monitors())
                if not layout:
                    raise ValueError("profile matches none of the connected monitors")
                _apply(layout)
            elif self.path == "/api/profile/delete":
                profiles.delete(body["name"])
            else:
                return self._send(404, {"error": "not found"})
            self._send(200, _state())
        except Exception as e:
            self._send(400, {"error": str(e)})


def serve(port=8765):
    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    print("rdisplay editor: http://127.0.0.1:%d" % port)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
