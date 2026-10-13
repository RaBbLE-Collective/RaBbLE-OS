"""GTK4 + layer-shell quick switcher: mini layout map, profile buttons, keep/revert prompt.
Run via `rdisplay overlay` (toggles: a second call closes the open one). Esc closes.
Needs LD_PRELOAD=libgtk4-layer-shell.so (cli re-execs itself with it)."""
import os
import re
import signal
import subprocess
import sys

import gi
gi.require_version("Gdk", "4.0")
gi.require_version("Gtk", "4.0")
gi.require_version("Gtk4LayerShell", "1.0")
from gi.repository import Gdk, GLib, Gtk, Gtk4LayerShell as LS  # noqa: E402

from . import core, profiles  # noqa: E402

AETHER = os.path.expanduser("~/RaBbLE-Collective/RaBbLE-Aether/dist/aether.css")
PIDFILE = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "rdisplay-overlay.pid")
REVERT = 15
TOKENS = ("bg", "surface", "border", "text", "cyan", "magenta", "dimmer")


def _css():
    """Aether tokens -> GTK @define-color, so the palette stays single-sourced in Aether."""
    defs = ""
    try:
        src = open(AETHER).read()
        for t in TOKENS:
            m = re.search(r"--rabble-%s:\s*(#[0-9a-fA-F]{3,8})\s*;" % t, src)
            if m:
                defs += "@define-color r_%s %s;\n" % (t, m.group(1))
    except OSError:
        pass
    if "r_bg" not in defs:
        return ""
    return defs + """
    window.rd { background: @r_bg; color: @r_text; border: 1px solid @r_border; border-radius: 12px; }
    .rd label.title { color: @r_cyan; font-weight: 600; font-size: 16px; }
    .rd label.dim { color: @r_dimmer; font-size: 12px; }
    .rd button { background: @r_surface; color: @r_text; border: 1px solid @r_border; border-radius: 8px; padding: 6px 14px; }
    .rd button:hover { border-color: @r_cyan; }
    .rd button.cur { border-color: @r_cyan; color: @r_cyan; }
    .rd button.danger { border-color: @r_magenta; color: @r_magenta; }
    .rd .warn { border: 1px solid @r_magenta; border-radius: 8px; padding: 8px; }
    """


