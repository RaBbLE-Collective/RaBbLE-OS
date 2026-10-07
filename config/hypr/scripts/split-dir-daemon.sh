#!/usr/bin/env bash
# split-dir-daemon.sh — persistent split direction enforcer
#
# Watches Hyprland's event socket. After every new window opens, if the
# split state is "v", re-applies preselect d so the *next* window also
# goes below. This makes Super+T a true persistent toggle.
#
# State file: /tmp/.hypr_split  (h = horizontal/right, v = vertical/below)
# Managed by: toggle-split.sh
#
# Started by autostart.conf via exec-once.

STATE=/tmp/.hypr_split
SOCK="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"

socat -U - "UNIX-CONNECT:$SOCK" | while IFS= read -r line; do
    if [[ "$line" == openwindow* ]]; then
        if [[ "$(cat "$STATE" 2>/dev/null)" == "v" ]]; then
            hyprctl dispatch 'hl.dsp.layout("preselect d")' >/dev/null 2>&1
        else
            hyprctl dispatch 'hl.dsp.layout("preselect r")' >/dev/null 2>&1
        fi
    fi
done
