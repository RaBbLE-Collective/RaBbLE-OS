"""Hotplug daemon (Hyprland). Replaces hdmi-hotplug.sh.

On monitoradded/monitorremoved it waits for events to settle (a KVM switch looks like
unplug+replug), then: applies the profile matching the connected set, makes sure every
enabled monitor has a waybar bar, and pins workspace 11 to the first external output.
Removal never migrates workspaces itself; Hyprland already does that."""
import json
import os
import socket
import subprocess
import sys
import threading
import time

from . import core, profiles

DEBOUNCE = 2.0
HDMI_WS = 11


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


def notify(title, body):
    subprocess.run(["notify-send", "-u", "normal", title, body], check=False)


def _bars():
    """Monitors that currently have a waybar layer."""
    r = subprocess.run(["hyprctl", "layers", "-j"], capture_output=True, text=True)
    have = set()
    for mon, data in json.loads(r.stdout or "{}").items():
        for layers in data.get("levels", {}).values():
            if any(l.get("namespace") == "waybar" for l in layers):
                have.add(mon)
    return have


def ensure_bars(mons):
    want = {m["name"] for m in mons if m["enabled"]}
    missing = want - _bars()
    if not missing:
        return
    log("waybar missing on", sorted(missing), "-> restarting")
    subprocess.run(["pkill", "-x", "waybar"], check=False)
    time.sleep(0.5)
    subprocess.Popen(["waybar"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def reconcile():
    mons = core.list_monitors()
    prof = profiles.match(mons)
    if prof:
        layout = profiles.to_layout(profiles.load(prof), mons)
        if layout:
            log("applying profile", prof)
            core.apply_layout(layout)
            mons = core.list_monitors()
    else:
        log("no profile for", sorted(m["name"] for m in mons))
    ext = [m["name"] for m in mons if m["enabled"] and not m["name"].startswith("eDP")]
    if ext:
        subprocess.run(["hyprctl", "dispatch", 'hl.dsp.workspace.move({ id = %d, monitor = "%s" })'
                        % (HDMI_WS, ext[0])], capture_output=True)
    time.sleep(0.5)
    ensure_bars(mons)
    return mons


def run():
    sig = os.environ["HYPRLAND_INSTANCE_SIGNATURE"]
    path = os.path.join(os.environ["XDG_RUNTIME_DIR"], "hypr", sig, ".socket2.sock")
    timer = {"t": None}
    known = {m["name"] for m in core.list_monitors()}

    def fire():
        nonlocal known
        try:
            mons = reconcile()
            now = {m["name"] for m in mons}
            for n in sorted(now - known):
                notify("Monitor connected", n)
            for n in sorted(known - now):
                notify("Monitor disconnected", n)
            known = now
        except Exception as e:
            log("reconcile failed:", e)

    def poke():
        if timer["t"]:
            timer["t"].cancel()
        timer["t"] = threading.Timer(DEBOUNCE, fire)
        timer["t"].daemon = True
        timer["t"].start()

    log("daemon up; watching", path)
    poke()  # settle once at startup
    with socket.socket(socket.AF_UNIX) as s:
        s.connect(path)
        buf = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                raise SystemExit("hyprland socket closed")
            buf += chunk
            *lines, buf = buf.split(b"\n")
            for ln in lines:
                if ln.startswith((b"monitoradded>", b"monitorremoved>")):
                    log("event", ln.decode(errors="replace"))
                    poke()
