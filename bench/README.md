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
