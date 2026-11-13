#!/usr/bin/env bash
# dgpu-watch.sh: log every dGPU wake/sleep and who holds the NVIDIA nodes while it is awake.
# No driver contact (sysfs + /proc only), so it cannot keep the card up. Run in a spare terminal; Ctrl-C ends.
# Root daemons (nvidia-powerd, supergfxd) are invisible without sudo: run `sudo ./dgpu-watch.sh` to see them.
D=$(for d in /sys/bus/pci/devices/*; do [ "$(cat $d/vendor)" = 0x10de ] && [ "$(cut -c1-4 $d/class)" = 0x03 ] && echo $d && break; done)
N=$(readlink -f /dev/dri/by-path/$(basename "$D")-render)
holders() {
    for f in /proc/[0-9]*/fd/*; do
        case "$(readlink "$f" 2>/dev/null)" in /dev/nvidia*|"$N") p=${f#/proc/}; p=${p%%/*}; echo "$(cat /proc/$p/comm 2>/dev/null)($p)";; esac
    done | sort | uniq -c | tr '\n' ' '
}
prev=""
while :; do
    s=$(cat "$D/power/runtime_status")
    if [ "$s" != "$prev" ]; then
        echo "$(date +%T.%N | cut -c1-12)  $s  $([ "$s" = suspended ] || holders)"; prev=$s
    elif [ "$s" = active ]; then
        h=$(holders); [ -n "$h" ] && echo "$(date +%T.%N | cut -c1-12)  active  $h"
    fi
    sleep 0.3
done
