#!/usr/bin/env bash
# config/hypr/scripts/float-top.sh
# One-key "float on top" toggle for the focused window.
#   tiled                -> float, size to ~60% of its monitor, center, pin on top
#   floating, not pinned -> pin on top (stay as-is)
#   floating + pinned    -> unpin and return to tiling
# Bare `pin` is a no-op on tiled windows in Hyprland, hence the float step.
# Lua-config dispatch (Hyprland 0.56): see smart-focus.sh.

d() { hyprctl dispatch "$1" >/dev/null 2>&1; }

read -r floating pinned mon < <(hyprctl activewindow -j | jq -r '"\(.floating) \(.pinned) \(.monitor)"')
[ "$floating" = "null" ] && exit 0

if [ "$floating" = "true" ] && [ "$pinned" = "true" ]; then
    d 'hl.dsp.window.pin({ action = "disable" })'
    d 'hl.dsp.window.float({ action = "disable" })'
    exit 0
fi

if [ "$floating" != "true" ]; then
    read -r w h < <(hyprctl monitors -j | jq -r --argjson m "$mon" '.[]|select(.id==$m)|"\((.width/.scale*0.6)|floor) \((.height/.scale*0.6)|floor)"')
    d 'hl.dsp.window.float({ action = "enable" })'
    d "hl.dsp.window.resize({ x = $w, y = $h, exact = true })"
    d 'hl.dsp.window.center()'
fi
d 'hl.dsp.window.pin({ action = "enable" })'
d 'hl.dsp.window.bring_to_top()'
