#!/usr/bin/env bash
# llm-usage-log.sh — Record a usage-meter observation for regression fitting.
#
# Anthropic's real usage accounting weighs token types and models differently
# (output > input, cache reads cheaper, Opus/Sonnet/Haiku multipliers). To tune
# our local estimate toward reality, we log paired samples of
# (per-model token breakdown, observed % from the Claude web usage meter)
# and fit a regression over them with llm-usage-fit.py.
#
# Usage:
#   llm-usage-log.sh 5h   <observed_pct>     # e.g. llm-usage-log.sh 5h 50
#   llm-usage-log.sh week <observed_pct>     # e.g. llm-usage-log.sh week 19
#
# Read the % directly off the Claude web usage meter at the moment you run this
# — the closer in time to that reading, the better the sample.

set -euo pipefail

CLAUDE_DIR="$HOME/.claude/projects"
LOG_DIR="$HOME/.cache/rabble"
LOG_FILE="$LOG_DIR/llm-usage-log.jsonl"
LATEST_FILE="$LOG_DIR/llm-usage-latest.json"
mkdir -p "$LOG_DIR"

usage() {
    cat >&2 <<'EOF'
usage: llm-usage-log.sh <5h|week> <observed_pct> [--web]

  --web   Mark this sample as "contaminated": claude.ai web chat was used
          within this window too. Web usage draws on the same pool but
          leaves no token trace in local transcripts — without this flag
          the regression would wrongly attribute web-driven % moves to the
          CC tokens it CAN see, skewing every coefficient.

          Clean (no --web) samples train the fit. --web samples are scored
          against that fit afterward to *estimate* the web-only contribution
          (observed % minus what CC tokens alone would predict) — see
          llm-usage-fit.py.
EOF
    exit 1
}

[[ $# -ge 2 && $# -le 3 ]] || usage
window_label="$1"
observed_pct="$2"
web_used="false"
if [[ $# -eq 3 ]]; then
    [[ "$3" == "--web" ]] || usage
    web_used="true"
fi

case "$window_label" in
    5h)   window_s=18000  ;;
    week) window_s=604800 ;;
    *)    usage ;;
esac

[[ "$observed_pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] || usage

python3 - "$CLAUDE_DIR" "$window_s" "$window_label" "$observed_pct" "$LOG_FILE" "$LATEST_FILE" "$web_used" <<'PYEOF'
import sys, json, time, pathlib, datetime
from collections import defaultdict

proj_dir, window_s, window_label, observed_pct, log_file, latest_file, web_used = (
    sys.argv[1], int(sys.argv[2]), sys.argv[3], float(sys.argv[4]), sys.argv[5], sys.argv[6], sys.argv[7] == "true"
)
now = time.time()
cutoff = now - window_s

models = defaultdict(lambda: defaultdict(int))

for jl in pathlib.Path(proj_dir).rglob("*.jsonl"):
    try:
        if jl.stat().st_mtime < cutoff - 60:
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
                if ts < cutoff:
                    continue

                msg = entry.get("message", {})
                usage = msg.get("usage") or entry.get("usage") or {}
                if not usage:
                    continue

                model = msg.get("model", "unknown")
                m = models[model]
                m["input"]          += usage.get("input_tokens", 0)
                m["cache_creation"] += usage.get("cache_creation_input_tokens", 0)
                m["cache_read"]     += usage.get("cache_read_input_tokens", 0)
                m["output"]         += usage.get("output_tokens", 0)
    except Exception:
        continue

# Drop empty/synthetic entries
models = {m: dict(v) for m, v in models.items() if any(v.values())}

row = {
    "ts":       now,
    "date":     datetime.datetime.now().isoformat(timespec="seconds"),
    "window":   window_label,
    "pct":      observed_pct,
    "web_used": web_used,
    "models":   models,
}

with open(log_file, "a") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")

latest = {}
latest_path = pathlib.Path(latest_file)
if latest_path.exists():
    try:
        latest = json.loads(latest_path.read_text())
    except (OSError, json.JSONDecodeError):
        latest = {}
latest[window_label] = {
    "ts": now,
    "date": row["date"],
    "pct": observed_pct,
    "web_used": web_used,
    "local_tokens": {
        "total": sum(sum(v.values()) for v in models.values()),
        "models": models,
    },
}
latest_path.write_text(json.dumps(latest, ensure_ascii=False, indent=2) + "\n")

tag = " [MIXED — web also used]" if web_used else " [clean — CC only]"
print(f"Logged {window_label} observation: {observed_pct}%{tag} — "
      f"{', '.join(f'{m}: {sum(v.values())} tok' for m, v in models.items()) or 'no activity'}")
PYEOF
