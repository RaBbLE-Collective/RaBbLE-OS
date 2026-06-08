#!/usr/bin/env bash
# score-claude-hook.sh — Claude Code hook bridge for the sCoRE Usage Tracker.
#
# Wired into ~/.claude/settings.json as a Notification + PreToolUse +
# UserPromptSubmit hook. Its only job is to drop/clear a marker file that
# score-status.sh reads to light up the "needs input" state — there is no
# on-disk signal that distinguishes "thinking" from "blocked on a permission
# prompt" without this, since both look identical in the transcript (an
# assistant tool_use with no result yet).
#
#   Notification (message mentions permission) -> touch marker  (needs input)
#   PreToolUse / UserPromptSubmit               -> remove marker (resolved)
#
# Claude-only by necessity — Codex has no equivalent hook surface yet. If/when
# it grows one, mirror this bridge for the codex side.

MARKER="$HOME/.cache/rabble/claude-needs-input"
mkdir -p "$(dirname "$MARKER")" 2>/dev/null || true

input="$(cat)"
event="$(printf '%s' "$input" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("hook_event_name",""))' 2>/dev/null)"

case "$event" in
    Notification)
        message="$(printf '%s' "$input" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("message",""))' 2>/dev/null)"
        if printf '%s' "$message" | grep -qi "permission"; then
            touch "$MARKER" 2>/dev/null || true
        fi
        ;;
    PreToolUse|UserPromptSubmit)
        rm -f "$MARKER" 2>/dev/null || true
        ;;
esac

exit 0
