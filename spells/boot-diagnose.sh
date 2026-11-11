#!/usr/bin/env bash
# =============================================================================
# boot-diagnose.sh — RaBbLE-OS boot-chain evidence capture
#
# The boot splash (Plymouth) only proves out on a real reboot, and an agent
# shell cannot see the screen. This spell captures, in one shot, everything
# needed to reason about a black / broken splash WITHOUT guessing:
#   • what is actually inside the current initramfs (theme frames, plugins, GPU)
#   • the real-boot Plymouth debug log (needs plymouth:debug on the cmdline —
#     enable with: spells/boot-debug-toggle.sh --on)
#   • the boot journal for Plymouth units + DRM/amdgpu/simpledrm/modeset
#   • current default theme + live kernel cmdline + GPU/DRM card wiring
# then prints a heuristic PASS/FAIL verdict.
#
# Run it TWICE around a verify reboot:
#   (1) before reboot — captures current initramfs + prior boot
#   (2) after  reboot — captures the boot that just showed (or failed to show)
#                       the splash; that is the CURRENT boot (-b 0, the default)
#
# Usage (from RaBbLE-OS/):
#   sudo bash spells/boot-diagnose.sh [--boot N] [--save PATH]
#
# Options:
#   --boot N    journal boot to inspect (default: 0 = current boot).
#               Use -1 for the previous boot. After a single verify reboot the
#               splash boot is the CURRENT boot, so the default is correct.
#   --save P    also write the full capture to P (default: /tmp/rabble-boot-diagnose-<ts>.log)
#
# cast ~ os/boot >> boot evidence capture
# =============================================================================

set -uo pipefail

BOOT="0"
TS="$(date +%Y%m%d-%H%M%S)"
SAVE="/tmp/rabble-boot-diagnose-${TS}.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --boot) BOOT="$2"; shift 2 ;;
    --save) SAVE="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "run as root: sudo bash spells/boot-diagnose.sh" >&2
  exit 1
fi

THEME="rabble-aether"
KVER="$(uname -r)"
INITRAMFS="/boot/initramfs-${KVER}.img"
PLY_LOG="/var/log/plymouth-debug.log"

# Heuristic flags (set during the run, summarized at the end).
F_THEME_IN_INITRAMFS="unknown"
F_SCRIPT_PLUGIN="unknown"
F_AMDGPU_IN_INITRAMFS="unknown"
F_PLY_DEBUG_FRESH="unknown"
F_PLY_SCRIPT_ERROR="unknown"

# Tee everything to the save file too.
exec > >(tee "$SAVE") 2>&1

hr()  { printf '\n── %s %s\n' "$1" "$(printf '─%.0s' $(seq 1 $((60 - ${#1}))))"; }
note(){ printf '   %s\n' "$1"; }

echo "═══ RaBbLE-OS boot-diagnose · ${TS} · kernel ${KVER} ═══"

# ── 1. Context ───────────────────────────────────────────────────────────────
hr "context"
note "default theme : $(plymouth-set-default-theme 2>/dev/null || echo '??')"
note "live cmdline  : $(tr '\0' ' ' < /proc/cmdline 2>/dev/null || cat /proc/cmdline)"
echo "   GPU / DRM cards:"
lspci 2>/dev/null | grep -iE 'vga|3d|display' | sed 's/^/     /'
for c in /sys/class/drm/card[0-9]; do
  [[ -e "$c" ]] || continue
  drv="$(basename "$(readlink -f "$c/device/driver" 2>/dev/null)" 2>/dev/null || echo '?')"
  printf '     %s → driver=%s\n' "$(basename "$c")" "$drv"
done

# ── 2. initramfs content check ───────────────────────────────────────────────
hr "initramfs ${INITRAMFS}"
if [[ ! -r "$INITRAMFS" ]]; then
  note "✗ cannot read initramfs (not root?)"
else
  LS="$(lsinitrd "$INITRAMFS" 2>/dev/null)"
  theme_files="$(printf '%s\n' "$LS" | grep -c "themes/${THEME}/" || true)"
  script_so="$(printf '%s\n' "$LS" | grep -E 'plymouth/.*script\.so' | head -1 || true)"
  label_so="$(printf '%s\n' "$LS"  | grep -E 'plymouth/.*label\.so'  | head -1 || true)"
  amdgpu="$(printf '%s\n' "$LS"    | grep -E 'amdgpu\.ko' | head -1 || true)"

  note "theme files in initramfs : ${theme_files}"
  [[ "${theme_files:-0}" -gt 5 ]] && F_THEME_IN_INITRAMFS="yes" || F_THEME_IN_INITRAMFS="NO"
  printf '%s\n' "$LS" | grep -E "themes/${THEME}/.*(\.script|wm-step|entity|bg-liminal)" | head -6 | sed 's/^/     /'

  if [[ -n "$script_so" ]]; then note "✓ script plugin : $script_so"; F_SCRIPT_PLUGIN="yes"
  else note "✗ script plugin : MISSING (a ModuleName=script theme cannot render → black)"; F_SCRIPT_PLUGIN="NO"; fi
  [[ -n "$label_so" ]]  && note "✓ label plugin  : $label_so" || note "· label plugin  : absent (ok unless theme uses labels)"
  if [[ -n "$amdgpu" ]]; then note "✓ amdgpu driver : $amdgpu"; F_AMDGPU_IN_INITRAMFS="yes"
  else note "✗ amdgpu driver : MISSING (no native KMS in initramfs → splash depends on simpledrm)"; F_AMDGPU_IN_INITRAMFS="NO"; fi