class Overlay(Gtk.Window):
    def __init__(self, app):
        super().__init__(application=app, title="RaBbLE Displays")
        self.add_css_class("rd")
        LS.init_for_window(self)
        LS.set_layer(self, LS.Layer.OVERLAY)
        LS.set_namespace(self, "rdisplay-overlay")
        LS.set_keyboard_mode(self, LS.KeyboardMode.EXCLUSIVE)
        self.prev, self.timer, self.left = None, None, 0
        self.box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, margin_top=16, margin_bottom=16,
                           margin_start=18, margin_end=18)
        self.set_child(self.box)
        kc = Gtk.EventControllerKey()
        kc.connect("key-pressed", lambda c, k, *_: (self.close(), True)[1] if k == Gdk.KEY_Escape else False)
        self.add_controller(kc)
        self.render()

    # -- drawing ------------------------------------------------------------
    def _map(self, mons):
        area = Gtk.DrawingArea(content_width=420, content_height=200)
        live = [m for m in mons if m["enabled"]]

        def draw(_a, cr, w, h):
            if not live:
                return
            rects = [(m, *core.logical_size(m)) for m in live]
            x0 = min(m["x"] for m, _, _ in rects); y0 = min(m["y"] for m, _, _ in rects)
            x1 = max(m["x"] + lw for m, lw, _ in rects); y1 = max(m["y"] + lh for m, _, lh in rects)
            k = min((w - 20) / (x1 - x0), (h - 20) / (y1 - y0))
            ox, oy = (w - (x1 - x0) * k) / 2, (h - (y1 - y0) * k) / 2
            for m, lw, lh in rects:
                x, y = ox + (m["x"] - x0) * k, oy + (m["y"] - y0) * k
                cr.rectangle(x, y, lw * k - 2, lh * k - 2)
                cr.set_source_rgba(0.07, 0.07, 0.16, 1); cr.fill_preserve()
                cr.set_source_rgba(0, 0.96, 1, 1); cr.set_line_width(1.5); cr.stroke()
                cr.set_source_rgba(0.91, 0.9, 0.94, 1); cr.set_font_size(12)
                cr.move_to(x + 8, y + 18); cr.show_text(m["name"])
                cr.set_font_size(10); cr.move_to(x + 8, y + 33)
                cr.show_text("%dx%d@%g  x%g" % (m["width"], m["height"], round(m["refresh"]), m["scale"]))
        area.set_draw_func(draw)
        return area

    def render(self):
        b = self.box
        while (c := b.get_first_child()):
            b.remove(c)
        mons = core.list_monitors()
        t = Gtk.Label(label="Displays", xalign=0); t.add_css_class("title"); b.append(t)
        b.append(self._map(mons))
        if self.timer:
            warn = Gtk.Box(spacing=10); warn.add_css_class("warn")
            self.lbl = Gtk.Label(label="", hexpand=True, xalign=0); warn.append(self.lbl)
            keep = Gtk.Button(label="Keep"); keep.connect("clicked", lambda *_: self.keep()); warn.append(keep)
            rev = Gtk.Button(label="Revert"); rev.add_css_class("danger"); rev.connect("clicked", lambda *_: self.revert()); warn.append(rev)
            b.append(warn); self._tick_label()
        names = profiles.list_profiles()
        cur = profiles.match(mons)
        d = Gtk.Label(label="Profiles" if names else "No profiles saved. Use the editor to save one.", xalign=0)
        d.add_css_class("dim"); b.append(d)
        row = Gtk.Box(spacing=8)
        for n in names:
            btn = Gtk.Button(label=n)
            if n == cur:
                btn.add_css_class("cur")
            btn.connect("clicked", lambda _b, n=n: self.apply_profile(n))
            row.append(btn)
        b.append(row)
        foot = Gtk.Box(spacing=8)
        ed = Gtk.Button(label="Open editor"); ed.connect("clicked", lambda *_: self.editor()); foot.append(ed)
        cl = Gtk.Button(label="Close"); cl.connect("clicked", lambda *_: self.close()); foot.append(cl)
        b.append(foot)

    # -- actions --------------------------------------------------------------
    def apply_profile(self, name):
        try:
            mons = core.list_monitors()
            layout = profiles.to_layout(profiles.load(name), mons)
            if not layout:
                return
            if not self.timer:
                self.prev = core.snapshot()
            core.apply_layout(layout)
        except Exception as e:  # keep the overlay alive; surface in stderr
            print("apply failed:", e, file=sys.stderr)
            return
        if self.timer:
            GLib.source_remove(self.timer)
        self.left = REVERT
        self.timer = GLib.timeout_add_seconds(1, self._tick)
        self.render()

    def _tick_label(self):
        self.lbl.set_text("Keep these display settings? Reverting in %ds" % self.left)

    def _tick(self):
        self.left -= 1
        if self.left <= 0:
            self.revert()
            return False
        self._tick_label()
        return True

    def keep(self):
        if self.timer:
            GLib.source_remove(self.timer)
        self.timer = self.prev = None
        self.render()

    def revert(self):
        if self.timer:
            GLib.source_remove(self.timer)
        self.timer = None
        if self.prev:
            try:
                core.apply_layout(self.prev)
            except Exception as e:
                print("revert failed:", e, file=sys.stderr)
        self.prev = None
        self.render()

    def editor(self):
        subprocess.Popen([sys.executable, "-m", "rdisplay", "gui"], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
        GLib.timeout_add(700, lambda: subprocess.Popen(["xdg-open", "http://127.0.0.1:8765"]) and False)
        self.close()


def _toggle_existing():
    try:
        pid = int(open(PIDFILE).read())
        os.kill(pid, 0)
        os.kill(pid, signal.SIGTERM)
        return True
    except (OSError, ValueError):
        return False


def run():
    if _toggle_existing():
        return
    with open(PIDFILE, "w") as f:
        f.write(str(os.getpid()))
    app = Gtk.Application(application_id="world.rabble.rdisplay.overlay")

    def activate(a):
        css = _css()
        if css:
            p = Gtk.CssProvider(); p.load_from_string(css)
            Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), p, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        Overlay(a).present()

    app.connect("activate", activate)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, lambda: (app.quit(), False)[1])
    try:
        app.run([])
    finally:
        try:
            os.remove(PIDFILE)
        except OSError:
            pass
