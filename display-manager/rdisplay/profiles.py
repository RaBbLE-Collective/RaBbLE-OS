"""Named profiles, keyed by monitor description so port renames don't break them."""
import json
import os
import re
from . import core

DIR = os.path.expanduser("~/.config/rabble/display/profiles")
SLUG = re.compile(r"^[A-Za-z0-9_-]{1,40}$")


def _path(name):
    if not SLUG.match(name):
        raise ValueError("profile name must be 1-40 chars of A-Za-z0-9_-")
    return os.path.join(DIR, name + ".json")


def list_profiles():
    if not os.path.isdir(DIR):
        return []
    return sorted(f[:-5] for f in os.listdir(DIR) if f.endswith(".json"))


def load(name):
    with open(_path(name)) as f:
        return json.load(f)


def save(name, layout=None):
    layout = layout if layout is not None else core.list_monitors()
    prof = {"name": name, "monitors": [
        {"key": core.key_of(m), "hint": m["name"], "enabled": m["enabled"],
         "mode": "%dx%d@%s" % (m["width"], m["height"], core._fmt(m["refresh"])),
         "x": m["x"], "y": m["y"], "scale": m["scale"], "transform": m["transform"]}
        for m in layout]}
    os.makedirs(DIR, exist_ok=True)
    with open(_path(name), "w") as f:
        json.dump(prof, f, indent=2)
    return prof


def delete(name):
    os.remove(_path(name))


def to_layout(prof, connected):
    """Map profile entries onto currently connected outputs by description."""
    by_key = {}
    for m in connected:
        by_key.setdefault(core.key_of(m), []).append(m["name"])
    layout, used = [], set()
    for e in prof["monitors"]:
        names = [n for n in by_key.get(e["key"], []) if n not in used]
        if not names:
            continue
        name = e["hint"] if e["hint"] in names else names[0]
        used.add(name)
        layout.append({"name": name, **{k: e[k] for k in ("enabled", "mode", "x", "y", "scale", "transform")}})
    return layout


def match(connected):
    """Best profile: one whose monitor set equals the connected set."""
    keys = sorted(core.key_of(m) for m in connected)
    for name in list_profiles():
        if sorted(e["key"] for e in load(name)["monitors"]) == keys:
            return name
    return None
