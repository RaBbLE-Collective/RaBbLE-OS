#!/usr/bin/env bash
# power-ac-fallback.sh — AC-unplug safety gate for the "Unbounded" power mode.
#
# Source lives here in config/waybar/scripts/ alongside power-profile.sh (its
# waybar-facing counterpart), but this script does NOT run as the desktop user
# via waybar/dotctl — it is installed to /usr/local/bin/rabble-power-ac-fallback.sh
# by ansible/roles/hardware/x64/asus_proart_p16/tasks/arbitration.yml and invoked
# by a udev rule (/etc/udev/rules.d/90-rabble-power-ac.rules) as root, with no
# graphical session, whenever mains power is removed (power_supply online -> 0).
#
# Job: if "Unbounded" (tuned-ppd performance + asusd Performance platform-profile)
# is the currently active mode when AC drops, fall back to the AC-independent
# safe mode — Quiet · Balanced (tuned-ppd balanced + asusd Balanced, which per
# arbitration.yml carries the QUIET fan curve, not stock). Unbounded is AC-only
# by policy (see power-profile.sh); this is the enforcement backstop for the
# case where AC is pulled while it's already active, not the point of selection.
#
# Kept deliberately small/fast — udev RUN+= processes should not block; the
# udev rule wraps this in `systemd-run --no-block` so udev's own timeout can't
# kill it mid-flight.
#
# powerprofilesctl / asusctl profile talk to system-bus D-Bus services
# (tuned-ppd, asusd) — both reachable from root with no session bus needed.
# notify-send is the one piece that needs a real user session, so we reach
# into the active seat0 session's bus explicitly below.

set -uo pipefail

LOG_TAG="rabble-power-ac-fallback"

log() { logger -t "$LOG_TAG" -- "$*"; }

current_profile="$(powerprofilesctl get 2>/dev/null || echo unknown)"

if [[ "$current_profile" != "performance" ]]; then
    log "AC removed; active profile is '$current_profile' (not Unbounded) — no action."
    exit 0
fi

log "AC removed while Unbounded (performance) was active — falling back to Quiet · Balanced."

powerprofilesctl set balanced 2>&1 | logger -t "$LOG_TAG"

# CONFIRM SYNTAX against installed asusctl version at apply time — flag name
# has drifted across asusctl releases (-P/--profile-set vs -p/--profile).
asusctl profile -P Balanced 2>&1 | logger -t "$LOG_TAG"

# Best-effort desktop notification. This process has no XDG_RUNTIME_DIR/
# DBUS_SESSION_BUS_ADDRESS of its own (root, launched by udev) — find the
# active seat0 session's user and borrow theirs. Failure here is non-fatal;
# the power-mode fallback above already happened regardless.
session_id="$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4 == "seat0" { print $1; exit }')"
if [[ -n "$session_id" ]]; then
    target_user="$(loginctl show-session "$session_id" -p Name --value 2>/dev/null)"
    if [[ -n "$target_user" ]]; then
        target_uid="$(id -u "$target_user" 2>/dev/null || true)"
        if [[ -n "$target_uid" ]]; then
            runuser -u "$target_user" -- env \
                XDG_RUNTIME_DIR="/run/user/${target_uid}" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${target_uid}/bus" \
                notify-send "RaBbLE Power" \
                "AC unplugged — Unbounded is AC-only. Reverted to Quiet · Balanced." \
                --icon=battery-symbolic -t 4000 \
                2>&1 | logger -t "$LOG_TAG"
        fi
    fi
fi

# Nudge waybar to repaint the custom/power-profile module immediately, same
# refresh signal power-profile.sh's own `cycle` verb uses.
pkill -SIGRTMIN+8 waybar 2>/dev/null || true

exit 0
