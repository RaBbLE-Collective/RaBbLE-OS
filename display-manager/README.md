# rdisplay: RaBbLE-OS display manager

Python, stdlib only. Design + status: Grimoire `log/plans/OS-Display-Manager-Plan.md`.

    export PYTHONPATH=~/RaBbLE-Collective/RaBbLE-OS/display-manager
    python3 -m rdisplay list
    python3 -m rdisplay mode HDMI-A-1 2560x1440@75
    python3 -m rdisplay scale HDMI-A-1 1.33333333
    python3 -m rdisplay place HDMI-A-1 above eDP-1
    python3 -m rdisplay save desk-2screen     # re-save after any layout change
    python3 -m rdisplay app                   # native GTK4 editor window (what the launcher entry runs)
    python3 -m rdisplay gui                   # older web editor, http://127.0.0.1:8765
    python3 -m rdisplay overlay               # GTK4 layer-shell switcher; XF86Display / Super+Shift+P toggles it
    python3 -m rdisplay daemon                # hotplug; autostarted by hypr conf_d/autostart.lua

Backends live in `rdisplay/backends/` (Hyprland only so far).
