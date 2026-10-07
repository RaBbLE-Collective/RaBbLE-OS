#!/usr/bin/env bash
# smart-movewindow.sh — directional window move with split-creation fallback
#
# For l/r: movewindow as normal.
# For u/d: tries movewindow first. If the window didn't move (no vertical
# neighbor because the current split is horizontal), it creates the vertical
# arrangement via togglesplit, then swaps to put the window in the right slot.
#
# Usage: smart-movewindow.sh [l|r|u|d]

dir="${1:-d}"

# Lua-config dispatch (Hyprland 0.56): legacy `hyprctl dispatch movewindow l`
# is a Lua syntax error now, so use hl.dsp.* forms with full direction names.
case "$dir" in l) dname=left ;; r) dname=right ;; u) dname=up ;; *) dname=down ;; esac

before=$(hyprctl activewindow -j 2>/dev/null | jq -r '.at | join(",")')
hyprctl dispatch "hl.dsp.window.move({ direction = \"$dname\" })" >/dev/null 2>&1
after=$(hyprctl activewindow -j 2>/dev/null | jq -r '.at | join(",")')

# Moved successfully — done
[[ "$before" != "$after" ]] && exit 0

# Didn't move — handle u/d by flipping the split
case "$dir" in
    d)
        # togglesplit turns A|B into A/B with focused window on top.
        # Swap down to put focused window in the bottom slot.
        hyprctl dispatch 'hl.dsp.layout("togglesplit")' >/dev/null
        hyprctl dispatch 'hl.dsp.window.swap({ direction = "down" })' >/dev/null 2>&1
        ;;
    u)
        # togglesplit turns A|B into A/B with focused window on top already.
        hyprctl dispatch 'hl.dsp.layout("togglesplit")' >/dev/null
        ;;
    l) hyprctl dispatch 'hl.dsp.window.move({ direction = "right" })' >/dev/null ;;
    r) hyprctl dispatch 'hl.dsp.window.move({ direction = "left" })' >/dev/null ;;
esac
