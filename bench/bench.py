#!/usr/bin/env python3
"""niri animation benchmark: frame pacing + clocks + power. Usage: bench.py LABEL [trials]

Runs on workspace 4 ("scratch") so it does not disturb other windows, then restores focus.
Needs ./frametap (make). Writes /tmp/rabble-bench/LABEL.json and prints a summary.
Frame pacing comes from frametap (passive frame callbacks); a gap > 1.5 vsync = dropped frame.
"""
import json, os, signal, statistics as st, subprocess, sys, threading, time

LABEL = sys.argv[1] if len(sys.argv) > 1 else "run"
TRIALS = int(sys.argv[2]) if len(sys.argv) > 2 else 12
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = "/tmp/rabble-bench"; os.makedirs(OUT, exist_ok=True)
GPU = "/sys/class/drm/card1/device"
APU_W = "/sys/class/hwmon/hwmon7/power1_average"
BAT = "/sys/class/power_supply/BAT1"
VSYNC = 16.667

def rd(p):
    try: return open(p).read().strip()
    except OSError: return ""
def sclk():
    for l in rd(f"{GPU}/pp_dpm_sclk").splitlines():
        if l.rstrip().endswith("*"): return int(l.split(":")[1].strip().split("M")[0])
    return 0
def bat_w():
    try: return int(rd(f"{BAT}/current_now")) * int(rd(f"{BAT}/voltage_now")) / 1e12
    except ValueError: return 0.0
def nvidia():
    """dGPU draw in W and runtime state; the dGPU awake while idle is the thing to catch."""
    r = subprocess.run(["nvidia-smi", "--query-gpu=power.draw", "--format=csv,noheader,nounits"], capture_output=True, text=True)
    w = r.stdout.strip() if r.returncode == 0 else "n/a"
    st_ = rd("/sys/bus/pci/devices/0000:64:00.0/power/runtime_status") or "?"
    return w, st_
def niri(*a):
    return subprocess.run(["niri", "msg", "action", *a], capture_output=True, text=True)
def niri_pid():
    return int(subprocess.run(["pidof", "niri"], capture_output=True, text=True).stdout.split()[0])
def cpu_ticks(pid):
    f = rd(f"/proc/{pid}/stat").rsplit(")", 1)[1].split()
    return int(f[11]) + int(f[12])
TICK = os.sysconf("SC_CLK_TCK")

samples = []; stop = threading.Event()
def sampler():
    while not stop.is_set():
        samples.append((time.monotonic(), sclk(), int(rd(f"{GPU}/gpu_busy_percent") or 0),
                        int(rd(APU_W) or 0) / 1e6))
        time.sleep(0.02)

def frames(path):
    return [int(x) / 1e6 for x in open(path).read().split()]

def idle_wait(max_s=6.0):
    """Wait until the GPU clock has dropped to its lowest level (the state the user feels)."""
    t0 = time.monotonic()
    while time.monotonic() - t0 < max_s:
        if sclk() <= 800: break
        time.sleep(0.1)
    time.sleep(0.4)
    return sclk()

def main():
    if not os.path.exists(f"{HERE}/frametap"): sys.exit("build first: make")
    orig = [w for w in subprocess.run(["niri", "msg", "workspaces"], capture_output=True, text=True).stdout.splitlines() if w.startswith(" *")]
    orig_idx = orig[0].split()[1] if orig else "1"
    ftp = f"{OUT}/{LABEL}.frames"
    niri("focus-workspace", "4"); time.sleep(0.6)
    tap = subprocess.Popen([f"{HERE}/frametap", ftp]); time.sleep(1.5)
    pid = niri_pid()
    th = threading.Thread(target=sampler, daemon=True); th.start()
    res = {"label": LABEL, "trials": TRIALS, "scenarios": {}}
    try:
        # idle: the tap sits still, so niri should be doing nothing; this is the baseline cost.
        time.sleep(1.0); i0 = time.monotonic(); c0 = cpu_ticks(pid); time.sleep(6.0)
        i1 = time.monotonic(); c1 = cpu_ticks(pid)
        res["idle"] = {"niri_cpu_pct": round(100 * (c1 - c0) / TICK / (i1 - i0), 2),
                       "battery_w": round(bat_w(), 1), "sclk": sclk(),
                       "nvidia_w": nvidia()[0], "nvidia_state": nvidia()[1]}
        scen = {
            "overview": [("open-overview",), ("close-overview",)],
            "ws_switch": [("focus-workspace", "5"), ("focus-workspace", "4")],
        }
        for name, acts in scen.items():
            rows = []
            for n in range(TRIALS):
                for k, act in enumerate(acts):
                    s0 = idle_wait()
                    cpu0 = cpu_ticks(pid)
                    tap.send_signal(signal.SIGUSR1)   # start logging right as the animation is triggered
                    t0 = time.monotonic(); niri(*act); t1 = time.monotonic()
                    time.sleep(0.7)
                    tap.send_signal(signal.SIGUSR2); time.sleep(0.1)
                    fr = [t for t in frames(ftp) if t0 <= t <= t0 + 0.7]
                    iv = [(b - a) * 1000 for a, b in zip(fr, fr[1:])]
                    sm = [s for s in samples if t0 <= s[0] <= t0 + 0.7]
                    rows.append({"dir": k, "idle_sclk": s0, "ipc_ms": round((t1 - t0) * 1000, 1),
                                 "first_cb_ms": round((fr[0] - t0) * 1000, 1) if fr else None,
                                 "frames": len(fr),
                                 "max_gap_ms": round(max(iv), 1) if iv else None,
                                 "dropped": sum(1 for x in iv if x > VSYNC * 1.5),
                                 "peak_sclk": max((s[1] for s in sm), default=0),
                                 "peak_gpu_pct": max((s[2] for s in sm), default=0),
                                 "niri_cpu_ms": round((cpu_ticks(pid) - cpu0) * 1000 / TICK)})
            res["scenarios"][name] = rows
    finally:
        stop.set(); tap.terminate(); tap.wait(timeout=3)
        niri("focus-workspace", orig_idx)
    json.dump(res, open(f"{OUT}/{LABEL}.json", "w"), indent=1)

    print(f"\n== {LABEL} ==  idle (tap attached): niri {res['idle']['niri_cpu_pct']}% CPU, "
          f"battery {res['idle']['battery_w']} W, sclk {res['idle']['sclk']} MHz, "
          f"dGPU {res['idle']['nvidia_w']} W ({res['idle']['nvidia_state']})")
    print(f"{'scenario':<10} {'n':>3} {'1st cb ms':>10} {'max gap ms':>11} {'drops/trial':>12} {'frames':>7} {'peak sclk':>10} {'peak gpu%':>10} {'niri cpu ms':>12}")
    for name, rows in res["scenarios"].items():
        def m(k): v = [r[k] for r in rows if r[k] is not None]; return st.median(v) if v else float("nan")
        print(f"{name:<10} {len(rows):>3} {m('first_cb_ms'):>10.1f} {m('max_gap_ms'):>11.1f} {sum(r['dropped'] for r in rows)/len(rows):>12.2f} "
              f"{m('frames'):>7.0f} {m('peak_sclk'):>10.0f} {m('peak_gpu_pct'):>10.0f} {m('niri_cpu_ms'):>12.0f}")
main()
