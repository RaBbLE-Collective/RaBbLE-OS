#!/usr/bin/env python3
"""Idle power + resource benchmark. No root, no subprocesses while sampling (so it adds no load).

    idle.py run LABEL [duration_s=180] [settle_s=60]
    idle.py compare LABEL_A LABEL_B

Leave the machine alone while it runs: on battery, Quiet profile, lid open, no input.
Samples every 5 s: battery W, APU W, iGPU clock, dGPU runtime state, CPU busy, free memory.
Per-process CPU and wakeups (context switches/s) are summed by command name over the window.
Results: /tmp/rabble-bench/idle-LABEL.json. Compare by LABEL (e.g. baseline vs after-tweak).
"""
import glob, json, os, statistics as st, sys, time

OUT = "/tmp/rabble-bench"; os.makedirs(OUT, exist_ok=True)
STEP = 5
CLK = os.sysconf("SC_CLK_TCK")

def rd(p):
    try: return open(p).read().strip()
    except OSError: return ""

def hwmon(name):
    for h in glob.glob("/sys/class/hwmon/hwmon*"):
        if rd(f"{h}/name") == name: return h
    return ""

BAT = next(iter(glob.glob("/sys/class/power_supply/BAT*")), "")
AC = next(iter(glob.glob("/sys/class/power_supply/AC*")), "")
AMD = hwmon("amdgpu")
IGPU = next((d for d in glob.glob("/sys/class/drm/card[0-9]/device") if rd(f"{d}/vendor") == "0x1002"), "")
DGPU = next((d for d in glob.glob("/sys/bus/pci/devices/*")
             if rd(f"{d}/vendor") == "0x10de" and rd(f"{d}/class").startswith("0x03")), "")

def bat_w():
    try: return int(rd(f"{BAT}/current_now")) * int(rd(f"{BAT}/voltage_now")) / 1e12
    except ValueError: return 0.0

def apu_w():
    try: return int(rd(f"{AMD}/power1_average")) / 1e6
    except ValueError: return 0.0

def sclk():
    for l in rd(f"{IGPU}/pp_dpm_sclk").splitlines():
        if l.rstrip().endswith("*"): return int(l.split(":")[1].strip().split("M")[0])
    return 0

def cpu_times():
    v = list(map(int, rd("/proc/stat").splitlines()[0].split()[1:]))
    return sum(v), v[3] + v[4]  # total, idle+iowait

def mem_avail_mb():
    for l in rd("/proc/meminfo").splitlines():
        if l.startswith("MemAvailable"): return int(l.split()[1]) / 1024
    return 0.0

def irqs():
    n = 0
    for l in rd("/proc/interrupts").splitlines()[1:]:
        n += sum(int(x) for x in l.split()[1:] if x.isdigit())
    return n

def procs():
    """pid -> (comm, cpu ticks, ctx switches, rss MB)"""
    out = {}
    for d in glob.glob("/proc/[0-9]*"):
        try:
            s = open(f"{d}/stat").read()
            comm = s[s.index("(") + 1:s.rindex(")")]
            f = s[s.rindex(")") + 2:].split()
            ticks = int(f[11]) + int(f[12])
            sw = 0
            for l in open(f"{d}/status"):
                if "ctxt_switches" in l: sw += int(l.split()[1])
                elif l.startswith("VmRSS"): rss = int(l.split()[1]) / 1024
            out[int(d[6:])] = (comm, ticks, sw, rss)
        except (OSError, ValueError, UnboundLocalError):
            pass
    return out

def dgpu_users():
    n = 0
    for d in glob.glob("/proc/[0-9]*/fd/*"):
        try:
            if os.readlink(d).startswith("/dev/nvidia"): n += 1
        except OSError: pass
    return n

