#!/usr/bin/sh
# RaBbLE-OS: retry-guard for the plymouth->DRM-master handoff race (S207/S216/S223).
#
# S207's sddm.service ordering fix (After=plymouth-quit-wait.service) narrowed
# the race but did not close it: "Finished plymouth-quit-wait.service" only
# means plymouth's own `quit` client process exited, not that plymouthd (a
# separate long-running daemon) has actually released DRM master yet. sway's
# KMS backend does a single non-retrying open() and exits immediately on
# EBUSY when it loses that residual race:
#   sway: [ERROR] Failed to open device: '/dev/dri/rabble-amdgpu-card': Device or resource busy
#   sway: [ERROR] Found 0 GPUs, cannot create backend
# The greeter session then closes ~1s later and the login screen never
# appears — no way in but a TTY (real-boot evidence, S223).
#
# A genuine hardware failure (missing driver, dead GPU) fails identically on
# every retry, so this can't mask a real fault — it only rides out a
# sub-second startup race that "Finished" ordering alone can't guarantee away.

dev=/dev/dri/rabble-amdgpu-card
max_tries=8
delay=0.15
i=1
while [ "$i" -le "$max_tries" ]; do
    start_ms=$(date +%s%3N)
    env WLR_DRM_DEVICES="$dev" /usr/libexec/sddm-compositor-sway "$@"
    status=$?
    end_ms=$(date +%s%3N)
    elapsed=$((end_ms - start_ms))
    # A real session only exits when sddm kills it at logout/switch — well
    # over a second later. An exit under 500ms means startup crashed.
    if [ "$elapsed" -ge 500 ]; then
        exit "$status"
    fi
    i=$((i + 1))
    sleep "$delay"
done

# Out of retries — run the real thing one last time so the failure and its
# actual error output surface normally instead of being swallowed here.
exec env WLR_DRM_DEVICES="$dev" /usr/libexec/sddm-compositor-sway "$@"
