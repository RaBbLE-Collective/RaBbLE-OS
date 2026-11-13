# bench

Frame-pacing and power benchmark for the niri desktop.

    make                          # builds frametap (needs wayland-client, wayland-scanner)
    python3 bench.py LABEL [N]    # runs N trials per scenario on workspace 4, restores focus

Scenarios: overview open/close, workspace switch. Reports first-callback latency, max frame gap,
dropped frames per trial (gap > 1.5 vsync), niri CPU time, peak iGPU clock, and idle dGPU draw.
Results land in /tmp/rabble-bench/LABEL.json. Run on battery in the Quiet profile to match daily use.
Compare runs by LABEL (e.g. `before-nvidia-render` vs `after-amd-render`).

## Idle power and resources

    python3 idle.py run LABEL [duration_s=180] [settle_s=60]   # unplugged, Quiet profile, hands off
    python3 idle.py compare LABEL_A LABEL_B

Samples battery W, APU W, iGPU clock, dGPU runtime state, CPU busy and free memory every 5 s with no
subprocesses, then ranks commands by CPU, wakeups/s and RSS over the window. No root needed.
Results land in /tmp/rabble-bench/idle-LABEL.json. Take a `baseline` first, change one thing, re-run.

### A/B: niri vs Hyprland idle

Same shell, same apps, same state, only the compositor differs. Log out between runs (a fresh session each).

1. Unplug. Quiet profile. Same brightness. Note both in your log.
2. Log in to niri. Open exactly: one kitty, nothing else. Wait 2 minutes for startup work to finish.
3. From that kitty (leave it unfocused-quiet, do not touch input):
   `python3 bench/idle.py run niri-a 180 60`
4. Log out, log in to Hyprland with the same single kitty: `python3 bench/idle.py run hypr-a 180 60`
5. Repeat both once more (`niri-b`, `hypr-b`, order swapped: Hyprland first) to catch drift and battery state.
6. `python3 bench/idle.py compare niri-a hypr-a` and `compare niri-b hypr-b`.

Trust a difference only if both pairs agree in direction and exceed the spread between a and b of the same compositor.
Read `bat_w_median` first, then `top_wakeups` (which command is waking the CPU) and `dgpu_states` (must stay suspended/D3cold).
The run records `XDG_CURRENT_DESKTOP` in `pre.compositor`, so check each JSON says what you think it does.
