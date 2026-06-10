#!/usr/bin/env bash
# score-claude-hook.sh — Claude Code hook bridge for the sCoRE Usage Tracker.
#
# Wired into ~/.claude/settings.json across Claude's full conversational
# lifecycle (see RaBbLE-OS-dotctl.sh's _post_apply_waybar for the wiring).
# It is the ground truth for each Claude instance's busy/ready/needs-input
# state — guessing from transcript mtimes can't tell "thinking" from "idle"
# because Claude only writes the transcript when a turn completes.
#
#   SessionStart                -> ready        (instance registered)
#   UserPromptSubmit            -> busy         (you just asked it to work)
#   PreToolUse / PostToolUse    -> busy         (it's actively running tools)
#   SubagentStop                -> busy         (parent is digesting the result)
#   Notification (permission)   -> needs-input  (blocked on YOUR authorization)
#   Notification (waiting)      -> ready        (open prompt, not blocked)
#   Stop                        -> ready        (turn finished, idle for input)
#   SessionEnd                  -> deregistered (state file removed)
#
# All real work — per-session state files (multi-instance safe), PID-based
# liveness, aggregation, desktop notifications, and the glyph-stream FIFO
# poke — lives in score-sessions.py. This wrapper only exists so the path
# wired into settings.json stays stable.

exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/score-sessions.py" update
