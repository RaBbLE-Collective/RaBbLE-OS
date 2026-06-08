#!/usr/bin/env bash
# score-status.sh — Claude/Codex usage meter for Waybar (JSON output)
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
CODEX_DIR="$HOME/.codex/sessions"
CACHE_DIR="$HOME/.cache/rabble"
CACHE_FILE="$CACHE_DIR/llm-status.json"
OBS_FILE="$CACHE_DIR/llm-usage-latest.json"

mkdir -p "$CACHE_DIR" 2>/dev/null || true

# ── Token counting from JSONL transcripts ─────────────────────────────────────

count_tokens_since() {
    local seconds_ago="$1"
    local cutoff_override="${2:-}"

    [[ -d "$CLAUDE_DIR" ]] || { echo "0 0"; return; }

    python3 - "$CLAUDE_DIR" "$seconds_ago" "$cutoff_override" <<'PYEOF'
import sys, os, json, time, pathlib, datetime

proj_dir  = sys.argv[1]
window_s  = int(sys.argv[2])
cutoff_override = sys.argv[3]
now       = time.time()
# Anthropic's 5h window resets at a fixed wall-clock boundary, not on a
# rolling "last 18000s" basis — once it rolls over, only tokens spent since
# THAT reset count toward the new window. When the API has told us the actual
# reset time (resets_at - window_length), use that as the cutoff instead of
# the rolling guess, so the bar doesn't double-count tokens from the prior
# window that the meter has already forgotten about.
cutoff_t  = float(cutoff_override) if cutoff_override else (now - window_s)

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

latest_observed_pct() {
    local window_label="$1" max_age_s="$2"
    [[ -f "$OBS_FILE" ]] || { echo ""; return; }

    python3 - "$OBS_FILE" "$window_label" "$max_age_s" <<'PYEOF'
import json, pathlib, sys, time

path = pathlib.Path(sys.argv[1])
window = sys.argv[2]
max_age = int(sys.argv[3])
now = time.time()

try:
    data = json.loads(path.read_text())
    row = data.get(window) or {}
    ts = float(row.get("ts", 0))
    pct = float(row["pct"])
except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
    sys.exit(0)

# API observations carry Anthropic's own reset timestamp — far more accurate
# than the local guess (oldest-transcript-ts + window length), which drifts
# whenever the actual window has already rolled over.
reset_epoch = ""
raw_reset = row.get("resets_at")
if raw_reset:
    try:
        import datetime
        if isinstance(raw_reset, str):
            reset_epoch = int(datetime.datetime.fromisoformat(
                raw_reset.replace("Z", "+00:00")
            ).timestamp())
        else:
            reset_epoch = int(raw_reset)
    except Exception:
        reset_epoch = ""

if 0 <= pct <= 100 and now - ts <= max_age:
    print(f"{pct:g} {int(now - ts)} {reset_epoch}")
PYEOF
}

codex_usage() {
    [[ -d "$CODEX_DIR" ]] || { echo ""; return; }

    python3 - "$CODEX_DIR" <<'PYEOF'
import datetime
import json
import pathlib
import sys
import time

root = pathlib.Path(sys.argv[1])
latest = None
now = time.time()
snapshots = []
tokens_7d = {"input": 0, "cached": 0, "output": 0, "reasoning": 0, "total": 0}
tokens_5h = {"input": 0, "cached": 0, "output": 0, "reasoning": 0, "total": 0}

def parse_ts(row, path):
    raw = row.get("timestamp")
    if raw:
        try:
            return datetime.datetime.fromisoformat(raw.replace("Z", "+00:00")).timestamp()
        except Exception:
            pass
    try:
        return float(row.get("ts"))
    except (TypeError, ValueError):
        return path.stat().st_mtime

def add_tokens(bucket, usage):
    bucket["input"] += int(usage.get("input_tokens", 0) or 0)
    bucket["cached"] += int(usage.get("cached_input_tokens", 0) or 0)
    bucket["output"] += int(usage.get("output_tokens", 0) or 0)
    bucket["reasoning"] += int(usage.get("reasoning_output_tokens", 0) or 0)
    bucket["total"] += int(usage.get("total_tokens", 0) or 0)

def snapshot_at_or_before(target_ts):
    chosen = None
    for snap in snapshots:
        if snap["ts"] <= target_ts and (chosen is None or snap["ts"] > chosen["ts"]):
            chosen = snap
    return chosen

for path in root.rglob("*.jsonl"):
    try:
        if path.stat().st_mtime < now - 604800 - 3600:
            continue
        session_latest = None
        with path.open() as f:
            for line in f:
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                payload = row.get("payload") or {}
                if payload.get("type") != "token_count":
                    continue
                ts = parse_ts(row, path)
                rate = payload.get("rate_limits") or {}
                primary = rate.get("primary") or {}
                if primary.get("used_percent") is not None:
                    snapshots.append({
                        "ts": ts,
                        "used_percent": float(primary.get("used_percent") or 0),
                    })
                info = payload.get("info") or {}
                usage = info.get("last_token_usage") or {}
                if usage:
                    if ts >= now - 604800:
                        add_tokens(tokens_7d, usage)
                    if ts >= now - 18000:
                        add_tokens(tokens_5h, usage)
                if rate.get("primary"):
                    candidate = {"ts": ts, "rate": rate, "info": info}
                    if latest is None or ts > latest["ts"]:
                        latest = candidate
                if info.get("total_token_usage"):
                    session_latest = {"ts": ts, "usage": info["total_token_usage"], "model_context_window": info.get("model_context_window")}
        # Fallback display total for older sessions where last_token_usage is absent.
        if session_latest and session_latest["ts"] >= now - 604800 and tokens_7d["total"] == 0:
            add_tokens(tokens_7d, session_latest["usage"])
            if session_latest["ts"] >= now - 18000:
                add_tokens(tokens_5h, session_latest["usage"])
    except Exception:
        continue

if not latest:
    sys.exit(0)

primary = latest["rate"].get("primary") or {}
secondary = latest["rate"].get("secondary") or {}
latest_pct = primary.get("used_percent")
trend = {}
if latest_pct is not None and snapshots:
    snapshots.sort(key=lambda s: s["ts"])
    latest_ts = latest["ts"]
    for label, seconds in (("1h", 3600), ("24h", 86400), ("7d", 604800)):
        snap = snapshot_at_or_before(latest_ts - seconds)
        if snap is None:
            snap = snapshots[0]
        if snap is not None:
            trend[label] = {
                "delta": float(latest_pct) - float(snap["used_percent"]),
                "from_ts": snap["ts"],
            }
out = {
    "used_percent": latest_pct,
    "window_minutes": primary.get("window_minutes"),
    "resets_at": primary.get("resets_at"),
    "secondary_used_percent": secondary.get("used_percent") if isinstance(secondary, dict) else None,
    "secondary_resets_at": secondary.get("resets_at") if isinstance(secondary, dict) else None,
    "plan_type": latest["rate"].get("plan_type"),
    "limit_id": latest["rate"].get("limit_id"),
    "age_s": int(now - latest["ts"]),
    "trend": trend,
    "tokens_5h": tokens_5h,
    "tokens_7d": tokens_7d,
    "snapshot_count": len(snapshots),
}
print(json.dumps(out, separators=(",", ":")))
PYEOF
}

# ── Agent state ───────────────────────────────────────────────────────────────

# Exact-name match only (pgrep -x). The broad `pgrep -f "codex"` / "claude.*code"
# fallbacks this used to fall through to self-match: every command this script
# (and the harness wrapping it) runs gets shelled out through a snapshot-loader
# whose command line contains "claude"/"codex" literally, so the fallback
# always found a "process" — the bar never showed idle. The actual CLIs run as
# plain `claude` / `codex` binaries, so exact-name matching is both correct
# and immune to that self-match.
claude_is_running() {
    pgrep -x "claude" &>/dev/null
}

codex_is_running() {
    pgrep -x "codex" &>/dev/null
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

fmt_abs_reset() {
    local epoch="$1"
    [[ -z "$epoch" || "$epoch" == "null" ]] && { echo ""; return; }
    local now reset_s
    now=$(date +%s)
    reset_s=$(( epoch - now ))
    fmt_reset "$reset_s"
}

source_state() {
    local source="$1"
    local state="idle"
    local state_label="idle"

    case "$source" in
        claude)
            if claude_is_running; then
                state="ready"
                state_label="ready"
            fi
            if [[ -f "$CACHE_FILE" ]] && find "$CLAUDE_DIR" -name "*.jsonl" \
                    -newer "$CACHE_FILE" 2>/dev/null | grep -q .; then
                state="busy"
                state_label="busy"
            fi
            ;;
        codex)
            if codex_is_running; then
                state="ready"
                state_label="ready"
            fi
            if [[ -f "$CACHE_FILE" && -d "$CODEX_DIR" ]] && find "$CODEX_DIR" -name "*.jsonl" \
                    -newer "$CACHE_FILE" 2>/dev/null | grep -q .; then
                state="busy"
                state_label="busy"
            fi
            ;;
    esac

    printf '%s %s\n' "$state" "$state_label"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    local mode="${1:-summary}"

    if [[ "$mode" == "claude" ]]; then
        local nl=$'\n'

        # Look up the API-observed reset time FIRST — if Anthropic's 5h
        # window has already rolled over, we want to count tokens only since
        # that actual reset, not over a rolling "last 18000s" span (which
        # would double-count spend the meter has already forgotten about).
        local observed_5h observed_week observed_5h_age observed_week_age observed_5h_pct observed_week_pct observed_5h_reset observed_week_reset
        observed_5h=$(latest_observed_pct 5h 1200 || true)
        observed_week=$(latest_observed_pct week 1200 || true)
        [[ -n "$observed_5h" ]]   && read -r observed_5h_pct   observed_5h_age   observed_5h_reset   <<< "$observed_5h"
        [[ -n "$observed_week" ]] && read -r observed_week_pct observed_week_age observed_week_reset <<< "$observed_week"

        local five_h_cutoff=""
        if [[ -n "${observed_5h_reset:-}" ]]; then
            five_h_cutoff=$(( observed_5h_reset - 18000 ))
            # Window start is in the future until the API's snapshot catches
            # up with a fresh reset — fall back to the rolling guess then.
            (( five_h_cutoff > $(date +%s) )) && five_h_cutoff=""
        fi

        local five_h_data weekly_data
        five_h_data=$(count_tokens_since 18000 "$five_h_cutoff")
        weekly_data=$(count_tokens_since 604800)

        local five_h_in five_h_out reset_in_s weekly_in weekly_out
        read -r five_h_in five_h_out reset_in_s <<< "$five_h_data"
        read -r weekly_in weekly_out _          <<< "$weekly_data"

        local five_h_tok=$(( five_h_in + five_h_out ))
        local weekly_tok=$(( weekly_in + weekly_out ))
        local five_h_est weekly_est five_h_disp weekly_disp reset_fmt
        five_h_est=$(fmt_pct  "$five_h_tok" "$FIVE_H_LIMIT")
        weekly_est=$(fmt_pct  "$weekly_tok" "$WEEKLY_LIMIT")
        five_h_disp="$five_h_est"
        weekly_disp="$weekly_est"
        if [[ -n "${observed_5h_pct:-}" ]]; then
            five_h_disp="${observed_5h_pct}%"
        fi
        if [[ -n "${observed_week_pct:-}" ]]; then
            weekly_disp="${observed_week_pct}%"
        fi
        # Prefer Anthropic's own reset timestamp (from the API observation)
        # over the local guess — the local one is derived from the oldest
        # cached transcript and drifts once the real window has rolled over.
        if [[ -n "${observed_5h_reset:-}" ]]; then
            reset_fmt=$(fmt_abs_reset "$observed_5h_reset")
        else
            reset_fmt=$(fmt_reset  "$reset_in_s")
        fi

        local five_h_in_disp five_h_out_disp
        five_h_in_disp=$(fmt_tokens "$five_h_in")
        five_h_out_disp=$(fmt_tokens "$five_h_out")

        local claude_state claude_state_label
        read -r claude_state claude_state_label <<< "$(source_state claude)"

        local claude_mark
        case "$claude_state" in
            busy)  claude_mark="◉" ;;
            ready) claude_mark="▶" ;;
            *)     claude_mark="✱" ;;
        esac

        # Minimize to just the icon when no Claude harness is running — the
        # usage figures are only actionable while you're actively spending
        # against the quota; idle, they're just bar clutter. Full detail is
        # always one click away via the tooltip/popup regardless of state.
        local claude_text
        if [[ "$claude_state" == "idle" ]]; then
            claude_text="${claude_mark}"
        else
            claude_text="Claude ${claude_mark} ${five_h_disp}"
            (( weekly_tok > 0 )) && claude_text+=" / ${weekly_disp}wk"
        fi

        local tt1=$'════════════════════ Claude ═════════════════════'
        local tt2="Status    : ${claude_state_label}"
        tt2+="${nl}5h window : $(fmt_tokens "$five_h_tok") tokens (↓${five_h_in_disp} in / ↑${five_h_out_disp} out)"
        (( FIVE_H_LIMIT > 0 ))  && tt2+=" / $(fmt_tokens $FIVE_H_LIMIT) limit (est ${five_h_est})"
        if [[ -n "${observed_5h:-}" ]]; then
            local five_h_delta
            five_h_delta=$(python3 - "$observed_5h_pct" "${five_h_est%%%}" <<'PYEOF'
import sys
print(f"{float(sys.argv[1]) - float(sys.argv[2]):+.1f}pp")
PYEOF
            )
            tt2+=" / web ${five_h_disp} (${observed_5h_age}s old, Δ ${five_h_delta})"
        fi
        (( five_h_tok  > 0 )) && tt2+="  [resets in ${reset_fmt}]"

        local tt3="Week      : $(fmt_tokens "$weekly_tok") tokens (↓$(fmt_tokens "$weekly_in") in / ↑$(fmt_tokens "$weekly_out") out)"
        (( WEEKLY_LIMIT > 0 ))  && tt3+=" / $(fmt_tokens $WEEKLY_LIMIT) limit (est ${weekly_est})"
        if [[ -n "${observed_week:-}" ]]; then
            local weekly_delta
            weekly_delta=$(python3 - "$observed_week_pct" "${weekly_est%%%}" <<'PYEOF'
import sys
print(f"{float(sys.argv[1]) - float(sys.argv[2]):+.1f}pp")
PYEOF
            )
            tt3+=" / web ${weekly_disp} (${observed_week_age}s old, Δ ${weekly_delta})"
        fi

        RABBLE_TEXT="$claude_text" \
        RABBLE_TT1="$tt1" \
        RABBLE_TT2="$tt2" \
        RABBLE_TT3="$tt3" \
        RABBLE_CLASS="llm-${claude_state}" \
        python3 -c "
