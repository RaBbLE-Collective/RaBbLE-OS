#!/bin/bash
# screenshot.sh — RaBbLE-OS screenshot capture
# Captures straight into swappy for annotate/save/discard (Ctrl+S save,
# Ctrl+C copy, Escape discard — see config/swappy/config for save_dir).
#
# Usage: screenshot.sh [screen|full|region|window]

MODE="${1:-region}"

case "$MODE" in
    screen|full)
        grim - | swappy -f -
        ;;
    region)
        GEOM="$(slurp)" || exit 0
        grim -g "$GEOM" - | swappy -f -
        ;;
    window)
        if command -v hyprctl &>/dev/null; then
            GEOM=$(hyprctl activewindow -j | jq -r '"\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"')
        else
            GEOM="$(slurp)" || exit 0
        fi
        grim -g "$GEOM" - | swappy -f -
        ;;
    *)
        echo "Usage: screenshot.sh [screen|full|region|window]" >&2
        exit 1
        ;;
esac
