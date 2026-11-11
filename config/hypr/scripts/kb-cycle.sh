#!/bin/bash
# Find your device with: brightnessctl --list
DEVICE="asus::kbd_backlight"

# Get current brightness as a percentage (removes the '%' sign)
CURRENT=$(brightnessctl -d "$DEVICE" info | grep -oP '\(\K[^%]+')

# Logic for 4 modes (0, 1, 2, 3)

if [ "$CURRENT" -le 10 ]; then
    VAL=33
elif [ "$CURRENT" -le 40 ]; then
    VAL=66
elif [ "$CURRENT" -le 70 ]; then
    VAL=100
else
    VAL=0
fi

# 2. Set the actual brightness
#brightnessctl -d "$DEVICE" set "${VAL}%"
swayosd-client --device "$DEVICE" --brightness="${VAL}" --custom-icon="keyboard-brightness-symbolic"