fi

# ── 3. Plymouth real-boot debug log ──────────────────────────────────────────
hr "plymouth debug log ${PLY_LOG}"
if [[ ! -e "$PLY_LOG" ]]; then
  note "· no ${PLY_LOG} — plymouth:debug not on cmdline. Enable: spells/boot-debug-toggle.sh --on"
  F_PLY_DEBUG_FRESH="absent"
else
  age_s=$(( $(date +%s) - $(stat -c %Y "$PLY_LOG") ))
  boot_s=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 999999)
  note "log mtime age : ${age_s}s ago   (this boot started ${boot_s}s ago)"
  if [[ "$BOOT" == "0" && "$age_s" -le "$boot_s" ]]; then
    note "✓ log is from the CURRENT boot"; F_PLY_DEBUG_FRESH="yes"
  elif [[ "$BOOT" == "0" ]]; then
    note "⚠ log predates this boot — plymouth:debug may not have been set on the last boot"; F_PLY_DEBUG_FRESH="stale"
  else
    F_PLY_DEBUG_FRESH="n/a (--boot $BOOT)"
  fi
  errs="$(grep -iE 'error|failed|could not|cannot|no such|unable' "$PLY_LOG" 2>/dev/null | head -15 || true)"
  if [[ -n "$errs" ]]; then
    note "✗ errors/warnings in plymouth log:"; printf '%s\n' "$errs" | sed 's/^/     /'; F_PLY_SCRIPT_ERROR="yes"
  else
    note "· no obvious error lines in plymouth log"; F_PLY_SCRIPT_ERROR="no"
  fi
  echo "   ── last 25 lines ──"
  tail -25 "$PLY_LOG" | sed 's/^/     /'
fi

# ── 4. Boot journal (-b ${BOOT}) ─────────────────────────────────────────────
hr "journal (-b ${BOOT}) plymouth units"
journalctl -b "$BOOT" --no-pager \
  -u plymouth-start.service -u plymouth-quit.service \
  -u plymouth-quit-wait.service -u plymouth-read-write.service 2>/dev/null \
  | sed 's/^/   /' || note "· journal unavailable for boot ${BOOT}"

hr "journal (-b ${BOOT}) DRM / amdgpu / simpledrm / modeset"
journalctl -b "$BOOT" -k --no-pager 2>/dev/null \
  | grep -iE 'amdgpu|simpledrm|\bdrm\b|fb0|modeset|nvidia' | head -40 | sed 's/^/   /' \
  || note "· no DRM-related kernel lines for boot ${BOOT}"

# ── 5. Verdict ───────────────────────────────────────────────────────────────
hr "verdict"
printf '   %-26s %s\n' "theme in initramfs:"  "$F_THEME_IN_INITRAMFS"
printf '   %-26s %s\n' "script plugin:"        "$F_SCRIPT_PLUGIN"
printf '   %-26s %s\n' "amdgpu in initramfs:"  "$F_AMDGPU_IN_INITRAMFS"
printf '   %-26s %s\n' "plymouth debug fresh:"  "$F_PLY_DEBUG_FRESH"
printf '   %-26s %s\n' "plymouth log errors:"   "$F_PLY_SCRIPT_ERROR"
echo
if [[ "$F_SCRIPT_PLUGIN" == "NO" || "$F_THEME_IN_INITRAMFS" == "NO" ]]; then
  note "→ ROOT CAUSE LIKELY in initramfs: theme/plugin missing. Re-check dracut install_items"
  note "  + run 'layerctl apply boot' to force a rebuild, then re-run this spell."
elif [[ "$F_PLY_SCRIPT_ERROR" == "yes" ]]; then
  note "→ ROOT CAUSE LIKELY in the theme script: fix the error above in rabble-aether.script."
elif [[ "$F_PLY_DEBUG_FRESH" == "absent" || "$F_PLY_DEBUG_FRESH" == "stale" ]]; then
  note "→ NO fresh Plymouth debug log. Enable instrumentation and reboot:"
  note "  spells/boot-debug-toggle.sh --on && reboot, then re-run this spell."
else
  note "→ initramfs + theme look healthy and Plymouth logged this boot. If the screen was"
  note "  still black, suspect the DRM/display path (review the DRM journal above):"
  note "  amdgpu modeset timing, or framebuffer/mode. Next probe: set a stock theme"
  note "  (plymouth-set-default-theme spinner; dracut -f; reboot) to split theme-vs-DRM."
fi
echo
note "full capture saved → ${SAVE}"
note "share that file (or this output) to continue the diagnosis."
