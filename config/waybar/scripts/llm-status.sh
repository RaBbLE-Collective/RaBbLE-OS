#!/usr/bin/env bash
# llm-status.sh — Claude Code usage meter for Waybar (JSON output)
#
# Tracks Claude Pro / Claude Code usage against the 5-hour rolling window
# and 7-day weekly cap by parsing ~/.claude/projects/**/*.jsonl transcripts.
# No API key required — reads token counts from local session files.
#
# ── Configure your plan limits here ─────────────────────────────────────────
# Set to 0 if unknown — the bar shows raw token count instead of percentage.
# Tune these after hitting a rate limit: note your token count at that moment.
#
# NOTE: Anthropic's usage meter does NOT weigh tokens 1:1 — output tokens cost
# more than input, and model multipliers apply (Opus ~2x+, Sonnet 1x, Haiku <1x).
# This script just sums raw input+output tokens, so any fixed limit here is an
# approximation that will drift as your model/in-out mix changes. Recalibrate
# whenever the bar's % and the web meter's % diverge meaningfully.
#
# Recalibrated 2026-06-08 against web usage meter:
#   5h window : ~402K tokens measured at web "50%"  → 402000 / 0.50 ≈ 804K
#   weekly    : ~2.80M tokens measured at web "19%" → 2800000 / 0.19 ≈ 14.7M
FIVE_H_LIMIT=804000     # tokens per 5-hour rolling window  (estimated from 50% @ ~402K)
WEEKLY_LIMIT=14700000   # tokens per 7-day rolling window   (estimated from 19% @ ~2.8M)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

CLAUDE_DIR="$HOME/.claude/projects"
CACHE_DIR="$HOME/.cache/rabble"
CACHE_FILE="$CACHE_DIR/llm-status.json"

mkdir -p "$CACHE_DIR"

# ── Token counting from JSONL transcripts ─────────────────────────────────────

count_tokens_since() {
    local seconds_ago="$1"

    [[ -d "$CLAUDE_DIR" ]] || { echo "0 0"; return; }

    python3 - "$CLAUDE_DIR" "$seconds_ago" <<'PYEOF'
import sys, os, json, time, pathlib, datetime

proj_dir  = sys.argv[1]
window_s  = int(sys.argv[2])
now       = time.time()
cutoff_t  = now - window_s

total_in  = 0
total_out = 0
oldest_ts = now

for jl in pathlib.Path(proj_dir).rglob("*.jsonl"):
    try:
        if jl.stat().st_mtime < cutoff_t - 60:
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

                ts_raw = entry.get("timestamp") or entry.get("ts") or ""
                ts = jl.stat().st_mtime
                if ts_raw:
                    try:
                        ts = datetime.datetime.fromisoformat(
                            ts_raw.replace("Z", "+00:00")
                        ).timestamp()
                    except Exception:
                        pass

                if ts < cutoff_t:
                    continue

                msg   = entry.get("message", {})
                usage = msg.get("usage") or entry.get("usage") or {}
                inp   = usage.get("input_tokens", 0)
                out   = usage.get("output_tokens", 0)
                if inp or out:
                    total_in  += inp
                    total_out += out
                    if ts < oldest_ts:
                        oldest_ts = ts
    except Exception:
        continue

reset_in_s = max(0, int(oldest_ts + window_s - now)) if (total_in + total_out) > 0 else 0
print(total_in, total_out, reset_in_s)
PYEOF
}

# ── Agent state ───────────────────────────────────────────────────────────────

claude_is_running() {
    pgrep -x "claude" &>/dev/null || pgrep -f "claude.*code" &>/dev/null
}

# ── Format helpers ────────────────────────────────────────────────────────────

fmt_tokens() {
    local t="$1"
    if   (( t >= 1000000 )); then printf "%.1fM" "$(echo "scale=1; $t / 1000000" | bc)"
    elif (( t >= 1000 ));    then printf "%.0fK" "$(echo "scale=0; $t / 1000" | bc)"
    else                          echo "$t"
    fi
}

fmt_pct() {
    local used="$1" limit="$2"
    (( limit > 0 )) && printf "%d%%" "$(( used * 100 / limit ))" || fmt_tokens "$used"
}

