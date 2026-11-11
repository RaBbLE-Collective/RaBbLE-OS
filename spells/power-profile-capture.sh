#!/usr/bin/env bash
# =============================================================================
# power-profile-capture.sh — repeatable power/GPU profiling snapshot
#
# Wraps the manual protocol in
# ../RaBbLE-Grimoire/RaBbLE-OS/verify/RaBbLE-OS-Verify-PowerTesting.md into one
# read-only capture, so before/after numbers (Hyprland blur cuts, NVIDIA
# D3cold fix, tuned/asusd power-stack changes) are comparable instead of
# guessed. Every probe degrades gracefully — a missing tool or missing
# permission prints "(unavailable)" rather than failing the whole capture.
#
# What it reports:
#   1. Battery        — upower -i on the battery/line-power devices,
#                        /sys/class/power_supply/BAT0/power_now (uW)
#   2. NVIDIA dGPU    — nvidia-smi power.draw/pstate/temp/util,
#                        PCI power_state (D0/D3cold) at a DYNAMICALLY
#                        derived PCI address (never hardcoded — PCI
#                        addresses renumber across kernel/BIOS changes)
#   3. CPU package    — turbostat single-shot PkgWatt/CorWatt/RAMWatt
#                        (needs root/MSR access — guarded)
#   4. Thermals       — sensors
#   5. Power profile  — tuned-adm active profile, asusctl platform-profile
#
# Output (BOTH, always):
#   1. Timestamped human-readable text report
#   2. Machine-readable JSON snapshot (stable schema — Phase 5's settings-app
#      diagnostics tab consumes this directly; built with printf, no jq
#      dependency)
#
# Usage (from RaBbLE-OS/):
#   bash spells/power-profile-capture.sh [options]
#
# Options:
#   --out DIR         directory to write the report + JSON
#                      (default: ../RaBbLE-BaBbLE/tmp/ if that sibling repo is
#                      present — survives reboots, per RaBbLE-Agent-Protocols.md
#                      "never use /tmp for RaBbLE work"; falls back to /tmp only
#                      if BaBbLE isn't checked out alongside this repo)
#   -h, --help        this help
#
# Read after running:
#   - Compare power_now_uw / power_draw_w / power_state before and after a
#     change (Hyprland blur cut, NVIDIA D3cold fix, power-profile switch).
#   - nvidia.power_state should read "D3cold" at idle once the D3cold fix
#     (fix/RaBbLE-OS-Fix-Nvidia.md) is live and the machine has rebooted.
#   - turbostat needing root is expected on most desktop sessions — re-run
#     with sudo for CPU package power, or ignore if only GPU numbers matter.
#   - Full manual protocol this wraps:
#       ../RaBbLE-Grimoire/RaBbLE-OS/verify/RaBbLE-OS-Verify-PowerTesting.md
#
# cast ~ os/power >> power-profile capture spell
# =============================================================================

set -euo pipefail

# Default output dir: RaBbLE-BaBbLE/tmp/ (gitignored, nuke-safe, survives reboots)
# if the Collective workspace is checked out alongside this repo — this spell's
# whole job is comparing before/after numbers across the reboots Phase 3 power
# testing requires, so /tmp (cleared on reboot) is the wrong default. Falls
# back to /tmp only when BaBbLE isn't present (e.g. a bare RaBbLE-OS clone).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLECTIVE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd 2>/dev/null || true)"
BABBLE_TMP="$COLLECTIVE_ROOT/RaBbLE-BaBbLE/tmp"

if [[ -n "$COLLECTIVE_ROOT" && -d "$BABBLE_TMP" ]]; then
  OUTDIR="$BABBLE_TMP"
else
  OUTDIR="/tmp"
fi
OUTDIR_FALLBACK=0
[[ "$OUTDIR" == "/tmp" ]] && OUTDIR_FALLBACK=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)      OUTDIR="$2"; OUTDIR_FALLBACK=0; shift 2 ;;
    -h|--help)  sed -n '2,49p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$OUTDIR" 2>/dev/null || { echo "✗ cannot create out dir: $OUTDIR" >&2; exit 1; }

if [[ "$OUTDIR_FALLBACK" -eq 1 ]]; then
  echo "⚠ RaBbLE-BaBbLE/tmp/ not found alongside this repo — writing to /tmp instead." >&2
  echo "  /tmp does not survive a reboot; pass --out DIR to pick a persistent location." >&2
