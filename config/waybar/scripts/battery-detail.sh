#!/usr/bin/env bash
# battery-detail.sh — sends a desktop notification with detailed battery info.
# Triggered by clicking the battery module in Waybar.
# FIX: removed unfilled %POWER_DETAIL% placeholder from notify-send title.

BAT=$(upower -i "$(upower -e | grep BAT | head -1)")
CAP=$(echo "$BAT"    | grep -oP 'percentage:\s+\K[0-9.]+')
STATE=$(echo "$BAT"  | grep -oP 'state:\s+\K\S+')
TIME=$(echo "$BAT"   | grep -oP 'time to (full|empty):\s+\K.+')
POWER=$(echo "$BAT"  | grep -oP 'energy-rate:\s+\K[0-9.]+')
HEALTH=$(echo "$BAT" | grep -oP 'capacity:\s+\K[0-9.]+')

notify-send "Battery Details" \
    "Charge: ${CAP}%\nState: ${STATE}\nTime: ${TIME:-N/A}\nDraw: ${POWER}W\nHealth: ${HEALTH}%" \
    --icon=battery-symbolic \
    -t 5000
