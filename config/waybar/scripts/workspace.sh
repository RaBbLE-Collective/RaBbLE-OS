#!/usr/bin/env bash
# workspace.sh N — waybar custom module for one workspace button.
# Replaces hyprland/workspaces, whose built-in click sends legacy
# "dispatch workspace N" that Hyprland's Lua config (0.56+) rejects.
n="$1"
active=$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id')
windows=$(hyprctl workspaces -j 2>/dev/null | jq -r --argjson n "$n" '[.[]|select(.id==$n)|.windows]|first // 0')
cls=empty
[ "$windows" -gt 0 ] && cls=occupied
[ "$active" = "$n" ] && cls=active
printf '{"text":"%s","class":"%s"}\n' "$n" "$cls"
