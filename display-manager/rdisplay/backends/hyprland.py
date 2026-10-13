"""Hyprland backend. Live apply uses `hyprctl eval hl.monitor{}`
(`hyprctl keyword monitor` is rejected by the Lua config parser on 0.56)."""
import json
import os
import re
import subprocess

NAME_RE = re.compile(r"^[A-Za-z0-9_.:-]+$")
MODE_RE = re.compile(r"^\d+x\d+@\d+(\.\d+)?$")
NAME = "hyprland"


def detect():
    return bool(os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"))


def _hyprctl(*args):
    r = subprocess.run(["hyprctl", *args], capture_output=True, text=True, timeout=10)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or r.stdout.strip())
    return r.stdout


def list_monitors():
    out = []
    for m in json.loads(_hyprctl("monitors", "all", "-j")):
        modes = []
        for s in m.get("availableModes", []):
            s = s.replace("Hz", "")
            if s not in modes:
                modes.append(s)
        out.append({
            "name": m["name"], "description": m["description"],
            "enabled": not m.get("disabled", False),
            "width": m["width"], "height": m["height"],
            "refresh": round(m["refreshRate"], 2),
            "x": m["x"], "y": m["y"], "scale": m["scale"], "transform": m["transform"],
            "modes": modes,
        })
    return out


def _lua(m, fmt):
    if not NAME_RE.match(m["name"]):
        raise ValueError("bad output name: %r" % m["name"])
    if not m.get("enabled", True):
        return 'hl.monitor({output="%s", disabled=true})' % m["name"]
    mode = m["mode"] if "mode" in m else "%dx%d@%s" % (m["width"], m["height"], fmt(m["refresh"]))
    if not MODE_RE.match(mode):
        raise ValueError("bad mode: %r" % mode)
    return ('hl.monitor({output="%s", mode="%s", position="%dx%d", scale=%s, transform=%d})'
            % (m["name"], mode, round(m["x"]), round(m["y"]), fmt(m["scale"]), int(m["transform"])))


def apply_layout(layout, fmt):
    """layout is already validated and ordered (enabled first)."""
    for m in layout:
        res = _hyprctl("eval", _lua(m, fmt)).strip()
        if res != "ok":
            raise RuntimeError("hyprland rejected %s: %s" % (m["name"], res))