def run(label, dur, settle):
    prof = rd("/sys/firmware/acpi/platform_profile")
    pre = {"on_ac": rd(f"{AC}/online") == "1", "battery_status": rd(f"{BAT}/status"),
           "battery_pct": rd(f"{BAT}/capacity"), "platform_profile": prof,
           "brightness": [rd(b) for b in glob.glob("/sys/class/backlight/*/brightness")],
           "compositor": os.environ.get("XDG_CURRENT_DESKTOP", "?"), "dgpu_fds": dgpu_users(), "kernel": os.uname().release}
    print(f"pre: {json.dumps(pre)}")
    if pre["on_ac"]: print("WARNING: on AC. Battery draw reads 0; unplug for real numbers.")
    print(f"settling {settle}s, then sampling {dur}s. Hands off.")
    time.sleep(settle)

    p0, irq0, c0, t0 = procs(), irqs(), cpu_times(), time.time()
    rows = []
    while time.time() - t0 < dur:
        a = cpu_times(); time.sleep(STEP); b = cpu_times()
        tot = b[0] - a[0]
        rows.append({"bat_w": bat_w(), "apu_w": apu_w(), "sclk": sclk(),
                     "cpu_busy": 100 * (1 - (b[1] - a[1]) / tot) if tot else 0.0,
                     "mem_mb": mem_avail_mb(),
                     "dgpu": rd(f"{DGPU}/power/runtime_status") + "/" + rd(f"{DGPU}/power_state")})
    el = time.time() - t0
    p1, irq1 = procs(), irqs()

    agg = {}
    for pid, (comm, tk, sw, rss) in p1.items():
        if pid not in p0: continue
        _, tk0, sw0, _ = p0[pid]
        r = agg.setdefault(comm, {"cpu_pct": 0.0, "wakeups_s": 0.0, "rss_mb": 0.0, "n": 0})
        r["cpu_pct"] += 100 * (tk - tk0) / CLK / el
        r["wakeups_s"] += (sw - sw0) / el
        r["rss_mb"] += rss; r["n"] += 1
    col = lambda k: [r[k] for r in rows]
    dg = col("dgpu")
    res = {"label": label, "pre": pre, "duration_s": round(el), "samples": len(rows),
           "bat_w_median": st.median(col("bat_w")), "bat_w_mean": st.mean(col("bat_w")),
           "bat_w_max": max(col("bat_w")), "apu_w_mean": st.mean(col("apu_w")),
           "igpu_mhz_mean": st.mean(col("sclk")), "cpu_busy_mean": st.mean(col("cpu_busy")),
           "mem_avail_mb": st.mean(col("mem_mb")), "irq_per_s": (irq1 - irq0) / el,
           "dgpu_states": {s: dg.count(s) for s in set(dg)}, "dgpu_fds_end": dgpu_users(),
           "top_cpu": sorted(((c, round(v["cpu_pct"], 2)) for c, v in agg.items()), key=lambda x: -x[1])[:10],
           "top_wakeups": sorted(((c, round(v["wakeups_s"], 1)) for c, v in agg.items()), key=lambda x: -x[1])[:10],
           "top_rss": sorted(((c, round(v["rss_mb"])) for c, v in agg.items()), key=lambda x: -x[1])[:10]}
    path = f"{OUT}/idle-{label}.json"
    json.dump(res, open(path, "w"), indent=1)
    show(res); print(f"saved {path}")

def show(r):
    print(f"\n== {r['label']}  ({r['duration_s']} s, {r['samples']} samples)")
    print(f"battery   median {r['bat_w_median']:.2f} W  mean {r['bat_w_mean']:.2f}  max {r['bat_w_max']:.2f}")
    print(f"APU       {r['apu_w_mean']:.2f} W   iGPU {r['igpu_mhz_mean']:.0f} MHz   CPU busy {r['cpu_busy_mean']:.1f}%")
    print(f"memory    {r['mem_avail_mb']:.0f} MB available   interrupts {r['irq_per_s']:.0f}/s")
    print(f"dGPU      {r['dgpu_states']}   open fds at end: {r['dgpu_fds_end']}")
    for k, unit in (("top_cpu", "% CPU"), ("top_wakeups", "wakeups/s"), ("top_rss", "MB RSS")):
        print(f"{k:12}" + "  ".join(f"{c} {v}" for c, v in r[k][:6]) + f"   [{unit}]")

def compare(a, b):
    A, B = (json.load(open(f"{OUT}/idle-{x}.json")) for x in (a, b))
    print(f"{'metric':16}{a:>14}{b:>14}{'delta':>10}")
    for k in ("bat_w_median", "bat_w_mean", "apu_w_mean", "igpu_mhz_mean", "cpu_busy_mean", "irq_per_s", "mem_avail_mb"):
        print(f"{k:16}{A[k]:14.2f}{B[k]:14.2f}{B[k] - A[k]:+10.2f}")
    print(f"{'dgpu_states':16}{A['dgpu_states']}  ->  {B['dgpu_states']}")

if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) >= 2 and a[0] == "run":
        run(a[1], int(a[2]) if len(a) > 2 else 180, int(a[3]) if len(a) > 3 else 60)
    elif len(a) == 3 and a[0] == "compare":
        compare(a[1], a[2])
    else:
        sys.exit(__doc__)