import json, os
parts = [os.environ[k] for k in ('RABBLE_TT1','RABBLE_TT2','RABBLE_TT3')]
print(json.dumps({
    'text':    os.environ['RABBLE_TEXT'],
    'tooltip': '\n'.join(parts),
    'class':   os.environ['RABBLE_CLASS'],
}, ensure_ascii=False))
"

        touch "$CACHE_FILE" 2>/dev/null || true
        return
    fi

    if [[ "$mode" == "codex" ]]; then
        local nl=$'\n'
        local codex_json codex_pct codex_reset codex_plan codex_5h_total codex_7d_total codex_age_s codex_trend codex_snapshot_count
        codex_json=$(codex_usage || true)
        if [[ -n "$codex_json" ]]; then
            read -r codex_pct codex_reset codex_plan codex_5h_total codex_7d_total <<< "$(
                RABBLE_CODEX_JSON="$codex_json" python3 - <<'PYEOF'
import json, os
data = json.loads(os.environ["RABBLE_CODEX_JSON"])
print(
    data.get("used_percent") if data.get("used_percent") is not None else "",
    data.get("resets_at") if data.get("resets_at") is not None else "",
    data.get("plan_type") or "",
    (data.get("tokens_5h") or {}).get("total", 0),
    (data.get("tokens_7d") or {}).get("total", 0),
)
PYEOF
            )"
            read -r codex_age_s codex_snapshot_count <<< "$(
                RABBLE_CODEX_JSON="$codex_json" python3 - <<'PYEOF'
