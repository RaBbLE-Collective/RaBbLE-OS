#!/usr/bin/env bash
# =============================================================================
# boot-debug-toggle.sh — flip Plymouth real-boot debug logging on/off
#
# Adds/removes the `plymouth:debug` token in the ProArt P16 kernel cmdline
# (group_vars), then re-applies the boot layer so the change lands in GRUB.
# With it on, plymouthd writes /var/log/plymouth-debug.log during the REAL
# boot — the only way to see why the splash is black without watching pixels.
#
# This is a TEMPORARY diagnostic switch. Turn it OFF once the splash is verified
# so the debug flag doesn't become permanent drift.
#
# Note: this manages ONLY `plymouth:debug`. It does not touch `rhgb`/`quiet`
# (those live in the shared grub2 template, not this host var) — the boot
# journal (journalctl -b) already captures the kernel/systemd log retroactively,
# so plymouth:debug + boot-diagnose.sh is sufficient evidence.
#
# Usage (from RaBbLE-OS/):
#   sudo bash spells/boot-debug-toggle.sh --on        # enable + apply boot layer
#   sudo bash spells/boot-debug-toggle.sh --off       # disable + apply boot layer
#        bash spells/boot-debug-toggle.sh --status    # report state (no root needed)
#
# Options:
#   --on | --off | --status
#   --no-apply    edit group_vars only; skip 'layerctl apply boot'
#
# cast ~ os/boot >> plymouth debug cmdline toggle
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GROUP_VARS="${REPO_ROOT}/ansible/inventory/group_vars/asus_proart_p16.yml"
LAYERCTL="${REPO_ROOT}/RaBbLE-OS-layerctl.sh"

KEY_LINE='rabble_grub_extra_cmdline: >-'
TOKEN_RE='^[[:space:]]*plymouth:debug[[:space:]]*$'
TOKEN_INSERT='  plymouth:debug'

ACTION=""
APPLY=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --on)       ACTION="on"; shift ;;
    --off)      ACTION="off"; shift ;;
    --status)   ACTION="status"; shift ;;
    --no-apply) APPLY=0; shift ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$ACTION" ]] && { echo "specify --on, --off, or --status" >&2; exit 1; }
[[ -f "$GROUP_VARS" ]] || { echo "group_vars not found: $GROUP_VARS" >&2; exit 1; }
grep -qF "$KEY_LINE" "$GROUP_VARS" || { echo "cmdline key not found in $GROUP_VARS" >&2; exit 1; }

is_on() { grep -qE "$TOKEN_RE" "$GROUP_VARS"; }

if [[ "$ACTION" == "status" ]]; then
  if is_on; then echo "plymouth:debug = ON  (in $GROUP_VARS)"
  else echo "plymouth:debug = OFF"; fi
  echo "live cmdline currently has it: $(grep -qw 'plymouth:debug' /proc/cmdline && echo yes || echo no)"
  exit 0
fi

apply_boot() {
  if [[ $APPLY -eq 0 ]]; then
    echo "── --no-apply: group_vars edited; run 'sudo layerctl apply boot' yourself to land it"
    return 0
  fi
  if [[ $EUID -ne 0 ]]; then
    echo "── not root: skipping apply. Run 'sudo ${LAYERCTL} apply boot' to land the change." >&2
    return 0
  fi
  echo "── applying boot layer (GRUB + dracut)…"
  "$LAYERCTL" apply boot
}

case "$ACTION" in
  on)
    if is_on; then
      echo "── plymouth:debug already present in group_vars — no edit needed"
    else
      # Insert the token line immediately after the cmdline key line.
      # NB: folded-scalar lines must NOT carry inline '#' comments (YAML treats
      # them as literal text inside '>-'), so the token is added bare.
      awk -v key="$KEY_LINE" -v tok="$TOKEN_INSERT" '
        {print}
        $0==key {print tok}
      ' "$GROUP_VARS" > "${GROUP_VARS}.tmp" && mv "${GROUP_VARS}.tmp" "$GROUP_VARS"
      echo "── added 'plymouth:debug' to ${GROUP_VARS##*/}"
    fi
    apply_boot
    echo
    echo "✓ debug ON. Next: sudo reboot  → watch the splash → after login:"
    echo "    sudo bash spells/boot-diagnose.sh"
    ;;
  off)
    if ! is_on; then
      echo "── plymouth:debug not present — nothing to remove"
    else
      grep -vE "$TOKEN_RE" "$GROUP_VARS" > "${GROUP_VARS}.tmp" && mv "${GROUP_VARS}.tmp" "$GROUP_VARS"
      echo "── removed 'plymouth:debug' from ${GROUP_VARS##*/}"
    fi
    apply_boot
    echo
    echo "✓ debug OFF. Reboot when convenient to drop the flag from the live cmdline."
    ;;
esac
