#!/usr/bin/env bash
# toggle-split.sh — i3-style split direction toggle with OSD
#
# Sets where the NEXT new window will open: right (→) or below (↓).
# Does NOT rearrange existing windows. Matches i3's split h / split v.
#
# Preselect is consumed by the next new window, then dwindle returns to
# its default (right). Press Super+T again before each window you want
# to open below. For persistent vertical mode, see: spawn a daemon that
# re-applies preselect on each openwindow socket event.
#
# Usage: bound to a key, no arguments.

STATE=/tmp/.hypr_split

current=$(cat "$STATE" 2>/dev/null || echo "h")

if [ "$current" = "h" ]; then
    echo "v" > "$STATE"
    hyprctl dispatch 'hl.dsp.layout("preselect d")'
    notify-send -t 1200 -u low "" "Split  ↓  vertical"
else
    echo "h" > "$STATE"
    hyprctl dispatch 'hl.dsp.layout("preselect r")'
    notify-send -t 1200 -u low "" "Split  →  horizontal"
fi
