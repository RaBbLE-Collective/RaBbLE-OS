#!/usr/bin/env bash
# score-status-daemon.sh — heavy-tier cache writer for the sCoRE Usage Tracker.
#
# score-status.sh's full computation (parsing every ~/.claude/projects and
# ~/.codex/sessions transcript, building the tooltip, etc.) costs ~0.5-0.6s
# per call — too expensive to run at the 5-8Hz cadence the busy-glyph
# animation wants. So we split the work into two tiers:
#
#   heavy tier (this daemon)   — recomputes the full JSON every HEAVY_INTERVAL_S
#                                seconds with RABBLE_GLYPH_PLACEHOLDER=1 (the
#                                glyph comes out as the literal "@GLYPH@"), and
#                                caches it to ~/.cache/rabble/score-<mode>.json
#   cheap tier (glyph-stream)  — score-glyph-stream.sh repaints just the glyph
#                                on top of that cache at high frequency; Waybar
#                                runs it continuously (no "interval" polling)
#
# Run as a persistent background process (see hypr/conf.d/autostart.conf),
# alongside score-usage-api-poll.py.

set -euo pipefail

HEAVY_INTERVAL_S="${SCORE_HEAVY_INTERVAL_S:-5}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$HOME/.cache/rabble"
mkdir -p "$CACHE_DIR"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

log "score-status-daemon starting (refresh every ${HEAVY_INTERVAL_S}s)"

while true; do
    for mode in claude codex; do
        out="$CACHE_DIR/score-${mode}.json"
        tmp="${out}.tmp.$$"
        if RABBLE_GLYPH_PLACEHOLDER=1 bash "$SCRIPT_DIR/score-status.sh" "$mode" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$out"
        else
            rm -f "$tmp"
            log "WARN: score-status.sh $mode failed this cycle"
        fi
    done
    sleep "$HEAVY_INTERVAL_S"
done
