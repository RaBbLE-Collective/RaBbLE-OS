"""Shared GTK theming: Aether tokens (read from aether.css, single source) -> @define-color + cairo rgb."""
import os
import re

import gi
gi.require_version("Gdk", "4.0")
gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, Gtk  # noqa: E402

AETHER = os.path.expanduser("~/RaBbLE-Collective/RaBbLE-Aether/dist/aether.css")
TOKENS = ("bg", "surface", "border", "text", "cyan", "magenta", "dimmer")
_cache = {}


def tokens():
    if not _cache:
        try:
            src = open(AETHER).read()
            for t in TOKENS:
                m = re.search(r"--rabble-%s:\s*#([0-9a-fA-F]{6})\s*;" % t, src)
                if m:
                    _cache[t] = "#" + m.group(1)
        except OSError:
            pass
    return _cache


def rgb(name, fallback=(0.5, 0.5, 0.5)):
    h = tokens().get(name)
    return tuple(int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)) if h else fallback


def css():
    t = tokens()
    if "bg" not in t:
        return ""
    defs = "".join("@define-color r_%s %s;\n" % (k, v) for k, v in t.items())
    return defs + """
    window.rd { background: @r_bg; color: @r_text; }
    .rd label { color: @r_text; }
    .rd label.title { color: @r_cyan; font-weight: 600; font-size: 16px; }
    .rd label.dim { color: @r_dimmer; font-size: 12px; }
    .rd label.err { color: @r_magenta; font-size: 12px; }
    .rd .panel { background: @r_surface; border: 1px solid @r_border; border-radius: 12px; padding: 12px; }
    .rd button { background: @r_surface; color: @r_text; border: 1px solid @r_border; border-radius: 8px; padding: 6px 14px; }
    .rd button:hover { border-color: @r_cyan; }
    .rd button.cur, .rd button.primary { border-color: @r_cyan; color: @r_cyan; }
    .rd button.danger { border-color: @r_magenta; color: @r_magenta; }
    .rd .warn { border: 1px solid @r_magenta; border-radius: 8px; padding: 8px; }
    .rd entry, .rd spinbutton, .rd dropdown > button { background: @r_bg; color: @r_text; border: 1px solid @r_border; border-radius: 6px; }
    """


def install():
    c = css()
    if c:
        p = Gtk.CssProvider()
        p.load_from_string(c)
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), p, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