import json, os
data = json.loads(os.environ["RABBLE_CODEX_JSON"])
print(
    data.get("age_s") if data.get("age_s") is not None else "",
    data.get("snapshot_count") if data.get("snapshot_count") is not None else "",
)
PYEOF
            )"
            codex_trend=$(RABBLE_CODEX_JSON="$codex_json" python3 - <<'PYEOF'
import json, os
data = json.loads(os.environ["RABBLE_CODEX_JSON"])
trend = data.get("trend") or {}
parts = []
for label in ("1h", "24h", "7d"):
    row = trend.get(label) or {}
    delta = row.get("delta")
    if delta is None:
        continue
    parts.append(f"{label} {delta:+.1f}pp")
print(" / ".join(parts))
PYEOF
            )
        fi

        local codex_state codex_state_label
        read -r codex_state codex_state_label <<< "$(source_state codex)"

        local codex_mark
        case "$codex_state" in
            busy)  codex_mark="◉" ;;
            ready) codex_mark="▶" ;;
            *)     codex_mark=">_" ;;
        esac

        # Minimize to just the icon when no Codex harness is running — same
        # reasoning as the Claude module: usage % only matters while you're
        # actively burning quota, idle it's just noise. Tooltip/popup still
        # carry full detail regardless of state.
        local codex_text
        if [[ "$codex_state" == "idle" ]]; then
            codex_text="${codex_mark}"
        else
            codex_text="Codex ${codex_mark}"
            if [[ -n "${codex_pct:-}" ]]; then
                codex_text+=" ${codex_pct}%"
            else
                codex_text+=" n/a"
            fi
        fi

        local tt1=$'════════════════════ Codex ══════════════════════'
        local tt2="Status    : ${codex_state_label}"
        tt2+="${nl}Plan      : ${codex_plan:-unknown}"
        if [[ -n "${codex_pct:-}" ]]; then
            local codex_reset_fmt codex_5h_fmt codex_7d_fmt
            codex_reset_fmt=$(fmt_abs_reset "$codex_reset")
            tt2+=" / ${codex_pct}% used"
            [[ -n "$codex_reset_fmt" ]] && tt2+=" [resets in ${codex_reset_fmt}]"
            tt2+="${nl}Recent    : ${codex_trend:-no trend yet}"
            [[ -n "$codex_age_s" ]] && tt2+="${nl}Snapshot  : ${codex_age_s}s old from ${codex_snapshot_count:-0} samples"
            codex_5h_fmt=$(fmt_tokens "$codex_5h_total")
            codex_7d_fmt=$(fmt_tokens "$codex_7d_total")
            tt2+="${nl}Local logs: ${codex_5h_fmt} 5h / ${codex_7d_fmt} 7d transcript volume"
        fi
        RABBLE_TEXT="$codex_text" \
        RABBLE_TT1="$tt1" \
        RABBLE_TT2="$tt2" \
        RABBLE_CLASS="llm-${codex_state}" \
        python3 -c "
