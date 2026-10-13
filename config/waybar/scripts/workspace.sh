#!/usr/bin/env bash
# workspace.sh N — waybar custom module for one workspace button on this bar's
# monitor ($WAYBAR_OUTPUT_NAME). Shows the monitor's own 1..10 (see hypr wsctl.sh).
# Replaces hyprland/workspaces, whose built-in click sends legacy
# "dispatch workspace N" that Hyprland's Lua config (0.56+) rejects.
n="$1"
out="${WAYBAR_OUTPUT_NAME:-}"
id=$(( $(~/.config/hypr/scripts/wsctl.sh base "$out") + n ))
active=$(hyprctl monitors -j | jq -r --arg o "$out" '.[]|select(.name==$o)|.activeWorkspace.id')
windows=$(hyprctl workspaces -j | jq -r --argjson n "$id" '[.[]|select(.id==$n)|.windows]|first // 0')
cls=empty
[ "$windows" -gt 0 ] && cls=occupied
[ "$active" = "$id" ] && cls=active
printf '{"text":"%s","class":"%s"}\n' "$n" "$cls"
