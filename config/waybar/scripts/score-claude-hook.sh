#!/usr/bin/env bash
# score-claude-hook.sh — Claude Code hook bridge for the sCoRE Usage Tracker.
#
# Wired into ~/.claude/settings.json across Claude's full conversational
# lifecycle. It is the *only* ground truth for Claude's busy/ready/needs-input
# state — guessing from transcript mtimes (the old approach) can't tell
# "thinking" from "idle" because Claude doesn't write to the transcript while
# generating, only when a turn completes, so the tracker would flash "ready"
# mid-response.
#
#   UserPromptSubmit            -> busy         (you just asked it to work)
#   PreToolUse / PostToolUse    -> busy         (it's actively running tools)
#   Notification (permission)   -> needs-input  (blocked on YOUR authorization)
#   Stop / SubagentStop         -> ready        (turn finished, idle for input)
#
# State lands in $STATE_FILE as a single word that score-status.sh /
# score-glyph-stream.sh treat as authoritative over their own heuristics
# whenever it's fresh (< 10 minutes old — stale beyond that falls back to
# the heuristic, so a crashed/killed Claude can't wedge the pill in "busy"
# forever).
#
# The *push*: rather than make the glyph-stream poll for this file to change,
# we poke its wake-FIFO directly the instant the state lands — an interrupt,
# not something it has to notice on its own schedule. See score-glyph-stream.sh
# for the read side of that handshake.
#
# Claude-only by necessity — Codex has no hook surface yet. If/when it grows
# one, mirror this bridge for the codex side.

CACHE_DIR="$HOME/.cache/rabble"
STATE_FILE="$CACHE_DIR/claude-live-state"
WAKE_FIFO="$CACHE_DIR/score-claude-wake.fifo"
mkdir -p "$CACHE_DIR" 2>/dev/null || true

input="$(cat)"
event="$(printf '%s' "$input" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("hook_event_name",""))' 2>/dev/null)"

new_state=""
case "$event" in
    UserPromptSubmit|PreToolUse|PostToolUse)
        new_state="busy"
        ;;
    Notification)
        message="$(printf '%s' "$input" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("message",""))' 2>/dev/null)"
        if printf '%s' "$message" | grep -qi "permission"; then
            new_state="needs-input"
        fi
        ;;
    Stop|SubagentStop)
        new_state="ready"
        ;;
esac

if [[ -n "$new_state" ]]; then
    printf '%s' "$new_state" > "$STATE_FILE.tmp" 2>/dev/null && mv -f "$STATE_FILE.tmp" "$STATE_FILE" 2>/dev/null

    # Wake the glyph-stream loop immediately. The FIFO write would block
    # forever if no reader has it open (e.g. Waybar isn't running yet), so
    # guard it with `timeout` and push it to the background — this hook must
    # return promptly, Claude is waiting on it.
    if [[ -p "$WAKE_FIFO" ]]; then
        ( timeout 0.5 bash -c "printf x > '$WAKE_FIFO'" >/dev/null 2>&1 & disown ) 2>/dev/null || true
    fi
fi

exit 0