import json, os
parts = [os.environ[k] for k in ('RABBLE_TT1','RABBLE_TT2')]
print(json.dumps({
    'text':    os.environ['RABBLE_TEXT'],
    'tooltip': '\n'.join(parts),
    'class':   os.environ['RABBLE_CLASS'],
}, ensure_ascii=False))
"

        touch "$CACHE_FILE" 2>/dev/null || true
        return
    fi

    # Look up the API-observed reset time FIRST so the 5h token count can be
    # scoped to the actual current window instead of a rolling 18000s span
    # (which would double-count spend from a window that's already reset).
    local observed_5h observed_week observed_5h_age observed_week_age observed_5h_pct observed_week_pct observed_5h_reset observed_week_reset
    observed_5h=$(latest_observed_pct 5h 1200 || true)
    observed_week=$(latest_observed_pct week 1200 || true)
    [[ -n "$observed_5h" ]]   && read -r observed_5h_pct   observed_5h_age   observed_5h_reset   <<< "$observed_5h"
    [[ -n "$observed_week" ]] && read -r observed_week_pct observed_week_age observed_week_reset <<< "$observed_week"

    local five_h_cutoff=""
    if [[ -n "${observed_5h_reset:-}" ]]; then
        five_h_cutoff=$(( observed_5h_reset - 18000 ))
        (( five_h_cutoff > $(date +%s) )) && five_h_cutoff=""
    fi

    local five_h_data weekly_data
    five_h_data=$(count_tokens_since 18000 "$five_h_cutoff")
    weekly_data=$(count_tokens_since 604800)

    local five_h_in five_h_out reset_in_s weekly_in weekly_out
    read -r five_h_in five_h_out reset_in_s <<< "$five_h_data"
    read -r weekly_in weekly_out _          <<< "$weekly_data"

    local five_h_tok=$(( five_h_in + five_h_out ))
    local weekly_tok=$(( weekly_in + weekly_out ))

    # Agent state
    local state="idle"
    local state_label="idle"
    if claude_is_running || codex_is_running; then
        state="ready"
        state_label="ready"
    fi
    if [[ -f "$CACHE_FILE" ]] && find "$CLAUDE_DIR" -name "*.jsonl" \
            -newer "$CACHE_FILE" 2>/dev/null | grep -q .; then
        state="busy"
        state_label="busy"
    fi
    if [[ -f "$CACHE_FILE" && -d "$CODEX_DIR" ]] && find "$CODEX_DIR" -name "*.jsonl" \
            -newer "$CACHE_FILE" 2>/dev/null | grep -q .; then
        state="busy"
        state_label="busy"
    fi

    # Bar text: state indicator + 5h usage + weekly usage
    local five_h_est weekly_est five_h_disp weekly_disp reset_fmt
    five_h_est=$(fmt_pct  "$five_h_tok" "$FIVE_H_LIMIT")
    weekly_est=$(fmt_pct  "$weekly_tok" "$WEEKLY_LIMIT")
    five_h_disp="$five_h_est"
    weekly_disp="$weekly_est"
    if [[ -n "${observed_5h_pct:-}" ]]; then
        five_h_disp="${observed_5h_pct}%"
    fi
    if [[ -n "${observed_week_pct:-}" ]]; then
        weekly_disp="${observed_week_pct}%"
    fi
    # Prefer Anthropic's own reset timestamp (from the API observation) over
    # the local guess, which drifts once the real window has rolled over.
    if [[ -n "${observed_5h_reset:-}" ]]; then
        reset_fmt=$(fmt_abs_reset "$observed_5h_reset")
    else
        reset_fmt=$(fmt_reset  "$reset_in_s")
    fi

    local codex_json codex_pct codex_reset codex_plan codex_5h_total codex_7d_total
    codex_json=$(codex_usage || true)
    if [[ -n "$codex_json" ]]; then
        read -r codex_pct codex_reset codex_plan codex_5h_total codex_7d_total <<< "$(
            RABBLE_CODEX_JSON="$codex_json" python3 - <<'PYEOF'
