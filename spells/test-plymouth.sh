#!/usr/bin/env bash
# =============================================================================
# test-plymouth.sh — Plymouth boot-splash QA
#
# Syncs the rabble-aether theme from the Ansible source to the deployed
# /usr/share/plymouth/themes/ directory, then launches plymouthd.
#
# MUST be run from a bare VT (/dev/tty3, etc.), NOT from inside Hyprland.
# Plymouth needs DRM master; Hyprland releases it when you switch away via VT.
#
# How to get there from Hyprland:
#   Ctrl+Alt+F3  (or your VT-switch binding) → log in → run this spell
#   After the test, Ctrl+Alt+F2 to return to Hyprland.
#
# Usage (from RaBbLE-OS/):
#   sudo bash spells/test-plymouth.sh [options]
#
# Options:
#   --duration N    seconds to hold the splash (default: 20)
#   --no-sync       skip syncing from Ansible source
#   --sync-only     sync files then exit
#
# cast ~ os/boot >> Plymouth QA spell
# =============================================================================

set -euo pipefail

THEME="rabble-aether"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_SRC="${SCRIPT_DIR}/../ansible/roles/boot/plymouth/files/${THEME}"
DEPLOY_DIR="/usr/share/plymouth/themes/${THEME}"
DURATION=20
SYNC=1

# ── args ─────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration)  DURATION="$2"; shift 2 ;;
    --no-sync)   SYNC=0; shift ;;
    --sync-only) SYNC=1; MODE="sync-only"; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
MODE="${MODE:-run}"

if [[ $EUID -ne 0 ]]; then
  echo "run as root: sudo bash spells/test-plymouth.sh" >&2
  exit 1
fi

# ── sync theme from Ansible source ───────────────────────────────────────────
if [[ $SYNC -eq 1 ]]; then
  echo "── syncing ${THEME} → ${DEPLOY_DIR}"
  cp "${ANSIBLE_SRC}/rabble-aether.script"   "${DEPLOY_DIR}/rabble-aether.script"
  cp "${ANSIBLE_SRC}/rabble-aether.plymouth" "${DEPLOY_DIR}/rabble-aether.plymouth"
  echo "   synced"
fi

[[ $MODE == "sync-only" ]] && { echo "── sync complete"; exit 0; }

# ── TTY check — must be on a real VT, not inside a graphical session ──────────
CURRENT_TTY=$(tty 2>/dev/null || echo "unknown")

if [[ ! "$CURRENT_TTY" =~ ^/dev/tty[0-9]+$ ]]; then
  echo ""
  echo "  ✗ Running inside a graphical session (tty: ${CURRENT_TTY})"
  echo "    Plymouth needs DRM master, which Hyprland holds while active."
  echo ""
  echo "  To test:"
  echo "    1. Press Ctrl+Alt+F3 from Hyprland to switch to VT3"
  echo "    2. Log in on VT3"
  echo "    3. Run:  sudo bash spells/test-plymouth.sh"
  echo "    4. Press Ctrl+Alt+F2 afterward to return to Hyprland"
  echo ""
  echo "  Or skip testing and bake directly into initrd:"
  echo "    sudo dracut -f && sudo reboot"
  echo ""
  echo "  Theme files are synced — ready when you are."
  exit 1
fi

# ── kill any stale plymouthd ──────────────────────────────────────────────────
if pgrep -x plymouthd &>/dev/null; then
  echo "── stopping stale plymouthd"
  plymouth quit 2>/dev/null || true
  sleep 0.5
fi

# ── launch Plymouth on the current VT ────────────────────────────────────────
VT_NUM="${CURRENT_TTY##*/dev/tty}"
echo "── launching Plymouth on ${CURRENT_TTY} for ${DURATION}s"
echo "   debug log: /tmp/plymouthd-test.log"
echo ""

plymouthd --no-daemon --debug --tty="${CURRENT_TTY}" --graphical-boot \
  > /tmp/plymouthd-test.log 2>&1 &
PLY_PID=$!
sleep 1

# check plymouthd survived startup
if ! kill -0 $PLY_PID 2>/dev/null; then
  echo "  ✗ plymouthd exited immediately — DRM still unavailable?"
  echo "  last log lines:"
  tail -15 /tmp/plymouthd-test.log 2>/dev/null | sed 's/^/    /'
  exit 1
fi

plymouth --show-splash 2>/dev/null || true

# ── simulate boot progress ────────────────────────────────────────────────────
PCTS=(4 8 15 24 35 48 62 75 84 92 97 100)
DELAY=$(echo "scale=2; ${DURATION} / ${#PCTS[@]}" | bc)
for P in "${PCTS[@]}"; do
  sleep "$DELAY"
  plymouth --update "step-${P}" 2>/dev/null || true
done

sleep 1
plymouth quit 2>/dev/null || true

# ── report ────────────────────────────────────────────────────────────────────
echo ""
echo "── Plymouth test complete"
LOG_LINES=$(wc -l < /tmp/plymouthd-test.log 2>/dev/null || echo 0)
if [[ $LOG_LINES -lt 20 ]]; then
  echo "   ✗ log is short (${LOG_LINES} lines) — likely crashed; see /tmp/plymouthd-test.log"
  tail -10 /tmp/plymouthd-test.log 2>/dev/null | sed 's/^/     /'
else
  echo "   ✓ ran successfully (${LOG_LINES} log lines)"
  echo "   to bake into initrd:  sudo dracut -f"
fi
