#!/usr/bin/env bash
# =============================================================================
# boot-profile.sh — boot-time profiler & hiccup finder
#
# Surfaces where the last boot spent its time and what slowed it down, so the
# boot chain (firmware → GRUB → initramfs → Plymouth → SDDM → graphical.target)
# can be tuned. Read-only — it analyzes the journal of the *current* boot.
#
# What it reports:
#   1. Overall budget        — systemd-analyze time (firmware/loader/kernel/userspace)
#   2. Slowest units         — systemd-analyze blame (top N)
#   3. Critical path         — systemd-analyze critical-chain (what actually gated boot)
#   4. Boot-chain landmarks  — initrd, plymouth-quit-wait, sddm, graphical.target
#   5. Hiccups               — failed units, units over the --threshold, big journal gaps
#   6. Optional SVG timeline — systemd-analyze plot (--plot)
#
# Usage (from RaBbLE-OS/):
#   bash spells/boot-profile.sh [options]
#
# Options:
#   --top N           how many slow units to list (default: 15)
#   --threshold MS    flag units slower than MS milliseconds (default: 1000)
#   --plot            also write a timeline SVG to /tmp/rabble-boot-plot.svg
#   --last            compare against the previous boot too (-b -1)
#
# Tuning workflow (read after running):
#   - A slow unit on the critical-chain is the highest-value target — units NOT on
#     the chain ran in parallel and didn't gate boot, even if "blame" lists them.
#   - plymouth-quit-wait.service eating seconds = the splash is being held open
#     waiting for a service (often the display manager / network). That long hold is
#     usually the "black screen hiccup" — find what plymouth-quit-wait is After=.
#   - kernel time high → trim initramfs (drivers/modules); see the dracut conf in
#     roles/boot/plymouth/tasks/config.yml (we force amdgpu in, defer nvidia out).
#   - Then re-run after a reboot and watch the same landmarks move.
#
# cast ~ os/boot >> boot-time profiler & hiccup finder
# =============================================================================

set -euo pipefail

TOP=15
THRESHOLD_MS=1000
PLOT=0
COMPARE_LAST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --top)        TOP="$2"; shift 2 ;;
    --threshold)  THRESHOLD_MS="$2"; shift 2 ;;
    --plot)       PLOT=1; shift ;;
    --last)       COMPARE_LAST=1; shift ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if ! command -v systemd-analyze >/dev/null 2>&1; then
  echo "✗ systemd-analyze not found — is this a systemd system?" >&2
  exit 1
fi

rule() { printf '\n\033[35m── %s\033[0m\n' "$1"; }

# ── 1. Overall budget ─────────────────────────────────────────────────────────
rule "Overall boot budget (this boot)"
systemd-analyze time 2>/dev/null || echo "  (unavailable — running in a container?)"

if [[ $COMPARE_LAST -eq 1 ]]; then
  rule "Previous boot budget (-b -1)"
  systemd-analyze --boot-offset=-1 time 2>/dev/null \
    || journalctl -b -1 -o short-monotonic 2>/dev/null | tail -1 \
    || echo "  (no previous boot recorded)"
fi

# ── 2. Slowest units ────────────────────────────────────────────────────────
rule "Slowest units (top ${TOP} — note: parallel units may not gate boot)"
systemd-analyze blame 2>/dev/null | head -n "$TOP" || echo "  (unavailable)"

# ── 3. Critical chain — what actually gated the boot ──────────────────────────
rule "Critical chain (the path that gated graphical.target)"
systemd-analyze critical-chain 2>/dev/null || echo "  (unavailable)"

# ── 4. Boot-chain landmarks ───────────────────────────────────────────────────
rule "Boot-chain landmarks"
for unit in \
  initrd.target initrd-switch-root.service \
  systemd-vconsole-setup.service \
  plymouth-start.service plymouth-quit-wait.service plymouth-quit.service \
  nvidia-load.service \
  sddm.service display-manager.service \
  graphical.target; do
  if systemctl show "$unit" >/dev/null 2>&1; then
    act=$(systemctl show -p ActiveEnterTimestampMonotonic --value "$unit" 2>/dev/null || echo "")
    state=$(systemctl is-active "$unit" 2>/dev/null || true)
    printf '  %-34s %-10s' "$unit" "${state:-?}"
    if [[ -n "$act" && "$act" != "0" ]]; then
      printf '  @%ss' "$(awk "BEGIN{printf \"%.2f\", $act/1000000}")"
    fi
    printf '\n'
  fi
done
echo "  (plymouth-quit-wait holding for seconds == splash held open waiting on a"
echo "   downstream service — the usual cause of a lingering black/splash screen.)"

# ── 5. Hiccups ────────────────────────────────────────────────────────────────
rule "Failed units this boot"
if systemctl --failed --no-legend 2>/dev/null | grep -q .; then
  systemctl --failed --no-legend
else
  echo "  ✓ none"
fi

rule "Units slower than ${THRESHOLD_MS}ms"
systemd-analyze blame 2>/dev/null | awk -v t="$THRESHOLD_MS" '
  {
    v=$1; ms=0
    if (v ~ /min/)      { split(v,a,"min"); ms += a[1]*60000; v=a[2] }
    if (v ~ /[0-9.]+s/) { sub(/s.*/,"",v); ms += v*1000 }
    else if (v ~ /ms/)  { sub(/ms.*/,"",v); ms += v }
    if (ms >= t) print "  " $0
  }' || true

rule "Largest gaps in the boot journal (>1s of silence)"
journalctl -b -o short-monotonic --no-pager 2>/dev/null | awk '
  {
    ts=$1; gsub(/[\[\]]/,"",ts)
    if (prev != "" && (ts-prev) > 1.0)
      printf "  +%5.1fs gap before: %s\n", ts-prev, substr($0, index($0,$3))
    prev=ts; line=$0
  }' | head -n 12 || echo "  (journal unavailable — try with sudo)"

# ── 6. Optional timeline ──────────────────────────────────────────────────────
if [[ $PLOT -eq 1 ]]; then
  rule "Timeline SVG"
  OUT=/tmp/rabble-boot-plot.svg
  if systemd-analyze plot > "$OUT" 2>/dev/null; then
    echo "  ✓ wrote $OUT  (open with: xdg-open $OUT)"
  else
    echo "  ✗ systemd-analyze plot failed"
  fi
fi

rule "Next steps"
cat <<'EOF'
  • Target units on the CRITICAL CHAIN first — blame lists parallel units that
    ran concurrently and did not actually delay boot.
  • plymouth-quit-wait eating time → find what holds the splash:
      systemctl show plymouth-quit-wait.service -p After
  • Trim kernel/initramfs time via the dracut conf:
      roles/boot/plymouth/tasks/config.yml   (amdgpu forced in, nvidia deferred out)
  • Re-run after a reboot to confirm the landmarks moved:  bash spells/boot-profile.sh
  • Full boot-chain verification recipe:
      ../RaBbLE-Grimoire/RaBbLE-OS/fix/RaBbLE-OS-Fix-BootChain.md
EOF
