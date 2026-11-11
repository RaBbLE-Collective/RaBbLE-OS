#!/bin/bash
# kb-brightness.sh — set asus keyboard backlight and show SwayOSD with keyboard icon
# Usage: kb-brightness.sh up|down|toggle
DEVICE="asus::kbd_backlight"
MAX=$(brightnessctl --device="$DEVICE" max 2>/dev/null)
CURRENT=$(brightnessctl --device="$DEVICE" get 2>/dev/null)

case "${1:-up}" in
    up)
        brightnessctl --device="$DEVICE" set +1 >/dev/null 2>&1
        CURRENT=$(brightnessctl --device="$DEVICE" get 2>/dev/null)
        ;;
    down)
        brightnessctl --device="$DEVICE" set 1- >/dev/null 2>&1
        CURRENT=$(brightnessctl --device="$DEVICE" get 2>/dev/null)
        ;;
    toggle)
        # Cycle: off(0) → low(1) → mid(2) → high(3) → off(0) → ...
        NEXT=$(( (${CURRENT:-0} + 1) % (MAX + 1) ))
        brightnessctl --device="$DEVICE" set "$NEXT" >/dev/null 2>&1
        CURRENT=$NEXT
        ;;
esac

# Show OSD with keyboard icon and progress bar
if [ -n "$MAX" ] && [ "$MAX" -gt 0 ]; then
    PROGRESS=$(awk "BEGIN {printf \"%.4f\", ${CURRENT:-0} / $MAX}")
    swayosd-client \
        --custom-icon input-keyboard-symbolic \
        --custom-progress "$PROGRESS"
fi
