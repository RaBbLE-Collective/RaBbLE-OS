"""rdisplay list | mode <mon> <WxH@R> | scale <mon> <factor> | place <mon> <above|below|left|right> <ref> | apply <profile> | save <name> | profiles | delete <name> | revert | gui | daemon"""
import argparse
import json
import os
import select
import sys
import time

from . import core, profiles

STATE = os.path.expanduser("~/.cache/rabble/display/last.json")


def _remember():
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE, "w") as f:
        json.dump(core.snapshot(), f)


def _confirm(seconds):
    sys.stdout.write("Keep this layout? [y/N] (reverting in %ds) " % seconds)
    sys.stdout.flush()
    r, _, _ = select.select([sys.stdin], [], [], seconds)
    return bool(r) and sys.stdin.readline().strip().lower() == "y"


def place(layout, name, side, ref, align="center"):
    """Return layout with `name` positioned on `side` of `ref` (logical, scale-aware coordinates)."""
    by = {m["name"]: m for m in layout}
    for n in (name, ref):
        if n not in by:
            raise SystemExit("unknown monitor %r (have: %s)" % (n, ", ".join(by)))
    m, r = by[name], by[ref]
    mw, mh = core.logical_size(m)
    rw, rh = core.logical_size(r)
    off = {"start": 0, "center": 0.5, "end": 1}[align]
    if side in ("above", "below"):
        m["x"] = round(r["x"] + (rw - mw) * off)
        m["y"] = round(r["y"] - mh) if side == "above" else round(r["y"] + rh)
    else:
        m["y"] = round(r["y"] + (rh - mh) * off)
        m["x"] = round(r["x"] - mw) if side == "left" else round(r["x"] + rw)
    return layout


def main(argv=None):
    p = argparse.ArgumentParser(prog="rdisplay")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    sub.add_parser("profiles")
    sub.add_parser("revert")
    g = sub.add_parser("gui")
    g.add_argument("--port", type=int, default=8765)
    sub.add_parser("daemon")
    mo = sub.add_parser("mode")
    mo.add_argument("monitor")
    mo.add_argument("mode", help="WxH@R from `rdisplay list`/modes, e.g. 2560x1440@75")
    sc = sub.add_parser("scale")
    sc.add_argument("monitor")
    sc.add_argument("factor", type=float)
    pl = sub.add_parser("place")
    pl.add_argument("monitor")
    pl.add_argument("side", choices=["above", "below", "left", "right"])
    pl.add_argument("ref")
    pl.add_argument("--align", choices=["start", "center", "end"], default="center")
    pl.add_argument("--revert-in", type=int, default=15, help="0 = no confirm prompt")
    a = sub.add_parser("apply")
    a.add_argument("profile")
    a.add_argument("--revert-in", type=int, default=15, help="0 = no confirm prompt")
    s = sub.add_parser("save")
    s.add_argument("name")
    d = sub.add_parser("delete")
    d.add_argument("name")
    args = p.parse_args(argv)

    if args.cmd == "list":
        for m in core.list_monitors():
            state = "%dx%d@%s" % (m["width"], m["height"], core._fmt(m["refresh"])) if m["enabled"] else "disabled"
            print("%-10s %-14s at %dx%d scale %s transform %d  %s"
                  % (m["name"], state, m["x"], m["y"], m["scale"], m["transform"], m["description"]))
    elif args.cmd == "profiles":
        cur = profiles.match(core.list_monitors())
        for n in profiles.list_profiles():
            print(("* " if n == cur else "  ") + n)
    elif args.cmd == "save":
        profiles.save(args.name)
        print("saved", args.name)
    elif args.cmd == "delete":
        profiles.delete(args.name)
    elif args.cmd == "apply":
        connected = core.list_monitors()
        layout = profiles.to_layout(profiles.load(args.profile), connected)
        if not layout:
            sys.exit("profile %r matches none of the connected monitors" % args.profile)
        _remember()
        core.apply_layout(layout)
        if args.revert_in and not _confirm(args.revert_in):
            print("\nreverting")
            core.apply_layout(json.load(open(STATE)))
    elif args.cmd == "mode":
        layout = core.snapshot()
        m = next((x for x in layout if x["name"] == args.monitor), None)
        if not m:
            sys.exit("unknown monitor %r" % args.monitor)
        avail = {x["name"]: x["modes"] for x in core.list_monitors()}[args.monitor]
        want = next((a for a in avail if a.rstrip("0").rstrip(".") == args.mode.rstrip("0").rstrip(".") or a == args.mode), None)
        if not want:
            sys.exit("%s does not advertise %s. Offered: %s" % (args.monitor, args.mode, " ".join(avail)))
        _remember()
        w, rest = want.split("@")
        m["width"], m["height"] = map(int, w.split("x"))
        m["refresh"] = float(rest)
        core.apply_layout(layout)
    elif args.cmd == "scale":
        layout = core.snapshot()
        m = next((x for x in layout if x["name"] == args.monitor), None)
        if not m:
            sys.exit("unknown monitor %r" % args.monitor)
        _remember()
        m["scale"] = args.factor
        core.apply_layout(layout)
        lw, lh = core.logical_size(next(x for x in core.list_monitors() if x["name"] == args.monitor))
        print("logical size %.4g x %.4g" % (lw, lh))
    elif args.cmd == "place":
        layout = place(core.snapshot(), args.monitor, args.side, args.ref, args.align)
        _remember()
        core.apply_layout(layout)
        if args.revert_in and not _confirm(args.revert_in):
            print("\nreverting")
            core.apply_layout(json.load(open(STATE)))
    elif args.cmd == "daemon":
        from . import daemon
        daemon.run()
    elif args.cmd == "revert":
        core.apply_layout(json.load(open(STATE)))
    elif args.cmd == "gui":
        from . import server
        server.serve(args.port)


if __name__ == "__main__":
    main()
