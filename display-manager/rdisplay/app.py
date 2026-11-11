"""Native GTK4 display editor: its own window (single instance), no browser, no server.
Hyprland floats + centers it on the screen it was launched from (windowrules.lua, class APP_ID)."""
import sys

import gi
gi.require_version("Gdk", "4.0")
gi.require_version("Gtk", "4.0")
from gi.repository import GLib, Gtk  # noqa: E402

from . import core, gtkstyle, profiles  # noqa: E402

APP_ID = "world.rabble.rdisplay"
REVERT = 15


def _parse(s):
    r, hz = s.split("@")
    w, h = r.split("x")
    return int(w), int(h), float(hz)


def _label(text, cls=None, xalign=0):
    lb = Gtk.Label(label=text, xalign=xalign)
    if cls:
        lb.add_css_class(cls)
    return lb


class Editor(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="RaBbLE Displays")
        self.add_css_class("rd")
        self.set_default_size(1040, 700)
        self.mons, self.sel = [], None
        self.k, self.ox, self.oy = 0.1, 0, 0
        self.drag = None          # (monitor, start x, start y) while dragging; transform frozen
        self.prev, self.timer, self.left = None, None, 0
        self._loading = False

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, margin_top=14, margin_bottom=14,
                       margin_start=14, margin_end=14)
        self.set_child(root)
        root.append(_label("RaBbLE Displays", "title"))

        self.banner = Gtk.Revealer()
        bar = Gtk.Box(spacing=10)
        bar.add_css_class("warn")
        self.blabel = Gtk.Label(xalign=0, hexpand=True)
        bar.append(self.blabel)
        keep = Gtk.Button(label="Keep"); keep.add_css_class("primary"); keep.connect("clicked", lambda *_: self.keep())
        undo = Gtk.Button(label="Revert"); undo.add_css_class("danger"); undo.connect("clicked", lambda *_: self.revert())
        bar.append(keep); bar.append(undo)
        self.banner.set_child(bar)
        root.append(self.banner)

        body = Gtk.Box(spacing=14, vexpand=True)
        root.append(body)

        left = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, hexpand=True)
        self.canvas = Gtk.DrawingArea(hexpand=True, vexpand=True)
        self.canvas.set_draw_func(self.draw)
        g = Gtk.GestureDrag()
        g.connect("drag-begin", self.drag_begin)
        g.connect("drag-update", self.drag_update)
        g.connect("drag-end", self.drag_end)
        self.canvas.add_controller(g)
        left.append(self.canvas)
        row = Gtk.Box(spacing=8)
        ap = Gtk.Button(label="Apply"); ap.add_css_class("primary"); ap.connect("clicked", lambda *_: self.apply())
        rs = Gtk.Button(label="Reset to live"); rs.connect("clicked", lambda *_: self.reload())
        row.append(ap); row.append(rs)
        row.append(_label("Drag monitors to arrange. Edges and centers snap. Apply reverts itself unless you keep it.", "dim"))
        left.append(row)
        self.err = _label("", "err"); left.append(self.err)
        body.append(left)

        side = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        side.set_size_request(320, -1)
        body.append(side)
        side.append(self._monitor_panel())
        side.append(self._profile_panel())
        self.reload()

    # -- panels ---------------------------------------------------------------------
    def _monitor_panel(self):
        p = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        p.add_css_class("panel")
        self.mname = _label("Monitor", "title"); p.append(self.mname)
        self.mdesc = _label("", "dim"); self.mdesc.set_wrap(True); p.append(self.mdesc)

        self.enabled = Gtk.CheckButton(label="Enabled")
        self.enabled.connect("toggled", lambda w: self._edit("enabled", w.get_active()))
        p.append(self.enabled)

        p.append(_label("Resolution @ refresh", "dim"))
        self.modes = Gtk.DropDown.new_from_strings([""])
        self.modes.connect("notify::selected", self._on_mode)
        p.append(self.modes)

        p.append(_label("Scale", "dim"))
        self.scale = Gtk.SpinButton.new_with_range(0.5, 4.0, 0.05)
        self.scale.set_digits(3)
        self.scale.connect("value-changed", lambda w: self._edit("scale", w.get_value()))
        p.append(self.scale)

        p.append(_label("Rotation", "dim"))
        self.rot = Gtk.DropDown.new_from_strings(["Normal", "90°", "180°", "270°"])
        self.rot.connect("notify::selected", self._on_rot)
        p.append(self.rot)

        p.append(_label("Position (x, y)", "dim"))
        xy = Gtk.Box(spacing=6)
        self.px = Gtk.SpinButton.new_with_range(-20000, 20000, 1)
        self.py = Gtk.SpinButton.new_with_range(-20000, 20000, 1)
        self.px.connect("value-changed", lambda w: self._edit("x", int(w.get_value())))
        self.py.connect("value-changed", lambda w: self._edit("y", int(w.get_value())))
        xy.append(self.px); xy.append(self.py)
        p.append(xy)

        n = _label("Only modes the monitor advertises are listed. A missing refresh rate means the monitor input, "
                   "cable, adapter or KVM is not offering it.", "dim")
        n.set_wrap(True)
        p.append(n)
        return p

    def _profile_panel(self):
        p = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        p.add_css_class("panel")
        p.append(_label("Profiles", "title"))
        self.plist = Gtk.DropDown.new_from_strings([""])
        p.append(self.plist)
        r = Gtk.Box(spacing=6)
        a = Gtk.Button(label="Apply"); a.connect("clicked", lambda *_: self.apply_profile())
        d = Gtk.Button(label="Delete"); d.add_css_class("danger"); d.connect("clicked", lambda *_: self.delete_profile())
        r.append(a); r.append(d)
        p.append(r)
        p.append(_label("Save current arrangement as", "dim"))
        r2 = Gtk.Box(spacing=6)
        self.pname = Gtk.Entry(placeholder_text="desk-2screen", hexpand=True)
        s = Gtk.Button(label="Save"); s.connect("clicked", lambda *_: self.save_profile())
        r2.append(self.pname); r2.append(s)
        p.append(r2)
        self.pstate = _label("", "dim"); p.append(self.pstate)
        return p

    # -- state ------------------------------------------------------------------------
    def reload(self):
        try:
            self.mons = core.list_monitors()
            self.err.set_text("")
        except Exception as e:
            self.err.set_text(str(e)); return
        if not any(m["name"] == self.sel for m in self.mons):
            self.sel = self.mons[0]["name"] if self.mons else None
        names = profiles.list_profiles()
        self.plist.set_model(Gtk.StringList.new(names or [""]))
        cur = profiles.match(self.mons)
        if cur in names:
            self.plist.set_selected(names.index(cur))
        self.pstate.set_text("matches profile: %s" % cur if cur else "no profile matches these monitors")
        self.fill_panel(); self.canvas.queue_draw()

    def cur(self):
        return next((m for m in self.mons if m["name"] == self.sel), None)

    def fill_panel(self):
        m = self.cur()
        self._loading = True
        try:
            if not m:
                self.mname.set_text("Monitor"); return
            self.mname.set_text(m["name"]); self.mdesc.set_text(m["description"])
            self.enabled.set_active(m["enabled"])
            seen, opts = set(), []
            for s in m["modes"]:
                w, h, hz = _parse(s)
                key = (w, h, round(hz, 2))
                if key not in seen:
                    seen.add(key); opts.append((w, h, hz))
            here = next((o for o in opts if o[:2] == (m["width"], m["height"]) and abs(o[2] - m["refresh"]) < 0.06), None)
            if not here:
                here = (m["width"], m["height"], m["refresh"]); opts.insert(0, here)
            self._opts = opts
            self.modes.set_model(Gtk.StringList.new(["%dx%d @ %g Hz" % (w, h, round(hz, 2)) for w, h, hz in opts]))
            self.modes.set_selected(opts.index(here))
            self.scale.set_value(m["scale"])
            self.rot.set_selected(m["transform"] % 4)
            self.px.set_value(m["x"]); self.py.set_value(m["y"])
        finally:
            self._loading = False

    def _edit(self, key, val):
        m = self.cur()
        if self._loading or not m:
            return
        m[key] = val
        self.canvas.queue_draw()

    def _on_mode(self, dd, _p):
        m = self.cur()
        if self._loading or not m or not getattr(self, "_opts", None):
            return
        i = dd.get_selected()
        if i < len(self._opts):
            m["width"], m["height"], m["refresh"] = self._opts[i]
            self.canvas.queue_draw()

    def _on_rot(self, dd, _p):
        m = self.cur()
        if self._loading or not m:
            return
        m["transform"] = (m["transform"] // 4) * 4 + dd.get_selected()
        self.canvas.queue_draw()

    # -- canvas -----------------------------------------------------------------------
    def fit(self, w, h):
        live = [m for m in self.mons if m["enabled"]] or self.mons
        if not live:
            return
        rects = [(m["x"], m["y"], *core.logical_size(m)) for m in live]
        x0 = min(r[0] for r in rects); y0 = min(r[1] for r in rects)
        x1 = max(r[0] + r[2] for r in rects); y1 = max(r[1] + r[3] for r in rects)
        W, H = x1 - x0 + 1400, y1 - y0 + 900            # headroom so monitors can be dragged outward
        self.k = max(min(w / W, h / H), 0.005)
        self.ox = (w - (x1 - x0) * self.k) / 2 - x0 * self.k
        self.oy = (h - (y1 - y0) * self.k) / 2 - y0 * self.k

    def _screen_rect(self, m):
        lw, lh = core.logical_size(m)
        return m["x"] * self.k + self.ox, m["y"] * self.k + self.oy, lw * self.k, lh * self.k

    def draw(self, _a, cr, w, h):
        if not self.drag:
            self.fit(w, h)
        cr.set_source_rgb(*gtkstyle.rgb("bg")); cr.paint()
        for m in self.mons:
            x, y, rw, rh = self._screen_rect(m)
            cr.rectangle(x, y, rw - 2, rh - 2)
            cr.set_source_rgb(*gtkstyle.rgb("surface")); cr.fill_preserve()
            if not m["enabled"]:
                cr.set_dash([6, 4])
            else:
                cr.set_dash([])
            cr.set_source_rgb(*gtkstyle.rgb("cyan" if m["name"] == self.sel else "border"))
            cr.set_line_width(2); cr.stroke()
            cr.set_source_rgb(*gtkstyle.rgb("text")); cr.set_font_size(14)
            cr.move_to(x + 10, y + 22); cr.show_text(m["name"])
            cr.set_source_rgb(*gtkstyle.rgb("dimmer")); cr.set_font_size(11)
            cr.move_to(x + 10, y + 40)
            cr.show_text("%dx%d @ %g Hz  scale %g" % (m["width"], m["height"], round(m["refresh"]), m["scale"])
                         if m["enabled"] else "disabled")

    def drag_begin(self, _g, sx, sy):
        hit = None
        for m in reversed(self.mons):
            x, y, rw, rh = self._screen_rect(m)
            if x <= sx <= x + rw and y <= sy <= y + rh:
                hit = m; break
        if not hit:
            return
        self.sel = hit["name"]
        self.drag = (hit, hit["x"], hit["y"])
        self.fill_panel(); self.canvas.queue_draw()

    def drag_update(self, _g, dx, dy):
        if not self.drag:
            return
        m, ox, oy = self.drag
        nx, ny = ox + dx / self.k, oy + dy / self.k
        w, h = core.logical_size(m)
        T = 14 / self.k
        for o in self.mons:
            if o is m or not o["enabled"]:
                continue
            ow, oh = core.logical_size(o)
            for t in (o["x"] + ow, o["x"] - w, o["x"], o["x"] + ow - w, o["x"] + (ow - w) / 2):
                if abs(nx - t) < T:
                    nx = t
            for t in (o["y"] + oh, o["y"] - h, o["y"], o["y"] + oh - h, o["y"] + (oh - h) / 2):
                if abs(ny - t) < T:
                    ny = t
        m["x"], m["y"] = round(nx), round(ny)
        self._loading = True
        self.px.set_value(m["x"]); self.py.set_value(m["y"])
        self._loading = False
        self.canvas.queue_draw()

    def drag_end(self, *_):
        self.drag = None
        self.canvas.queue_draw()

    # -- apply / revert ---------------------------------------------------------------
    def apply(self):
        try:
            if not self.timer:
                self.prev = core.snapshot()
            core.apply_layout(self.mons)
        except Exception as e:
            self.err.set_text(str(e)); return
        self._arm()
        self.reload()

    def apply_profile(self):
        name = self.plist.get_selected_item()
        name = name.get_string() if name else ""
        if not name:
            return
        try:
            layout = profiles.to_layout(profiles.load(name), core.list_monitors())
            if not layout:
                self.err.set_text("profile matches none of the connected monitors"); return
            if not self.timer:
                self.prev = core.snapshot()
            core.apply_layout(layout)
        except Exception as e:
            self.err.set_text(str(e)); return
        self._arm()
        self.reload()

    def _arm(self):
        if self.timer:
            GLib.source_remove(self.timer)
        self.left = REVERT
        self.timer = GLib.timeout_add_seconds(1, self._tick)
        self.blabel.set_text("Keep these display settings? Reverting in %ds" % self.left)
        self.banner.set_reveal_child(True)

    def _tick(self):
        self.left -= 1
        if self.left <= 0:
            self.revert(); return False
        self.blabel.set_text("Keep these display settings? Reverting in %ds" % self.left)
        return True

    def _disarm(self):
        if self.timer:
            GLib.source_remove(self.timer)
        self.timer = None
        self.banner.set_reveal_child(False)

    def keep(self):
        self._disarm(); self.prev = None

    def revert(self):
        self._disarm()
        if self.prev:
            try:
                core.apply_layout(self.prev)
            except Exception as e:
                self.err.set_text(str(e))
        self.prev = None
        self.reload()

    # -- profiles ---------------------------------------------------------------------
    def save_profile(self):
        name = self.pname.get_text().strip()
        try:
            profiles.save(name, self.mons)
        except Exception as e:
            self.err.set_text(str(e)); return
        self.pname.set_text("")
        self.reload()

    def delete_profile(self):
        item = self.plist.get_selected_item()
        if item and item.get_string():
            try:
                profiles.delete(item.get_string())
            except OSError as e:
                self.err.set_text(str(e))
        self.reload()


def run():
    app = Gtk.Application(application_id=APP_ID)   # single instance: relaunch re-presents the window
    Gtk.Window.set_default_icon_name("video-display")

    def activate(a):
        win = a.get_active_window()
        if win and win.timer:          # a keep/revert prompt is pending: never hide it, just raise
            win.present()
            return
        if win:                        # re-summoned: reopen so it lands on the screen it was called from
            win.destroy()
        gtkstyle.install()
        Editor(a).present()

    app.connect("activate", activate)
    return app.run(sys.argv[:1])
