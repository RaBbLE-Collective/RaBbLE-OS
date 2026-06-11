#!/bin/bash
# screenshot.sh — RaBbLE-OS screenshot utility
# Saves to RaBbLE-Captures so all desktop captures land in the project tree.
# Subdirectory:
#   region → Design-Iterations/by-date/  (targeted, needs manual classification)
#   screen → Collective-Atmosphere/      (full desktop state captures)

CAPTURES="$HOME/RaBbLE-Collective/RaBbLE-Captures"
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"

case "$1" in
    region)
        DIR="$CAPTURES/Design-Iterations/by-date"
        mkdir -p "$DIR"
        FILE="$DIR/capture-region_$TIMESTAMP.png"
        grim -g "$(slurp)" "$FILE" && notify-send "Screenshot" "Saved: $FILE"
        ;;
    screen)
        DIR="$CAPTURES/Collective-Atmosphere"
        mkdir -p "$DIR"
        FILE="$DIR/capture-screen_$TIMESTAMP.png"
        grim "$FILE" && notify-send "Screenshot" "Saved: $FILE"
        ;;
    *)
        DIR="$CAPTURES/Design-Iterations/by-date"
        mkdir -p "$DIR"
        FILE="$DIR/capture-region_$TIMESTAMP.png"
        grim -g "$(slurp)" "$FILE" && notify-send "Screenshot" "Saved: $FILE"
        ;;
esac
