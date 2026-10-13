#!/usr/bin/env bash
# power-profile.sh — show / cycle the RaBbLE-OS power mode; output Waybar JSON.
#
# asusd's platform-profile is the single source of truth. It carries the
# firmware power limits (kernel platform_profile), the CPU EPP (asusd.ron
# platform_profile_linked_epp) and the per-profile fan curves. Status is read
# straight from /sys/firmware/acpi/platform_profile, so it also reflects changes
# made by the ASUS Fn hotkey, an AC plug/unplug, or `asusctl` in a terminal —
# not just clicks on this module. (The old version read tuned-ppd's D-Bus profile
# via `powerprofilesctl`, which is not installed and does not follow asusd.)
#
#   Mode              | platform_profile | asusctl profile | AC gate
#   ------------------|------------------|-----------------|--------
#   Quiet · Low Power | quiet            | Quiet           | any
#   Quiet · Balanced  | balanced         | Balanced        | any
#   Unbounded         | performance      | Performance     | AC only
#
# Selecting Unbounded while on battery is BLOCKED (notify-send warning, stays
# on the current mode). power-ac-fallback.sh backstops AC being pulled while
# Unbounded is already active.
#
# Usage:
#   power-profile.sh get    — print current mode as Waybar JSON
#   power-profile.sh cycle  — advance to next mode, notify (or block if AC-gated)

PLATFORM_PROFILE=/sys/firmware/acpi/platform_profile

# Mode table — index-aligned across all arrays.
MODE_NAMES=("quiet-low-power" "quiet-balanced" "unbounded")
PLATFORM_NAMES=("quiet" "balanced" "performance")
ASUS_PROFILES=("Quiet" "Balanced" "Performance")
ICONS=("󰌪" "󰗑" "󱐋")
TIPS=("Quiet · Low Power — max battery life" "Quiet · Balanced — CPU headroom, fans held quiet" "Unbounded — max clocks, fans unrestricted (AC only)")

is_on_ac() {
    # Only the mains adapter counts. The USB-C ucsi-source-psy-* supplies also
    # expose `online` and read 0 on this machine; matching them would misreport.
    # Assume AC only when no adapter node exists at all (desktop-class host).
    local node
    for node in /sys/class/power_supply/AC*/online /sys/class/power_supply/ADP*/online; do
        [[ -f "$node" ]] || continue
        [[ "$(cat "$node" 2>/dev/null)" == "1" ]] && return 0
        return 1
    done
    return 0
}

# Prints the mode index for the live platform_profile, or nothing if unreadable
# or unknown (callers must not guess — a wrong status is worse than a visible one).
get_current_index() {
    local current i
    current=$(cat "$PLATFORM_PROFILE" 2>/dev/null) || return 1
    for i in "${!PLATFORM_NAMES[@]}"; do
        [[ "${PLATFORM_NAMES[$i]}" == "$current" ]] && echo "$i" && return 0
    done
    return 1
}

refresh_bar() { pkill -SIGRTMIN+8 waybar 2>/dev/null || true; }

case "$1" in
    get)
        if idx=$(get_current_index); then
            printf '{"text":"%s  %s","tooltip":"%s","class":"%s"}\n' \
                "${ICONS[$idx]}" "${MODE_NAMES[$idx]}" "${TIPS[$idx]}" "${MODE_NAMES[$idx]}"
        else
            printf '{"text":"󰀦  power-unknown","tooltip":"Cannot read %s (is asusd running?)","class":"unknown"}\n' \
                "$PLATFORM_PROFILE"
        fi
        ;;
    cycle)
        idx=$(get_current_index) || idx=1
        next=$(( (idx + 1) % ${#MODE_NAMES[@]} ))

        # Unbounded is AC-only — skip it on battery rather than dead-ending the cycle.
        if [[ "${MODE_NAMES[$next]}" == "unbounded" ]] && ! is_on_ac; then
            notify-send "Power Profile" \
                "Unbounded is AC-only — plug in to use it. Wrapping to ${TIPS[0]}." \
                --icon=battery-caution-symbolic -t 3000
            next=0
        fi

        if ! asusctl profile set "${ASUS_PROFILES[$next]}" >/dev/null 2>&1; then
            notify-send "Power Profile" "asusctl failed to set ${ASUS_PROFILES[$next]} — is asusd running?" \
                --icon=dialog-error-symbolic -t 4000
            refresh_bar
            exit 1
        fi

        # Report what actually happened, not what was requested.
        sleep 0.2
        if now=$(get_current_index) && [[ "$now" == "$next" ]]; then
            notify-send "Power Profile" "${TIPS[$next]}" --icon=battery-symbolic -t 2000
        else
            notify-send "Power Profile" "Requested ${ASUS_PROFILES[$next]} but the kernel reports '$(cat "$PLATFORM_PROFILE" 2>/dev/null)'." \
                --icon=dialog-warning-symbolic -t 4000
        fi
        refresh_bar
        ;;
    *)
        echo "Usage: $0 {get|cycle}" >&2
        exit 1
        ;;
esac
