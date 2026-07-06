#!/usr/bin/env bash
# power-profile.sh — cycle the three composite RaBbLE-OS power modes; output Waybar JSON.
#
# Works against tuned-ppd's power-profiles-daemon-COMPATIBLE D-Bus interface —
# NOT power-profiles-daemon itself, which must never be installed on this
# machine (conflicts with tuned; see arbitration.yml's guard task and
# RaBbLE-Grimoire/RaBbLE-OS/RaBbLE-OS-AgentGuide.md:64-66). `powerprofilesctl`
# is the same CLI either way — tuned-ppd just answers on the same bus name.
#
# Each mode below sets BOTH halves together:
#   - powerprofilesctl (tuned-ppd's PPD-compatible profile)
#   - asusctl's platform-profile (asusd)
# The asusd side is what actually carries the fan curve — Balanced's curve is
# the QUIET one (not stock), configured once in arbitration.yml, not by this
# script. This script only picks which platform-profile is active.
#
#   Mode              | powerprofilesctl | asusd platform-profile | AC gate
#   ------------------|-------------------|-------------------------|--------
#   Quiet · Low Power | power-saver       | Quiet                   | any
#   Quiet · Balanced  | balanced          | Balanced (quiet curve)  | any
#   Unbounded         | performance       | Performance             | AC only
#
# Selecting Unbounded while on battery is BLOCKED (notify-send warning, stays
# on the current mode) — Unbounded is AC-only by policy. The udev-triggered
# fallback in power-ac-fallback.sh is the backstop for AC being pulled while
# Unbounded is already active; this in-script check is the front door.
#
# FIX: removed %PROFILE_SHIFT% placeholder from notify-send.
# FIX: cycle now sends SIGRTMIN+8 to waybar to force immediate refresh.
#
# Usage:
#   power-profile.sh get    — print current composite mode as Waybar JSON
#   power-profile.sh cycle  — advance to next mode, notify (or block if AC-gated)

# Mode table — index-aligned across all four arrays.
MODE_NAMES=("quiet-low-power" "quiet-balanced" "unbounded")
PPD_PROFILES=("power-saver" "balanced" "performance")
ASUS_PROFILES=("Quiet" "Balanced" "Performance")
ICONS=("󰌪" "󰗑" "󱐋")
TIPS=("Quiet · Low Power — max battery life" "Quiet · Balanced — CPU headroom, fans held quiet" "Unbounded — max clocks, fans unrestricted (AC only)")

is_on_ac() {
    # ProArt P16 AC supply node is AC*/online under /sys/class/power_supply.
    # Fall back to "assume AC" only if no AC node is found at all (desktop-class
    # host with no battery), so the gate never falsely blocks on hardware that
    # has no concept of unplugged.
    local ac_node
    for ac_node in /sys/class/power_supply/A*/online /sys/class/power_supply/AC*/online; do
        [[ -f "$ac_node" ]] || continue
        if [[ "$(cat "$ac_node" 2>/dev/null)" == "1" ]]; then
            return 0
        else
            return 1
        fi
    done
    return 0
}

get_current_index() {
    local current
    current=$(powerprofilesctl get 2>/dev/null)
    for i in "${!PPD_PROFILES[@]}"; do
        [[ "${PPD_PROFILES[$i]}" == "$current" ]] && echo "$i" && return
    done
    echo 1  # default to Quiet · Balanced if unknown
}

apply_mode() {
    local idx="$1"
    powerprofilesctl set "${PPD_PROFILES[$idx]}"
    # CONFIRM SYNTAX against installed asusctl version at apply time — flag
    # name has drifted across asusctl releases (-P/--profile-set vs -p/--profile).
    asusctl profile -P "${ASUS_PROFILES[$idx]}"
}

case "$1" in
    get)
        idx=$(get_current_index)
        printf '{"text":"%s  %s","tooltip":"%s","class":"%s"}\n' \
            "${ICONS[$idx]}" "${MODE_NAMES[$idx]}" "${TIPS[$idx]}" "${MODE_NAMES[$idx]}"
        ;;
    cycle)
        idx=$(get_current_index)
        next=$(( (idx + 1) % ${#MODE_NAMES[@]} ))

        # Unbounded (index 2) is AC-only — block the transition on battery.
        if [[ "${MODE_NAMES[$next]}" == "unbounded" ]] && ! is_on_ac; then
            notify-send "Power Profile" \
                "Unbounded is AC-only — plug in to use it. Staying on ${TIPS[$idx]}." \
                --icon=battery-caution-symbolic -t 3000
            pkill -SIGRTMIN+8 waybar
            exit 0
        fi

        apply_mode "$next"
        notify-send "Power Profile" "${TIPS[$next]}" \
            --icon=battery-symbolic -t 2000
        # Signal Waybar to refresh this custom module immediately
        pkill -SIGRTMIN+8 waybar
        ;;
    *)
        echo "Usage: $0 {get|cycle}" >&2
        exit 1
        ;;
esac
