#!/usr/bin/env bash
# llm-status.sh — Claude Code usage meter for Waybar (JSON output)
#
# Tracks Claude Pro / Claude Code usage against the 5-hour rolling window
# and 7-day weekly cap by parsing ~/.claude/projects/**/*.jsonl transcripts.
# No API key required — reads token counts from local session files.
#
# Waybar usage:
#   "exec": "~/.config/waybar/scripts/llm-status.sh"
#   "return-type": "json"
#   "interval": 30

set -euo pipefail

CLAUDE_DIR="$HOME/.claude/projects"
CACHE_DIR="$HOME/.cache/rabble"
CACHE_FILE="$CACHE_DIR/llm-status.json"

mkdir -p "$CACHE_DIR"

# ── Token counting from JSONL transcripts ─────────────────────────────────────

# Sum input+output tokens from all .jsonl files modified within the last $1 seconds.
# Reads assistant message usage fields: {"usage":{"input_tokens":N,"output_tokens":N}}
count_tokens_since() {
    local seconds_ago="$1"
    local cutoff
    cutoff=$(date -d "@$(( $(date +%s) - seconds_ago ))" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
          || date -v-${seconds_ago}S +%Y-%m-%dT%H:%M:%S 2>/dev/null)

    [[ -d "$CLAUDE_DIR" ]] || { echo "0 0"; return; }

    python3 - "$CLAUDE_DIR" "$cutoff" "$seconds_ago" <<'PYEOF'
import sys, os, json, time, pathlib

proj_dir  = sys.argv[1]
cutoff_s  = sys.argv[2]
window_s  = int(sys.argv[3])
now       = time.time()
cutoff_t  = now - window_s

total_in  = 0
total_out = 0
oldest_ts = now   # oldest message timestamp inside the window

for jl in pathlib.Path(proj_dir).rglob("*.jsonl"):
    try:
        mtime = jl.stat().st_mtime
        # Skip files not touched in the window (fast path)
        if mtime < cutoff_t - 60:
            continue
        with open(jl) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue

                # Timestamp is stored as ISO string on most entries
                ts_raw = entry.get("timestamp") or entry.get("ts") or ""
                if ts_raw:
                    try:
                        import datetime
                        ts = datetime.datetime.fromisoformat(ts_raw.replace("Z","+00:00")).timestamp()
                    except Exception:
                        ts = mtime
                else:
                    ts = mtime

                if ts < cutoff_t:
                    continue

                # Pull usage from assistant messages
                msg = entry.get("message", {})
                usage = msg.get("usage") or entry.get("usage") or {}
                inp = usage.get("input_tokens", 0)
                out = usage.get("output_tokens", 0)
                if inp or out:
                    total_in  += inp
                    total_out += out
                    if ts < oldest_ts:
                        oldest_ts = ts
    except Exception:
        continue

# When does the 5h window free up? = oldest_ts + window_s
reset_in_s = max(0, int(oldest_ts + window_s - now)) if (total_in + total_out) > 0 else 0
print(total_in + total_out, reset_in_s)
PYEOF
}

# ── Agent activity detection ──────────────────────────────────────────────────

claude_is_running() {
    pgrep -x "claude" &>/dev/null || pgrep -f "claude.*code" &>/dev/null
}

claude_is_busy() {
    [[ -d "$CLAUDE_DIR" ]] || return 1
    # A transcript touched in the last 90 seconds = active session
    find "$CLAUDE_DIR" -name "*.jsonl" -newer "$CACHE_FILE" 2>/dev/null \
        | head -1 | grep -q . 2>/dev/null
}

# ── Format helpers ────────────────────────────────────────────────────────────

fmt_tokens() {
    local t="$1"
    if   (( t >= 1000000 )); then printf "%.1fM" "$(echo "scale=1; $t / 1000000" | bc)"
    elif (( t >= 1000 ));    then printf "%.0fK" "$(echo "scale=0; $t / 1000" | bc)"
    else                          echo "$t"
    fi
}

fmt_reset() {
    local s="$1"
    (( s <= 0 )) && { echo "now"; return; }
    local h=$(( s / 3600 ))
    local m=$(( (s % 3600) / 60 ))
    (( h > 0 )) && echo "${h}h ${m}m" || echo "${m}m"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    # 5-hour window = 18000 seconds; 7-day window = 604800 seconds
    local five_h_data weekly_data
    five_h_data=$(count_tokens_since 18000)
    weekly_data=$(count_tokens_since 604800)

    local five_h_tok reset_in_s weekly_tok weekly_reset
    read -r five_h_tok reset_in_s <<< "$five_h_data"
    read -r weekly_tok _          <<< "$weekly_data"

    # State
    local state="idle"
    local state_icon="󰌪"   # sleep
    if claude_is_running; then
        state="ready"
        state_icon="󰅐"     # timer-sand
    fi
    # Recent transcript activity = actively generating
    if [[ -f "$CACHE_FILE" ]] && find "$CLAUDE_DIR" -name "*.jsonl" \
            -newer "$CACHE_FILE" 2>/dev/null | grep -q .; then
        state="busy"
        state_icon="󱐋"     # lightning-bolt
    fi

    # Bar text
    local five_h_fmt weekly_fmt reset_fmt
    five_h_fmt=$(fmt_tokens "$five_h_tok")
    weekly_fmt=$(fmt_tokens "$weekly_tok")
    reset_fmt=$(fmt_reset   "$reset_in_s")

    local text="󰋦 ${state_icon} ${five_h_fmt}"

    # Tooltip
    local tooltip
    tooltip="Claude Code — ${state}\n"
    tooltip+="5h window : ${five_h_fmt} tokens"
    if (( five_h_tok > 0 )); then
        tooltip+="  (resets in ${reset_fmt})"
    fi
    tooltip+="\nWeek      : ${weekly_fmt} tokens"

    local other_agents=""
    pgrep -x "codex"  &>/dev/null && other_agents+=" codex"
    pgrep -x "gemini" &>/dev/null && other_agents+=" gemini"
    [[ -n "$other_agents" ]] && tooltip+="\nAlso running:${other_agents}"

    # CSS class for coloring
    local css_class="llm-${state}"

    printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' \
        "$text" \
        "$(echo -e "$tooltip" | sed 's/"/\\"/g')" \
        "$css_class"

    # Touch the cache file so "newer" check works next poll
    touch "$CACHE_FILE"
}

main
