#!/usr/bin/env bash
# audio-popup.sh — toggle a compact floating mixer popup for Waybar.
#
# Left-clicking the pulseaudio module runs this. First click opens the mixer as
# a small floating panel anchored top-right under the bar; clicking again
# dismisses it. float/size/opacity come from Hyprland windowrules keyed on the
# pavucontrol class (config/hypr/conf.d/windowrules.conf, ## Audio mixer popup);
# the top-right *position* is set here imperatively — Hyprland auto-centers new
# floats and ignores a `move` windowrule for this GTK app, so we place it after
# it maps. Resolution-independent: computed from the focused monitor's logical
# width, so it lands correctly at any scale.
#
# Volume *adjustment* goes through swayOSD (on-scroll / on-click-right in
# config.jsonc) — same themed OSD as the Fn keys. This popup is the full mixer
# (per-app routing, device pick) on demand.
set -euo pipefail

CLASS="org.pulseaudio.pavucontrol"
WIN_W=480      # must match the `size` windowrule
MARGIN=16      # gap from the right edge
TOP=40         # below the 30px bar + gap

# Toggle: already open → dismiss.
if pgrep -x pavucontrol >/dev/null 2>&1; then
    pkill -x pavucontrol
    exit 0
fi

setsid --fork pavucontrol >/dev/null 2>&1

# Wait for the window to map (up to ~1.5s), grab its address.
addr=""
for _ in $(seq 1 30); do
    addr=$(hyprctl clients -j 2>/dev/null \
        | python3 -c "import sys,json; w=[c for c in json.load(sys.stdin) if c['class']=='$CLASS']; print(w[0]['address'] if w else '')" 2>/dev/null || true)
    [ -n "$addr" ] && break
    sleep 0.05
done
[ -z "$addr" ] && exit 0

# Logical width of the focused monitor → anchor top-right.
mon_w=$(hyprctl monitors -j 2>/dev/null \
    | python3 -c "import sys,json; m=[x for x in json.load(sys.stdin) if x['focused']]; print(int(m[0]['width']/m[0]['scale']) if m else 1920)" 2>/dev/null || echo 1920)
x=$(( mon_w - WIN_W - MARGIN ))

hyprctl dispatch movewindowpixel "exact $x $TOP,address:$addr" >/dev/null 2>&1
