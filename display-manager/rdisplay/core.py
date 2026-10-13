"""Backend-agnostic monitor model helpers; all compositor I/O goes through rdisplay.backends."""
from . import backends


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


def apply_layout(layout):
    """Apply [{name, enabled, mode|width/height/refresh, x, y, scale, transform}] live."""
    validate(layout)
    # enable/configure first, disable last, so we never pass through zero monitors
    ordered = sorted(layout, key=lambda m: not m.get("enabled", True))
    backends.current().apply_layout(ordered, _fmt)


def snapshot():
    return [{k: m[k] for k in ("name", "enabled", "width", "height", "refresh", "x", "y", "scale", "transform")}
            for m in list_monitors()]
