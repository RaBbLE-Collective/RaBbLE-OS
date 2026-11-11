#!/usr/bin/sh
# RaBbLE-OS: retry-guard for the plymouth->DRM-master handoff race (S207/S216/S223/S224/S226/S228).
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
# way in but a TTY (real-boot evidence, S211, reproduced again S224, S226).
#
# S223 FIX WAS WRONG: it relaunched sway and used "did the process live
# >=500ms" as a proxy for "was that a real session, not a crash." On this
# hardware sway takes ~850-900ms to actually log its failure and exit after
# losing the EBUSY race (S224 real-boot journal) — ABOVE the 500ms bar — so
# the wrapper classified its own crash as a legitimate session and gave up
# after one try. Same black screen, disguised as a fix.
#
# S224 FIX WAS ALSO WRONG: it polled `pgrep -x plymouthd` and only launched
# sway once the daemon process itself was gone, on the theory that DRM
# master is tied to plymouthd's fd and its exit guarantees the device is
# free. Real-boot journal (S226) disproves it: sway's KMS open() still hit
# EBUSY on the very first launch, ~330ms after plymouth-quit-wait finished.
# Process absence is not a reliable proxy for "master released" on this
# hardware — there is no advance signal for that, so guessing the wait
# window (short or long) is the wrong shape of fix entirely.
#
# S226: stop predicting and retry the actual operation. Launch sway for
# real; if it exits fast with the specific EBUSY signature (not a generic
# timing guess — S223's mistake), retry after a short delay, bounded. A
# real working session runs until logout and never matches the grep, so
# this can't misfire on a legitimate session the way the elapsed-time
# heuristic did.

max_attempts=10
delay_s=0.25
device=/dev/dri/rabble-amdgpu-card
# S228: /run is root:root 0755 — the greeter runs as the unprivileged `sddm`
# user (not root), so a fixed /run path can't be created here and every
# redirection below silently failed to open, meaning sway never even
# launched (real-boot journal, S228: "Permission denied" on this path,
# then "No such file or directory" on every later read of it). /tmp is
# sticky-writable by any user; mktemp also sidesteps any collision between
# concurrent greeter launches.
out="$(mktemp /tmp/rabble-sddm-compositor-wait.XXXXXX)"

attempt=1
while [ "$attempt" -le "$max_attempts" ]; do
    env WLR_DRM_DEVICES="$device" /usr/libexec/sddm-compositor-sway "$@" >"$out" 2>&1
    status=$?
    cat "$out" >&2
    if ! grep -q "Device or resource busy" "$out"; then
        rm -f "$out"
        exit "$status"
    fi
    attempt=$((attempt + 1))
    sleep "$delay_s"
done

rm -f "$out"
exit "$status"
