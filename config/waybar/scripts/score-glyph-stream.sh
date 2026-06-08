#!/usr/bin/env bash
# score-glyph-stream.sh — cheap, high-frequency glyph repaint for Waybar.
#
# Waybar custom modules normally re-`exec` their script every "interval"
# seconds — fine for the heavy sCoRE computation (~0.6s/call), but far too
# slow and CPU-heavy to drive a smooth busy-glyph animation. Waybar also
# supports a "continuous" mode: run the command once with no interval, and
# treat each line of stdout as a fresh JSON state. This script is built for
# that mode — it loops at GLYPH_INTERVAL_S, reads the cached JSON that
# score-status-daemon.sh refreshes every few seconds, swaps the literal
# "@GLYPH@" placeholder for the live glyph (pure bash string substitution —
# no subprocess, no parsing), and prints the patched line.
#
# This keeps the expensive transcript-parsing on its own slow cadence while
# the glyph itself updates as fast as Waybar will redraw.

mode="${1:-claude}"
GLYPH_INTERVAL_S="${SCORE_GLYPH_INTERVAL_S:-0.2}"
CACHE="$HOME/.cache/rabble/score-${mode}.json"
NEEDS_INPUT_MARKER="$HOME/.cache/rabble/claude-needs-input"

SPIN_FRAMES=(▁ ▂ ▄ ▆ █ ▆ ▄ ▂)
case "$mode" in
    claude) IDLE_GLYPH="✱" ;;
    codex)  IDLE_GLYPH=">_" ;;
    *)      IDLE_GLYPH="·" ;;
esac
NEEDS_INPUT_GLYPH="⚑"
READY_GLYPH="▶"

# Phase-offset the wave so Claude and Codex don't animate in lockstep —
# matches the offsets score-status.sh's spin_glyph() uses (claude=0, codex=2).
case "$mode" in
    codex) SPIN_OFFSET=2 ;;
    *)     SPIN_OFFSET=0 ;;
esac

# Avoid forking `date` every tick — bash's strftime builtin is free.
now_s() { printf -v "$1" '%(%s)T' -1; }

while true; do
    if [[ -r "$CACHE" ]]; then
        raw="$(<"$CACHE")"

        # Cheap, dependency-free class extraction (no jq/python in the hot
        # loop). The `*` between ':' and the opening quote tolerates the
        # space python's json.dumps puts after the colon ("class": "...").
        class="${raw#*\"class\":*\"}"
        class="${class%%\"*}"
        cached_class="$class"

        # The marker is the live signal — the hook drops/clears it the instant
        # a permission prompt appears or resolves. Checking it here (a single
        # stat, no subprocess) means "needs input" reacts immediately instead
        # of waiting up to HEAVY_INTERVAL_S for the daemon to re-parse and
        # rewrite the cached class — and we patch the class field in `raw`
        # too, so the CSS (color/flash animation) flips instantly along with
        # the glyph, not just the icon.
        if [[ "$mode" == "claude" && -f "$NEEDS_INPUT_MARKER" ]]; then
            class="llm-needs-input"
            raw="${raw/\"$cached_class\"/\"$class\"}"
        fi

        glyph=""
        case "$class" in
            *needs-input*) glyph="$NEEDS_INPUT_GLYPH" ;;
            *busy*)
                now_s now
                idx=$(( (now + SPIN_OFFSET) % ${#SPIN_FRAMES[@]} ))
                glyph="${SPIN_FRAMES[$idx]}"
                ;;
            *ready*) glyph="$READY_GLYPH" ;;
            *)       glyph="$IDLE_GLYPH" ;;
        esac

        printf '%s\n' "${raw//@GLYPH@/$glyph}"
    fi
    sleep "$GLYPH_INTERVAL_S"
done
