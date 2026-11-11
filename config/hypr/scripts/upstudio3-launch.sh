#!/bin/bash
# upstudio3-launch.sh — launch UP Studio 3 (Cetus3D MK2, via Bottles) and lay
# out its windows: main app dominant on the left, Wand 3D Printer Manager in
# a right-hand column, side by side on workspace 6, no overlap.
#
# windowrule `size`/`move` do NOT stick for these windows (confirmed
# 2026-07-27 — float and workspace assignment apply fine via windowrule, but
# geometry doesn't; these are XWayland clients under Bottles and something
# about that combination resists windowrule-imposed geometry even though the
# rules parse cleanly with no errors). `hyprctl dispatch resizewindowpixel` /
# `movewindowpixel` by window address DOES work reliably against a settled
# window — but applying it the instant the window is first detected loses a
# race: both apps visibly resize/reposition THEMSELVES shortly after their
# window first appears (DPI-awareness + CEF layout settling), which
# overwrites whatever we just set. Confirmed 2026-07-27 by placing a window
# immediately after detection (silently ineffective — reverted to the app's
# own default geometry within a second or two) vs. placing it a couple
# seconds later (sticks). Fix: wait a settle period after first detecting
# each window, THEN place it, then re-check and re-place once more as a
# safety net in case of a second late self-resize. float + workspace
# assignment still come from windowrules.conf (those work fine there); this
# script only handles the geometry that doesn't.

set -u

BOTTLE="UPStudio3"
PROGRAM="UP Studio3"
MAIN_TITLE="UP Studio3 3.3.4"
WAND_TITLE="Wand 3D Printer Manager"
TIMEOUT_S=30

flatpak run --command=bottles-cli com.usebottles.bottles run -b "$BOTTLE" -p "$PROGRAM" &
disown

# Current (focused) monitor's resolution — layout is computed relative to
# this so it's not hardcoded to one panel.
read -r MON_W MON_H < <(hyprctl -j monitors | jq -r '.[] | select(.focused==true) | "\(.width) \(.height)"')
MON_W="${MON_W:-3840}"
MON_H="${MON_H:-2400}"

# Side-by-side columns: 2% margins, 2% gap between, main dominant (68%),
# Wand secondary (28%). Both share the same top/bottom margins (4%/96%).
MAIN_X=$(( MON_W * 2 / 100 ))
MAIN_Y=$(( MON_H * 4 / 100 ))
MAIN_W=$(( MON_W * 68 / 100 ))
MAIN_H=$(( MON_H * 92 / 100 ))

WAND_X=$(( MON_W * 72 / 100 ))
WAND_Y=$(( MON_H * 4 / 100 ))
WAND_W=$(( MON_W * 28 / 100 ))
WAND_H=$(( MON_H * 92 / 100 ))

# Poll for a window's Hyprland address by exact title match.
wait_for_window() {
    local title="$1" waited=0 addr=""
    while (( waited < TIMEOUT_S )); do
        addr=$(hyprctl -j clients | jq -r --arg t "$title" '.[] | select(.title==$t) | .address' | head -1)
        [[ -n "$addr" ]] && { echo "$addr"; return 0; }
        sleep 0.5
        waited=$(( waited + 1 ))
    done
    return 1
}

place_window() {
    local addr="$1" x="$2" y="$3" w="$4" h="$5"
    # If the app has put itself in fullscreen (observed on Wand at least
    # once), resize/move are no-ops until that's cleared.
    local fs
    fs=$(hyprctl -j clients | jq -r --arg a "$addr" '.[] | select(.address==$a) | .fullscreen')
    if [[ "$fs" != "0" ]]; then
        hyprctl dispatch focuswindow "address:$addr" >/dev/null
        hyprctl dispatch fullscreen 0 >/dev/null
    fi
    hyprctl dispatch resizewindowpixel "exact $w $h,address:$addr" >/dev/null
    hyprctl dispatch movewindowpixel "exact $x $y,address:$addr" >/dev/null
}

# Settle time before the FIRST placement attempt — the app's own post-open
# resize (DPI-awareness / CEF layout) happens in this window; placing before
# it settles just gets overwritten.
SETTLE_S=3
# Extra delay before the safety-net re-placement, in case of a second, later
# self-resize.
RECHECK_S=2

place_settled() {
    local title="$1" x="$2" y="$3" w="$4" h="$5" addr=""
    addr=$(wait_for_window "$title") || return 1
    sleep "$SETTLE_S"
    # address can change if the app recreated its window during startup —
    # re-resolve by title rather than trusting the first address found.
    addr=$(wait_for_window "$title") || return 1
    place_window "$addr" "$x" "$y" "$w" "$h"
    sleep "$RECHECK_S"
    addr=$(wait_for_window "$title") || return 0
    place_window "$addr" "$x" "$y" "$w" "$h"
}

place_settled "$MAIN_TITLE" "$MAIN_X" "$MAIN_Y" "$MAIN_W" "$MAIN_H" &
place_settled "$WAND_TITLE" "$WAND_X" "$WAND_Y" "$WAND_W" "$WAND_H" &
wait
