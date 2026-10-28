#!/usr/bin/env bash
# split-dir-daemon.sh — persistent split direction enforcer
#
# Watches Hyprland's event socket. After a new tiled window opens next to at
# least one other tiled window on its workspace, re-applies the split direction
# so the *next* window also goes right (h) or below (v). This makes Super+T a
# true persistent toggle.
#
# Skips floating windows and the first window on a workspace: a preselect set
# on a lone window is never consumed and later skews moves and new placements.
#
# State file: /tmp/.hypr_split  (h = horizontal/right, v = vertical/below)
# Managed by: toggle-split.sh
#
# Started by autostart.conf via exec-once.

STATE=/tmp/.hypr_split
SOCK="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"

socat -U - "UNIX-CONNECT:$SOCK" | while IFS= read -r line; do
    if [[ "$line" == openwindow* ]]; then
        addr="0x${line#openwindow>>}"; addr="${addr%%,*}"
        # openwindow>>ADDR,WS,CLASS,TITLE — keep only tiled windows with a tiled sibling
        tiled=$(hyprctl -j clients 2>/dev/null | jq -r --arg a "$addr" '
            (map(select(.address == $a)) | first) as $w
            | if ($w == null or $w.floating) then 0
              else [.[] | select(.workspace.id == $w.workspace.id and (.floating | not) and .mapped)] | length end')
        [[ "${tiled:-0}" -ge 2 ]] || continue
        if [[ "$(cat "$STATE" 2>/dev/null)" == "v" ]]; then
            hyprctl dispatch 'hl.dsp.layout("preselect d")' >/dev/null 2>&1
        else
            hyprctl dispatch 'hl.dsp.layout("preselect r")' >/dev/null 2>&1
        fi
    fi
done
