#!/usr/bin/env bash
# network-menu.sh — fuzzel wifi overlay for waybar network module

DEVICE=$(nmcli -t -f TYPE,DEVICE device | grep "^wifi:" | cut -d: -f2 | head -1)
CURRENT=$(nmcli -t -f ACTIVE,SSID device wifi 2>/dev/null | grep "^yes:" | cut -d: -f2)
WIFI_STATE=$(nmcli radio wifi)

# ── Build menu ──────────────────────────────────────────────────────────────

ITEMS=""

if [[ "$WIFI_STATE" == "enabled" ]]; then
    nmcli device wifi rescan dev "$DEVICE" 2>/dev/null

    if [[ -n "$CURRENT" ]]; then
        ITEMS+="  Disconnect from $CURRENT\n"
    fi
    ITEMS+="  Disable WiFi\n"
    ITEMS+="─────────────────────\n"

    # List networks: active first, then sorted by signal strength
    while IFS=: read -r active signal ssid; do
        [[ -z "$ssid" ]] && continue
        [[ "$ssid" == "--" ]] && continue
        marker="  "
        [[ "$active" == "yes" ]] && marker=" "
        ITEMS+="$(printf '%s [%3d%%]  %s' "$marker" "$signal" "$ssid")\n"
    done < <(nmcli -t -f ACTIVE,SIGNAL,SSID device wifi list 2>/dev/null \
             | sort -t: -k1 -r | sort -t: -k2 -rn)
else
    ITEMS+="  Enable WiFi\n"
fi

# ── Show overlay ─────────────────────────────────────────────────────────────

CHOICE=$(printf "%b" "$ITEMS" | grep -v "^─" | fuzzel --dmenu --prompt "  Network  ")
[[ -z "$CHOICE" ]] && exit 0

# ── Handle selection ─────────────────────────────────────────────────────────

if [[ "$CHOICE" == *"Disable WiFi"* ]]; then
    nmcli radio wifi off

elif [[ "$CHOICE" == *"Enable WiFi"* ]]; then
    nmcli radio wifi on

elif [[ "$CHOICE" == *"Disconnect from"* ]]; then
    nmcli device disconnect "$DEVICE"

else
    # Extract SSID from the end of the line (after the signal indicator)
    SSID=$(echo "$CHOICE" | sed 's/.*[0-9]\+%\]  //')

    if nmcli connection show "$SSID" &>/dev/null; then
        # Known network — connect directly
        nmcli connection up "$SSID" 2>/dev/null \
            || nmcli device wifi connect "$SSID" dev "$DEVICE"
    else
        # Unknown network — prompt for password
        PASS=$(fuzzel --dmenu --password --prompt "  $SSID  " <<< "")
        [[ -z "$PASS" ]] && exit 0
        nmcli device wifi connect "$SSID" password "$PASS" dev "$DEVICE"
    fi
fi
