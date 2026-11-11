#!/usr/bin/env bash
# gpu-usage.sh — AMD GPU busy percentage for Waybar (JSON output)
# FIX: outputs JSON so Waybar can display tooltip via return-type: json
# Reads from sysfs; falls back to radeontop if the node is absent.

GPU_NODE=$(find /sys/class/drm/card*/device -name "gpu_busy_percent" 2>/dev/null | head -1)

if [[ -n "$GPU_NODE" ]]; then
    USAGE=$(cat "$GPU_NODE")
elif command -v radeontop &>/dev/null; then
    USAGE=$(radeontop -d - -l 1 2>/dev/null \
      | grep -oP 'gpu \K[0-9]+(?=\.)' \
      | head -1)
else
    USAGE="N/A"
fi

# Output Waybar JSON: text shown in bar, tooltip on hover
printf '{"text":"󰾲  %s%%","tooltip":"GPU Usage: %s%%"}\n' "$USAGE" "$USAGE"