fmt_reset() {
    local s="$1"
    (( s <= 0 )) && { echo "now"; return; }
    local h=$(( s / 3600 )) m=$(( (s % 3600) / 60 ))
    (( h > 0 )) && echo "${h}h ${m}m" || echo "${m}m"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    local five_h_data weekly_data
    five_h_data=$(count_tokens_since 18000)
    weekly_data=$(count_tokens_since 604800)

    local five_h_in five_h_out reset_in_s weekly_in weekly_out
    read -r five_h_in five_h_out reset_in_s <<< "$five_h_data"
    read -r weekly_in weekly_out _          <<< "$weekly_data"

    local five_h_tok=$(( five_h_in + five_h_out ))
    local weekly_tok=$(( weekly_in + weekly_out ))

    # Agent state
    local state="idle"
    local state_label="idle"
    if claude_is_running; then
        state="ready"
        state_label="ready"
    fi
    if [[ -f "$CACHE_FILE" ]] && find "$CLAUDE_DIR" -name "*.jsonl" \
            -newer "$CACHE_FILE" 2>/dev/null | grep -q .; then
        state="busy"
        state_label="busy"
    fi

    # Bar text: state indicator + 5h usage + weekly usage
    local five_h_disp weekly_disp reset_fmt
    five_h_disp=$(fmt_pct  "$five_h_tok" "$FIVE_H_LIMIT")
    weekly_disp=$(fmt_pct  "$weekly_tok" "$WEEKLY_LIMIT")
    reset_fmt=$(fmt_reset  "$reset_in_s")

    # State markers using standard Unicode (no Nerd Font required)
    local state_mark
    case "$state" in
        busy)  state_mark="⚡" ;;
        ready) state_mark="▶" ;;
        *)     state_mark="·" ;;
    esac

    local five_h_in_disp five_h_out_disp
    five_h_in_disp=$(fmt_tokens "$five_h_in")
    five_h_out_disp=$(fmt_tokens "$five_h_out")

    local text="C ${state_mark} ↓${five_h_in_disp} ↑${five_h_out_disp} ${five_h_disp}"
    (( weekly_tok > 0 )) && text+=" / ${weekly_disp}wk"

    # Tooltip
    local five_h_raw weekly_raw weekly_in_disp weekly_out_disp
    five_h_raw=$(fmt_tokens "$five_h_tok")
    weekly_raw=$(fmt_tokens "$weekly_tok")
    weekly_in_disp=$(fmt_tokens "$weekly_in")
    weekly_out_disp=$(fmt_tokens "$weekly_out")

    local tt1="Claude Code — ${state_label}"

    local tt2="5h window : ${five_h_raw} tokens (↓${five_h_in_disp} in / ↑${five_h_out_disp} out)"
    (( FIVE_H_LIMIT > 0 ))  && tt2+=" / $(fmt_tokens $FIVE_H_LIMIT) limit (${five_h_disp})"
    (( five_h_tok  > 0 ))   && tt2+="  [resets in ${reset_fmt}]"

    local tt3="Week      : ${weekly_raw} tokens (↓${weekly_in_disp} in / ↑${weekly_out_disp} out)"
    (( WEEKLY_LIMIT > 0 ))  && tt3+=" / $(fmt_tokens $WEEKLY_LIMIT) limit (${weekly_disp})"

    local other=""
    pgrep -x "codex"  &>/dev/null && other+=" codex"
    pgrep -x "gemini" &>/dev/null && other+=" gemini"
    local tt4="${other:+Also running:${other}}"

    local css_class="llm-${state}"

    RABBLE_TEXT="$text" \
    RABBLE_TT1="$tt1" \
    RABBLE_TT2="$tt2" \
    RABBLE_TT3="$tt3" \
    RABBLE_TT4="$tt4" \
    RABBLE_CLASS="$css_class" \
    python3 -c "
import json, os
parts = [os.environ[k] for k in ('RABBLE_TT1','RABBLE_TT2','RABBLE_TT3')]
tt4 = os.environ['RABBLE_TT4']
if tt4: parts.append(tt4)
print(json.dumps({
    'text':    os.environ['RABBLE_TEXT'],
    'tooltip': '\n'.join(parts),
    'class':   os.environ['RABBLE_CLASS'],
}, ensure_ascii=False))
"

    touch "$CACHE_FILE"
}

main
