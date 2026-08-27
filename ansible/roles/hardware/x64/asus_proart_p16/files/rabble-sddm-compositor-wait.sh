#!/usr/bin/sh
# RaBbLE-OS: retry-guard for the plymouth->DRM-master handoff race (S207/S216/S223/S224).
#
# S207's sddm.service ordering fix (After=plymouth-quit-wait.service) narrowed
# the race but did not close it: "Finished plymouth-quit-wait.service" only
# means plymouth's own `quit` client process exited, not that plymouthd (a
# separate long-running daemon) has actually released DRM master yet. sway's
# KMS backend does a single non-retrying open() and exits on EBUSY when it
# loses that residual race:
#   sway: [ERROR] Failed to open device: '/dev/dri/rabble-amdgpu-card': Device or resource busy
#   sway: [ERROR] Found 0 GPUs, cannot create backend
# The greeter session then closes and the login screen never appears — no
# way in but a TTY (real-boot evidence, S211, reproduced again S224).
#
# S223 FIX WAS WRONG: it relaunched sway and used "did the process live
# >=500ms" as a proxy for "was that a real session, not a crash." On this
# hardware sway takes ~850-900ms to actually log its failure and exit after
# losing the EBUSY race (S224 real-boot journal) — ABOVE the 500ms bar — so
# the wrapper classified its own crash as a legitimate session and gave up
# after one try. Same black screen, disguised as a fix.
#
# S224: wait on the real signal instead of guessing from elapsed time. DRM
# master is tied to plymouthd's open fd on the device; once the plymouthd
# process itself has exited (not just its `quit` client), the kernel has
# released master and the device is guaranteed openable. Poll for that,
# bounded, before ever invoking sway — no relaunch-and-time heuristic needed.

max_wait_ms=4000
delay_ms=100
waited_ms=0
while pgrep -x plymouthd >/dev/null 2>&1; do
    if [ "$waited_ms" -ge "$max_wait_ms" ]; then
        break
    fi
    sleep 0.1
    waited_ms=$((waited_ms + delay_ms))
done

exec env WLR_DRM_DEVICES=/dev/dri/rabble-amdgpu-card /usr/libexec/sddm-compositor-sway "$@"
