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
# The loop sleeps via a read on a wake-FIFO rather than plain `sleep`, so a
# state change is an *interrupt*, not something we have to poll our way into
# noticing: score-claude-hook.sh writes the new ground-truth state straight
# to $CLAUDE_LIVE_STATE_FILE and pokes the FIFO the instant Claude's lifecycle
# changes (prompt submitted, tool blocked on permission, response finished),
# which wakes this loop immediately — `read -t` still times out on its own
# for the cadence-driven busy-glyph animation frames and periodic heavy-data
# repaint when nothing has interrupted it.

mode="${1:-claude}"
GLYPH_INTERVAL_S="${SCORE_GLYPH_INTERVAL_S:-0.2}"
CACHE_DIR="$HOME/.cache/rabble"
CACHE="$CACHE_DIR/score-${mode}.json"
CLAUDE_LIVE_STATE_FILE="$CACHE_DIR/claude-live-state"
WAKE_FIFO="$CACHE_DIR/score-${mode}-wake.fifo"

mkdir -p "$CACHE_DIR" 2>/dev/null || true
[[ -p "$WAKE_FIFO" ]] || { rm -f "$WAKE_FIFO" 2>/dev/null; mkfifo "$WAKE_FIFO" 2>/dev/null; }
# Open read-write so our own `read` never blocks forever waiting on a writer,
# and so a hook's write never blocks waiting on a reader — both ends of the
# pipe are always held open by this one fd.
exec 3<>"$WAKE_FIFO"

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

        # score-claude-hook.sh is ground truth for Claude's lifecycle —
        # it knows "prompt submitted"/"blocked on permission"/"response
        # finished" directly from Claude Code itself, not by guessing from
        # transcript mtimes (which can't tell "thinking" from "idle" and
        # is what caused the tracker to flash "ready" mid-response). When
        # it's fresh, it overrides both the glyph and the cached `class`
        # field in `raw` so the CSS color/flash flips with it, instantly.
        if [[ "$mode" == "claude" && -f "$CLAUDE_LIVE_STATE_FILE" ]]; then
            now_s now
            state_age=$(( now - $(stat -c %Y "$CLAUDE_LIVE_STATE_FILE" 2>/dev/null || echo "$now") ))
            if (( state_age < 600 )); then
                live="$(<"$CLAUDE_LIVE_STATE_FILE")"
                case "$live" in
                    busy|ready|needs-input)
                        class="llm-${live}"
                        raw="${raw/\"$cached_class\"/\"$class\"}"
                        ;;
                esac
            fi
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

    # Sleep by reading the wake-FIFO with a timeout: a hook poking the FIFO
    # makes `read` return immediately (interrupt-driven repaint on state
    # change); the timeout firing with nothing written is the normal cadence
    # tick that drives the busy-glyph wave and periodic heavy-data refresh.
    read -t "$GLYPH_INTERVAL_S" -r _ <&3 || true
done