import json, os
data = json.loads(os.environ["RABBLE_CODEX_JSON"])
print(
    data.get("used_percent") if data.get("used_percent") is not None else "",
    data.get("resets_at") if data.get("resets_at") is not None else "",
    data.get("plan_type") or "",
    (data.get("tokens_5h") or {}).get("total", 0),
    (data.get("tokens_7d") or {}).get("total", 0),
)
PYEOF
        )"
    fi

    # State markers using standard Unicode (no Nerd Font required)
    local state_mark
    case "$state" in
        busy)  state_mark="◉" ;;
        ready) state_mark="▶" ;;
        *)     state_mark="·" ;;
    esac

    local five_h_in_disp five_h_out_disp
    five_h_in_disp=$(fmt_tokens "$five_h_in")
    five_h_out_disp=$(fmt_tokens "$five_h_out")

    local text="Claude ${state_mark} ${five_h_disp}"
    (( weekly_tok > 0 )) && text+=" / ${weekly_disp}wk"
    if [[ -n "${codex_pct:-}" ]]; then
        text+=" | Codex ${codex_pct}%"
    fi

    # Tooltip
    local five_h_raw weekly_raw weekly_in_disp weekly_out_disp
    five_h_raw=$(fmt_tokens "$five_h_tok")
    weekly_raw=$(fmt_tokens "$weekly_tok")
    weekly_in_disp=$(fmt_tokens "$weekly_in")
    weekly_out_disp=$(fmt_tokens "$weekly_out")

    local tt1="sCoRE Usage Tracker — ${state_label}"

    local tt2="5h window : ${five_h_raw} tokens (↓${five_h_in_disp} in / ↑${five_h_out_disp} out)"
    (( FIVE_H_LIMIT > 0 ))  && tt2+=" / $(fmt_tokens $FIVE_H_LIMIT) limit (est ${five_h_est})"
    if [[ -n "${observed_5h:-}" ]]; then
        local five_h_delta
        five_h_delta=$(python3 - "$observed_5h_pct" "${five_h_est%%%}" <<'PYEOF'
import sys
print(f"{float(sys.argv[1]) - float(sys.argv[2]):+.1f}pp")
PYEOF
        )
        tt2+=" / web ${five_h_disp} (${observed_5h_age}s old, Δ ${five_h_delta})"
    fi
    (( five_h_tok  > 0 ))   && tt2+="  [resets in ${reset_fmt}]"

    local tt3="Week      : ${weekly_raw} tokens (↓${weekly_in_disp} in / ↑${weekly_out_disp} out)"
    (( WEEKLY_LIMIT > 0 ))  && tt3+=" / $(fmt_tokens $WEEKLY_LIMIT) limit (est ${weekly_est})"
    if [[ -n "${observed_week:-}" ]]; then
        local weekly_delta
        weekly_delta=$(python3 - "$observed_week_pct" "${weekly_est%%%}" <<'PYEOF'
import sys
print(f"{float(sys.argv[1]) - float(sys.argv[2]):+.1f}pp")
PYEOF
        )
        tt3+=" / web ${weekly_disp} (${observed_week_age}s old, Δ ${weekly_delta})"
    fi

    local tt4=""
    if [[ -n "${codex_pct:-}" ]]; then
        local codex_reset_fmt codex_5h_fmt codex_7d_fmt
        codex_reset_fmt=$(fmt_abs_reset "$codex_reset")
        codex_5h_fmt=$(fmt_tokens "$codex_5h_total")
        codex_7d_fmt=$(fmt_tokens "$codex_7d_total")
        tt4="Codex    : ${codex_pct}%"
        [[ -n "$codex_plan" ]] && tt4+=" (${codex_plan})"
        [[ -n "$codex_reset_fmt" ]] && tt4+=" [resets in ${codex_reset_fmt}]"
        tt4+=" — ${codex_5h_fmt} 5h / ${codex_7d_fmt} 7d local tokens"
    fi

    local other=""
    pgrep -x "gemini" &>/dev/null && other+=" gemini"
    local tt5="${other:+Also running:${other}}"

    local css_class="llm-${state}"

    RABBLE_TEXT="$text" \
    RABBLE_TT1="$tt1" \
    RABBLE_TT2="$tt2" \
    RABBLE_TT3="$tt3" \
    RABBLE_TT4="$tt4" \
    RABBLE_TT5="$tt5" \
    RABBLE_CLASS="$css_class" \
    python3 -c "
import json, os
parts = [os.environ[k] for k in ('RABBLE_TT1','RABBLE_TT2','RABBLE_TT3')]
tt4 = os.environ['RABBLE_TT4']
if tt4: parts.append(tt4)
tt5 = os.environ['RABBLE_TT5']
if tt5: parts.append(tt5)
print(json.dumps({
    'text':    os.environ['RABBLE_TEXT'],
    'tooltip': '\n'.join(parts),
    'class':   os.environ['RABBLE_CLASS'],
}, ensure_ascii=False))
"

    touch "$CACHE_FILE" 2>/dev/null || true
}

main "$@"
