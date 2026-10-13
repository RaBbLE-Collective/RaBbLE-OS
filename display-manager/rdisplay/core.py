"""Backend-agnostic monitor model helpers; all compositor I/O goes through rdisplay.backends."""
import json
import os
import time

from . import backends

INTENT = os.path.expanduser("~/.cache/rabble/display/intent.json")


def _norm(m):
    """Reduce a layout entry (mode string or width/height/refresh) to comparable fields."""
    if not m.get("enabled", True):
        return {"name": m["name"], "enabled": False}
    if "mode" in m:
        wh, hz = m["mode"].split("@")
        w, h = map(int, wh.split("x"))
        hz = float(hz)
    else:
        w, h, hz = m["width"], m["height"], m["refresh"]
    return {"name": m["name"], "enabled": True, "width": w, "height": h, "refresh": hz,
            "x": round(m["x"]), "y": round(m["y"]), "scale": m["scale"], "transform": int(m["transform"])}


def save_intent(layout):
    os.makedirs(os.path.dirname(INTENT), exist_ok=True)
    with open(INTENT, "w") as f:
        json.dump([_norm(m) for m in layout], f)


def load_intent():
    try:
        with open(INTENT) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def drifted(intent, live):
    """Names of monitors in `intent` whose live state differs. Monitors not connected are ignored."""
    cur = {m["name"]: _norm(m) for m in live}
    bad = []
    for want in intent:
        got = cur.get(want["name"])
        if got is None:
            continue
        if want["enabled"] != got["enabled"]:
            bad.append(want["name"])
        elif want["enabled"] and (
                (want["width"], want["height"], want["x"], want["y"], want["transform"])
                != (got["width"], got["height"], got["x"], got["y"], got["transform"])
                or abs(want["refresh"] - got["refresh"]) > 0.1
                or abs(want["scale"] - got["scale"]) > 0.001):
            bad.append(want["name"])
    return bad


def key_of(m):
    """Stable identity: description (make/model/serial), not the port name."""
    return m["description"]


def list_monitors():
    return backends.current().list_monitors()


def logical_size(m):
    w, h = m["width"] / m["scale"], m["height"] / m["scale"]
    return (h, w) if m["transform"] in (1, 3, 5, 7) else (w, h)


def _fmt(v):
    return ("%.8f" % v).rstrip("0").rstrip(".")


def validate(layout):
    if not [m for m in layout if m.get("enabled", True)]:
        raise ValueError("refusing to disable every monitor")
    for m in layout:
        if m.get("enabled", True) and m["scale"] <= 0:
            raise ValueError("scale must be > 0")


def _settled(layout):
    """What the compositor actually ended up with: it may snap a scale to the nearest valid
    value (2560 wide: 1.5 -> 1.6) or pick a different refresh. Intent must record that, or the
    daemon would see the snap as drift forever."""
    time.sleep(0.3)
    live = {m["name"]: m for m in list_monitors()}
    out = []
    for m in layout:
        g = live.get(m["name"])
        if g is None or not m.get("enabled", True) or not g["enabled"]:
            out.append(m)
        else:
            out.append({"name": g["name"], "enabled": True, "width": g["width"], "height": g["height"],
                        "refresh": g["refresh"], "x": m["x"], "y": m["y"], "scale": g["scale"],
                        "transform": g["transform"]})
    return out


def apply_layout(layout):
    """Apply [{name, enabled, mode|width/height/refresh, x, y, scale, transform}] live."""
    validate(layout)
    # enable/configure first, disable last, so we never pass through zero monitors
    ordered = sorted(layout, key=lambda m: not m.get("enabled", True))
    backends.current().apply_layout(ordered, _fmt)
    save_intent(_settled(layout))


def snapshot():
    return [{k: m[k] for k in ("name", "enabled", "width", "height", "refresh", "x", "y", "scale", "transform")}
            for m in list_monitors()]
