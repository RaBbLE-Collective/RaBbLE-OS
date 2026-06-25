#!/usr/bin/env bash
# =============================================================================
# sddm-screenshot.sh — SDDM greeter screenshot for layout QA
#
# Clears the QML bytecode cache, launches sddm-greeter-qt6 in --test-mode on
# the focused Wayland output, captures it with grim, then kills the greeter.
# Run this whenever you edit Main.qml, the layout knobs, EntityDisplay, or
# LoginForm — the cache clear ensures source changes are actually loaded.
#
# Usage (from RaBbLE-OS/):
#   bash spells/sddm-screenshot.sh
#   bash spells/sddm-screenshot.sh --open        # open in imv after capture
#   bash spells/sddm-screenshot.sh --check       # parse-check only, no screenshot
#   bash spells/sddm-screenshot.sh --delay 4     # wait longer before capture
#   bash spells/sddm-screenshot.sh --no-cache    # skip cache clear (rarely needed)
#   bash spells/sddm-screenshot.sh --out /tmp/test.png
#
# Output lands in: RaBbLE-BaBbLE/captures/_inbox/sddm-YYYYMMDD-HHMMSS.png
#
# spark ~ os/sddm >> one-command greeter screenshot spell
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_ROOT="${SCRIPT_DIR}/.."
COLLECTIVE_ROOT="${SCRIPT_DIR}/../.."
THEME_DIR="${OS_ROOT}/ansible/roles/boot/session_manager/files/sddm-theme"
CAPTURES_DIR="${COLLECTIVE_ROOT}/RaBbLE-BaBbLE/captures/_inbox"
QML_CACHE="${HOME}/.cache/sddm-greeter-qt6/qmlcache"

DELAY=3
OPEN=false
CHECK_ONLY=false
NO_CACHE=false
OUT=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --delay)   DELAY="${2:?--delay requires a number}"; shift 2 ;;
        --open)    OPEN=true; shift ;;
        --check)   CHECK_ONLY=true; shift ;;
        --no-cache) NO_CACHE=true; shift ;;
        --out)     OUT="${2:?--out requires a path}"; shift 2 ;;
        --theme)   THEME_DIR="${2:?--theme requires a path}"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Preflight ─────────────────────────────────────────────────────────────────
if ! command -v sddm-greeter-qt6 &>/dev/null; then
    echo "✗  sddm-greeter-qt6 not found — is sddm installed?" >&2
    exit 1
fi
if [[ ! -f "${THEME_DIR}/Main.qml" ]]; then
    echo "✗  Theme not found at: ${THEME_DIR}" >&2
    exit 1
fi

# ── QML cache clear ───────────────────────────────────────────────────────────
if [[ "${NO_CACHE}" == false && -d "${QML_CACHE}" ]]; then
    rm -rf "${QML_CACHE}"
    echo "  cleared QML cache"
fi

# ── Parse-check mode (offscreen, no screenshot) ───────────────────────────────
if [[ "${CHECK_ONLY}" == true ]]; then
    echo "  parse-checking QML (offscreen)…"
    QT_QPA_PLATFORM=offscreen timeout 8 sddm-greeter-qt6 --test-mode \
        --theme "${THEME_DIR}" 2>&1 || true
    EXIT=$?
    if [[ $EXIT -eq 0 || $EXIT -eq 124 ]]; then
        echo "✓  QML OK (exit ${EXIT})"
    else
        echo "✗  QML error (exit ${EXIT})" >&2
        exit "${EXIT}"
    fi
    exit 0
fi

# ── Screenshot mode ───────────────────────────────────────────────────────────
if ! command -v grim &>/dev/null; then
    echo "✗  grim not found — install with: sudo dnf install grim" >&2
    exit 1
fi

# Resolve output path
if [[ -z "${OUT}" ]]; then
    mkdir -p "${CAPTURES_DIR}"
    STAMP=$(date +%Y%m%d-%H%M%S)
    OUT="${CAPTURES_DIR}/sddm-${STAMP}.png"
fi

# Detect focused monitor
MONITOR=$(hyprctl monitors -j 2>/dev/null \
    | python3 -c "
import sys, json
mons = json.load(sys.stdin)
focused = [m['name'] for m in mons if m.get('focused')]
print(focused[0] if focused else mons[0]['name'])
" 2>/dev/null || echo "")

if [[ -z "${MONITOR}" ]]; then
    echo "  could not detect focused monitor — grim will capture all outputs"
    GRIM_ARGS=()
else
    GRIM_ARGS=(-o "${MONITOR}")
fi

# Launch greeter
echo "  launching greeter (delay ${DELAY}s)…"
QT_QPA_PLATFORM=wayland sddm-greeter-qt6 --test-mode --theme "${THEME_DIR}" &>/dev/null &
GPID=$!

# Give the greeter time to render (entity fade-in = 500ms; add headroom)
sleep "${DELAY}"

# Verify the greeter is still running before we shoot
if ! kill -0 "${GPID}" 2>/dev/null; then
    echo "✗  greeter exited before screenshot — check QML for errors" >&2
    exit 1
fi

# Capture
grim "${GRIM_ARGS[@]}" "${OUT}"
kill "${GPID}" 2>/dev/null || true
wait "${GPID}" 2>/dev/null || true

echo "✓  ${OUT}"

if [[ "${OPEN}" == true ]]; then
    if command -v imv &>/dev/null; then
        imv "${OUT}" &
    elif command -v eog &>/dev/null; then
        eog "${OUT}" &
    else
        echo "  (--open: no imv or eog found)"
    fi
fi
