#!/usr/bin/env bash
# Hyprland HDMI hotplug handler.
# Listens on the Hyprland IPC event socket via socat and moves workspace 11
# to the HDMI output when it is connected. Disconnect is handled natively —
# Hyprland migrates workspace 11 windows back to the active monitor.

SOCKET="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
HDMI_WS=11

socat - "UNIX-CONNECT:$SOCKET" | while IFS= read -r event; do
    case "$event" in
        monitoradded\>*)
            monitor="${event#monitoradded>}"
            if [[ "$monitor" != eDP-* ]]; then
                notify-send -u normal "Monitor connected" "Detected $monitor — moving workspace $HDMI_WS"
                sleep 0.5
                hyprctl dispatch moveworkspacetomonitor "$HDMI_WS $monitor"
                notify-send -u normal "Monitor ready" "Workspace $HDMI_WS is live on $monitor"
            fi
            ;;
        monitorremoved\>*)
            monitor="${event#monitorremoved>}"
            if [[ "$monitor" != eDP-* ]]; then
                notify-send -u normal "Monitor disconnected" "$monitor removed — workspace $HDMI_WS migrated back"
            fi
            ;;
    esac
done
