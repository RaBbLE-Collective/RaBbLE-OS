"""Compositor/desktop backends. A backend module provides:
  NAME, detect() -> bool, list_monitors() -> [monitor dict], apply_layout(layout, fmt)
Monitor dict: name, description, enabled, width, height, refresh, x, y, scale, transform, modes[].
Planned: gnome (Mutter DisplayConfig D-Bus), kde (kscreen-doctor), wlroots (wlr-randr / wlr-output-management).
"""
import importlib

ORDER = ["hyprland"]


def current():
    for n in ORDER:
        mod = importlib.import_module("." + n, __name__)
        if mod.detect():
            return mod
    raise RuntimeError("no supported display backend detected (supported: %s)" % ", ".join(ORDER))