fi

TS_FILE=$(date +%Y%m%d-%H%M%S)
TS_ISO=$(date -Iseconds)
TXT="$OUTDIR/rabble-power-${TS_FILE}.txt"
JSON="$OUTDIR/rabble-power-${TS_FILE}.json"

: > "$TXT"

rule() { printf '\n\033[35m── %s\033[0m\n' "$1"; }
section() {
  rule "$1"
  { printf '\n== %s ==\n' "$1"; } >> "$TXT"
}
out() {
  printf '%s\n' "$1"
  printf '%s\n' "$1" >> "$TXT"
}

# ── JSON helpers (no jq dependency) ──────────────────────────────────────────
json_esc() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"
  printf '%s' "$s"
}
json_str() {  # emits "value" or null
  local v="$1"
  if [[ -z "$v" ]]; then printf 'null'; else printf '"%s"' "$(json_esc "$v")"; fi
}
json_num() {  # emits a bare number or null (guards non-numeric input)
  local v="$1"
  if [[ "$v" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then printf '%s' "$v"; else printf 'null'; fi
}
json_bool() { if [[ "$1" == "1" ]]; then printf 'true'; else printf 'false'; fi }

get_field() {  # get_field "<text>" "<field-name>" — parses "  field:   value" lines
  printf '%s\n' "$1" | grep -m1 -iE "^[[:space:]]*$2:" | sed -E "s/^[[:space:]]*[^:]+:[[:space:]]*//"
}

out "RaBbLE-OS power profile capture — $TS_ISO"
out "host: $(hostname 2>/dev/null || echo unknown)"

# ── 1. Battery ────────────────────────────────────────────────────────────────
section "Battery (upower + sysfs)"

BAT_AVAILABLE=0
BAT_STATE="" BAT_PERCENTAGE="" BAT_ENERGY_RATE="" POWER_NOW_UW="" POWER_NOW_W=""

if command -v upower >/dev/null 2>&1; then
  if UPOWER_DUMP=$(upower --dump 2>/dev/null); then
    out "$UPOWER_DUMP"
  else
    out "(upower --dump unavailable)"
  fi

  BATDEV=$(upower -e 2>/dev/null | grep -m1 -i battery || true)
  LINEDEV=$(upower -e 2>/dev/null | grep -m1 -i line_power || true)

  if [[ -n "$BATDEV" ]]; then
    if UPOWER_BAT=$(upower -i "$BATDEV" 2>/dev/null); then
      BAT_AVAILABLE=1
      out "-- upower -i $BATDEV --"
      out "$UPOWER_BAT"
      BAT_STATE=$(get_field "$UPOWER_BAT" "state")
      BAT_PERCENTAGE_RAW=$(get_field "$UPOWER_BAT" "percentage")
      BAT_ENERGY_RATE_RAW=$(get_field "$UPOWER_BAT" "energy-rate")
      BAT_PERCENTAGE="${BAT_PERCENTAGE_RAW%\%}"
      BAT_ENERGY_RATE="${BAT_ENERGY_RATE_RAW% W}"
    fi
  fi
  if [[ -n "$LINEDEV" ]]; then
    if UPOWER_LINE=$(upower -i "$LINEDEV" 2>/dev/null); then
      out "-- upower -i $LINEDEV --"
      out "$UPOWER_LINE"
    fi
  fi
else
  out "(upower not installed)"
fi

BATDIR=""
for d in /sys/class/power_supply/BAT*; do
  [[ -d "$d" ]] && BATDIR="$d" && break
done

if [[ -n "$BATDIR" && -r "$BATDIR/power_now" ]]; then
  POWER_NOW_UW=$(cat "$BATDIR/power_now" 2>/dev/null || true)
  if [[ "$POWER_NOW_UW" =~ ^[0-9]+$ ]]; then
    BAT_AVAILABLE=1
    POWER_NOW_W=$(awk -v uw="$POWER_NOW_UW" 'BEGIN{printf "%.2f", uw/1000000}')
    out "$BATDIR/power_now: ${POWER_NOW_UW} uW (${POWER_NOW_W} W)"
  fi
else
  out "($BATDIR/power_now unavailable — no BAT0-style sysfs node)"
fi

# ── 2. NVIDIA dGPU ────────────────────────────────────────────────────────────
section "NVIDIA dGPU"

NV_AVAILABLE=0
NV_PCI="" NV_POWER_DRAW="" NV_PSTATE="" NV_TEMP="" NV_UTIL="" NV_POWER_STATE=""

if command -v lspci >/dev/null 2>&1; then
  NV_PCI=$(lspci -d 10de: -D 2>/dev/null | awk '{print $1}' | head -1)
fi

if [[ -n "$NV_PCI" ]]; then
  out "PCI address (derived via lspci -d 10de:): $NV_PCI"
  if [[ -r "/sys/bus/pci/devices/$NV_PCI/power_state" ]]; then
    NV_POWER_STATE=$(cat "/sys/bus/pci/devices/$NV_PCI/power_state" 2>/dev/null || true)
    out "power_state: ${NV_POWER_STATE:-(unavailable)}  (target at idle: D3cold)"
  else
    out "power_state: (unavailable — no power_state sysfs node for $NV_PCI)"
  fi
else
  out "(no NVIDIA PCI device found via lspci -d 10de:)"
fi

if command -v nvidia-smi >/dev/null 2>&1; then
  if NVSMI_LINE=$(nvidia-smi --query-gpu=power.draw,pstate,temperature.gpu,utilization.gpu \
                    --format=csv,noheader,nounits 2>/dev/null | head -1) && [[ -n "$NVSMI_LINE" ]]; then
    NV_AVAILABLE=1
    out "nvidia-smi: $NVSMI_LINE  (power.draw, pstate, temp.gpu, util.gpu)"
    IFS=',' read -r NV_POWER_DRAW NV_PSTATE NV_TEMP NV_UTIL <<< "$NVSMI_LINE"
    NV_POWER_DRAW="${NV_POWER_DRAW// /}"
    NV_PSTATE="${NV_PSTATE// /}"
    NV_TEMP="${NV_TEMP// /}"
    NV_UTIL="${NV_UTIL// /}"
  else
    out "(nvidia-smi unavailable — dGPU may be fully suspended/D3cold, or driver not loaded)"
  fi
else
  out "(nvidia-smi not installed)"
fi

# ── 3. CPU package power (turbostat) ─────────────────────────────────────────
section "CPU package power (turbostat, single-shot)"

TURBOSTAT_AVAILABLE=0
PKG_WATT="" COR_WATT="" RAM_WATT=""

if command -v turbostat >/dev/null 2>&1; then
  if TURBOSTAT_OUT=$(timeout 5 turbostat --quiet --show PkgWatt,CorWatt,RAMWatt \
                       --num_iterations 1 --interval 1 2>&1); then
    out "$TURBOSTAT_OUT"
    PKG_WATT=$(awk -v f="PkgWatt" '
      NR==1 { for (i=1;i<=NF;i++) if ($i==f) col=i; next }
      { if (col) val=$col }
      END { if (val!="") print val }' <<< "$TURBOSTAT_OUT")
    COR_WATT=$(awk -v f="CorWatt" '
      NR==1 { for (i=1;i<=NF;i++) if ($i==f) col=i; next }
      { if (col) val=$col }
      END { if (val!="") print val }' <<< "$TURBOSTAT_OUT")
    RAM_WATT=$(awk -v f="RAMWatt" '
      NR==1 { for (i=1;i<=NF;i++) if ($i==f) col=i; next }
      { if (col) val=$col }
      END { if (val!="") print val }' <<< "$TURBOSTAT_OUT")
    # turbostat can exit 0 with only a permission warning and no data row at
    # all (no MSR access, not run as root) — "available" must mean we actually
    # parsed a number, not just that the command didn't crash.
    if [[ -n "$PKG_WATT" || -n "$COR_WATT" || -n "$RAM_WATT" ]]; then
      TURBOSTAT_AVAILABLE=1
    else
      out "(turbostat ran but returned no Watt counters — needs root/MSR access; re-run with sudo)"
    fi
  else
    out "(turbostat failed — likely needs root/MSR access; re-run with sudo)"
    out "${TURBOSTAT_OUT:-}"
  fi
else
  out "(turbostat not installed)"
fi

# ── 4. Thermals (sensors) ─────────────────────────────────────────────────────
section "Thermals (sensors)"

SENSORS_AVAILABLE=0
if command -v sensors >/dev/null 2>&1; then
  if SENSORS_OUT=$(sensors 2>/dev/null); then
    SENSORS_AVAILABLE=1
    out "$SENSORS_OUT"
  else
    out "(sensors present but read failed — try 'sudo sensors-detect')"
  fi
else
  out "(sensors not installed — lm_sensors package)"
fi

# ── 5. Power profile (tuned + asusd) ──────────────────────────────────────────
section "Power profile (tuned + asusd)"

TUNED_PROFILE=""
if command -v tuned-adm >/dev/null 2>&1; then
  if TUNED_RAW=$(tuned-adm active 2>/dev/null); then
    out "tuned-adm active: $TUNED_RAW"
    TUNED_PROFILE=$(sed -E 's/^[^:]*:[[:space:]]*//' <<< "$TUNED_RAW")
  else
    out "(tuned-adm active unavailable — tuned.service not running?)"
  fi
else
  out "(tuned-adm not installed)"
fi

ASUS_PROFILE=""
if command -v asusctl >/dev/null 2>&1; then
  if ASUS_RAW=$(asusctl profile -p 2>/dev/null); then
    out "asusctl profile -p: $ASUS_RAW"
    ASUS_PROFILE=$(sed -E 's/^[^:]*:[[:space:]]*//' <<< "$ASUS_RAW")
  else
    out "(asusctl profile -p unavailable — asusd.service not running?)"
  fi
else
  out "(asusctl not installed)"
fi

# ── Write JSON snapshot ────────────────────────────────────────────────────────
{
  printf '{\n'
  printf '  "timestamp": %s,\n'        "$(json_str "$TS_ISO")"
  printf '  "battery": {\n'
  printf '    "available": %s,\n'     "$(json_bool "$BAT_AVAILABLE")"
  printf '    "state": %s,\n'         "$(json_str "$BAT_STATE")"
  printf '    "percentage": %s,\n'    "$(json_num "$BAT_PERCENTAGE")"
  printf '    "energy_rate_w": %s,\n' "$(json_num "$BAT_ENERGY_RATE")"
  printf '    "power_now_uw": %s,\n'  "$(json_num "$POWER_NOW_UW")"
  printf '    "power_now_w": %s\n'    "$(json_num "$POWER_NOW_W")"
  printf '  },\n'
  printf '  "nvidia": {\n'
  printf '    "available": %s,\n'      "$(json_bool "$NV_AVAILABLE")"
  printf '    "pci_address": %s,\n'    "$(json_str "$NV_PCI")"
  printf '    "power_draw_w": %s,\n'   "$(json_num "$NV_POWER_DRAW")"
  printf '    "pstate": %s,\n'         "$(json_str "$NV_PSTATE")"
  printf '    "temperature_c": %s,\n'  "$(json_num "$NV_TEMP")"
  printf '    "utilization_pct": %s,\n' "$(json_num "$NV_UTIL")"
  printf '    "power_state": %s\n'     "$(json_str "$NV_POWER_STATE")"
  printf '  },\n'
  printf '  "cpu": {\n'
  printf '    "turbostat_available": %s,\n' "$(json_bool "$TURBOSTAT_AVAILABLE")"
  printf '    "pkg_watt": %s,\n'      "$(json_num "$PKG_WATT")"
  printf '    "cor_watt": %s,\n'      "$(json_num "$COR_WATT")"
  printf '    "ram_watt": %s\n'       "$(json_num "$RAM_WATT")"
  printf '  },\n'
  printf '  "tuned_profile": %s,\n'   "$(json_str "$TUNED_PROFILE")"
  printf '  "asus_profile": %s,\n'    "$(json_str "$ASUS_PROFILE")"
  printf '  "sensors_available": %s\n' "$(json_bool "$SENSORS_AVAILABLE")"
  printf '}\n'
} > "$JSON"

rule "Wrote"
echo "  ✓ text report: $TXT"
echo "  ✓ JSON snapshot: $JSON"

rule "Next steps"
cat <<EOF
  • Diff two JSON snapshots (e.g. before/after a change) to compare numbers:
      diff <(python3 -m json.tool "$JSON") <(python3 -m json.tool <other>.json)
  • nvidia.power_state should read D3cold at idle once the D3cold fix is live
    and the machine has rebooted — see fix/RaBbLE-OS-Fix-Nvidia.md
  • turbostat needing root is expected in a normal desktop session — re-run
    with sudo for real CPU package numbers.
  • Full manual protocol this wraps:
      ../RaBbLE-Grimoire/RaBbLE-OS/verify/RaBbLE-OS-Verify-PowerTesting.md
EOF
