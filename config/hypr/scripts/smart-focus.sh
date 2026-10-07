#!/usr/bin/env bash
# smart-focus.sh — directional focus with cyclenext fallback (i3-style)
#
# In dwindle, movefocus silently does nothing when there's no window in the
# requested direction. This script detects that and cycles to next/prev window
# so up/down always does something useful.
#
# Usage: smart-focus.sh [u|d|l|r]

dir="${1:-d}"

# Lua-config dispatch (Hyprland 0.56): legacy `hyprctl dispatch movefocus l`
# is a Lua syntax error now, so use hl.dsp.* forms with full direction names.
case "$dir" in l) dname=left ;; r) dname=right ;; u) dname=up ;; *) dname=down ;; esac

before=$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty')
hyprctl dispatch "hl.dsp.focus({ direction = \"$dname\" })" >/dev/null 2>&1
after=$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty')

[[ -n "$before" && "$before" != "$after" ]] && exit 0

# Focus didn't move — cycle
case "$dir" in
    u|l) hyprctl dispatch 'hl.dsp.window.cycle_next({ next = false })' >/dev/null ;;
    d|r) hyprctl dispatch 'hl.dsp.window.cycle_next()' >/dev/null ;;
esac
