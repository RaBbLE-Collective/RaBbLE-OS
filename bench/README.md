# bench

Frame-pacing and power benchmark for the niri desktop.

    make                          # builds frametap (needs wayland-client, wayland-scanner)
    python3 bench.py LABEL [N]    # runs N trials per scenario on workspace 4, restores focus

Scenarios: overview open/close, workspace switch. Reports first-callback latency, max frame gap,
dropped frames per trial (gap > 1.5 vsync), niri CPU time, peak iGPU clock, and idle dGPU draw.
Results land in /tmp/rabble-bench/LABEL.json. Run on battery in the Quiet profile to match daily use.
Compare runs by LABEL (e.g. `before-nvidia-render` vs `after-amd-render`).
