#!/usr/bin/env bash
# config/hypr/scripts/help.sh
# Quick keybind reference — displayed in a floating kitty terminal

kitty --title "RaBbLE Keybinds" \
     --override window-size-pixels=900x640 \
     bash -c '
cat << "EOF"
  RaBbLE — Hyprland Keybind Reference
  ─────────────────────────────────────────────────────────
  SUPER + Return     Open terminal (kitty)
  SUPER + Space      App launcher (fuzzel)
  SUPER + B          Browser
  SUPER + E          File manager
  SUPER + L          Lock screen
  SUPER + F          Toggle fullscreen
  SUPER + SHIFT + F  Toggle maximize (keeps bar)
  SUPER + U          Raise window to top
  SUPER + SHIFT + U  Pin window (floating: on top, all workspaces)
  SUPER + V          Toggle floating
  SUPER + G          Toggle window group
  SUPER + Q  (SHIFT) Kill active window / Exit Hyprland
  ─────────────────────────────────────────────────────────
  SUPER + H/J/K/L    Focus direction (Vim-style)
  SUPER + SHIFT+HJKL Move window
  SUPER + R → HJKL   Resize mode (Esc to exit)
  SUPER + 1–0        Switch workspace
  SUPER + SHIFT+1–0  Move window to workspace
  SUPER + Tab        Previous workspace
  SUPER + [ / ]      Cycle workspaces
  SUPER + `          Scratchpad toggle
  ─────────────────────────────────────────────────────────
  SUPER + S          Screenshot (region)
  SUPER + SHIFT+S    Screenshot → clipboard
  SUPER + SHIFT+C    Clipboard history (fuzzel)
  ─────────────────────────────────────────────────────────
  Volume:  XF86AudioRaiseVolume / LowerVolume / Mute
  Bright:  XF86MonBrightnessUp / Down
  Media:   XF86AudioPlay / Next / Prev
  ─────────────────────────────────────────────────────────
  Press q or Ctrl+C to close
EOF
read -rsn1'
