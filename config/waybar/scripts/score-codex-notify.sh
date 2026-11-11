#!/usr/bin/env bash
# score-codex-notify.sh — Codex notify bridge for the sCoRE Usage Tracker.
#
# Wired into ~/.codex/config.toml as the top-level `notify` program (see
# RaBbLE-OS-dotctl.sh's _post_apply_waybar). Codex invokes it with a JSON
# payload as the last argument when a turn completes (agent-turn-complete) —
# the only lifecycle event Codex exposes today. That single event still buys
# a lot: an instant "ready" flip on the bar (instead of waiting out the
# transcript-mtime heuristic's window) plus a desktop notification with the
# turn's final message.
#
# Busy detection for Codex remains heuristic (recent transcript writes) —
# there is no turn-start hook surface yet. Mirror score-claude-hook.sh's
# event table if/when Codex grows one.

exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/score-sessions.py" codex-notify "$@"
