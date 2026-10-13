#!/usr/bin/env bash
# wsctl.sh — per-monitor workspaces. Each monitor owns a block of 10 real
# workspaces and shows them as 1..10: monitor index i (eDP first, then by name)
# maps N -> i*10+N. One monitor behaves exactly like plain 1..10.
#   wsctl.sh base [OUTPUT]            print the monitor's block offset
#   wsctl.sh focus N [OUTPUT]         switch OUTPUT's (default: focused) workspace N
#   wsctl.sh move N                   move active window to focused monitor's N
#   wsctl.sh cycle +1|-1              next/prev within focused monitor's 1..10
out_name() { hyprctl monitors -j | jq -r '.[]|select(.focused)|.name'; }
base() {
    local out="${1:-$(out_name)}"
    hyprctl monitors -j | jq -r --arg o "$out" \
        '[.[].name]|sort_by(startswith("eDP")|not, .)|index($o)//0|.*10'
}
cmd="$1"; shift
case "$cmd" in
    base) base "$1" ;;
    focus)
        n="$1"; out="${2:-$(out_name)}"
        [ "$out" != "$(out_name)" ] && hyprctl dispatch "hl.dsp.focus({monitor=\"$out\"})" >/dev/null
        hyprctl dispatch "hl.dsp.focus({workspace=$(( $(base "$out") + n ))})" ;;
    move)
        hyprctl dispatch "hl.dsp.window.move({workspace=$(( $(base) + $1 ))})" ;;
    cycle)
        b=$(base); cur=$(hyprctl activeworkspace -j | jq -r '.id')
        n=$(( (cur - b - 1 + $1 + 10) % 10 + 1 ))
        hyprctl dispatch "hl.dsp.focus({workspace=$(( b + n ))})" ;;
esac
