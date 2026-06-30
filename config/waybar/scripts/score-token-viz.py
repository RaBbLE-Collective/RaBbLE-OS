#!/usr/bin/env python3
"""score-token-viz.py — breadcrumbs → visualization data file.

Joins three breadcrumb sources into one structured, chartable JSON:

  1. ~/.claude/projects/**/*.jsonl   — raw transcripts: per-message token usage
                                        + model, parsed per session AND per model
  2. RaBbLE-Grimoire/log/token-ledger.tsv — session_id → feature → note tags
  3. score-pricing.json (via score_pricing) — per-model list-price API rates

Output: per-session, per-feature, per-model, per-project rollups with tokens
split DOWN (input) / UP (output) / cache, the model-agnostic weighted cost
(matches spells/session-tokens.sh), and a list-price API dollar estimate.

Unlike spells/session-tokens.sh (which the ledger join was built for), this
also breaks every total down BY MODEL, so the dollar figure reflects the real
Haiku/Sonnet/Opus mix instead of one flat input rate.

Usage:
  score-token-viz.py                      # write <grimoire>/log/token-viz.json + summary
  score-token-viz.py --since 7            # only sessions active in last 7 days
  score-token-viz.py --out /tmp/viz.json  # custom output path
  score-token-viz.py --stdout             # print JSON to stdout instead of writing
  score-token-viz.py --quiet              # no summary table
"""

import argparse
import datetime
import json
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
try:
    import score_pricing
except Exception:
    score_pricing = None

CLAUDE_DIR = pathlib.Path.home() / ".claude" / "projects"

# Weighted (input-equivalent) cost weights — kept in lockstep with
# spells/session-tokens.sh so the two tools report the same weighted number.
W_OUTPUT = 5.0
W_CACHE_READ = 0.1
W_CACHE_WRITE = 1.25


# ── helpers ──────────────────────────────────────────────────────────────────


def short_model(m: str) -> str:
    return m.replace("claude-", "").replace("-20251001", "")


def dir_to_project(dirname: str) -> str:
    """Mirror of session-tokens.sh dir_to_project so project slugs match."""
    if dirname.endswith("-RaBbLE-Collective"):
        return "RaBbLE-Collective"
    if dirname.endswith("-Jobotron3000"):
        return "Jobotron3000"
    if "-RaBbLE-RaBbLE-" in dirname:
        return "RaBbLE-" + dirname.split("-RaBbLE-RaBbLE-", 1)[1]
    if "-RaBbLE-" in dirname:
        return "RaBbLE-" + dirname.split("-RaBbLE-", 1)[1]
    return dirname.replace("-home-rabble-", "")


def parse_ts(row: dict, fallback: float) -> float:
    raw = row.get("timestamp") or row.get("ts")
    if isinstance(raw, (int, float)):
        return float(raw)
    if raw:
        try:
            return datetime.datetime.fromisoformat(
                str(raw).replace("Z", "+00:00")).timestamp()
        except Exception:
            pass
    return fallback


def find_grimoire_log() -> pathlib.Path | None:
    """Walk up from the script dir and CWD looking for the Grimoire log dir."""
    starts = [pathlib.Path(__file__).resolve(), pathlib.Path.cwd().resolve()]
    seen = set()
    for start in starts:
        for d in [start, *start.parents]:
            if d in seen:
                continue
            seen.add(d)
            cand = d / "RaBbLE-Grimoire" / "log" / "token-ledger.tsv"
            if cand.exists():
                return cand.parent
    return None


def load_ledger(path: pathlib.Path | None) -> dict:
    """session_id -> (feature, note). Commit-tagged rows (commit-XXX) are kept
    too; they just won't match a transcript session and are harmless."""
    table = {}
    if not path or not path.exists():
        return table
    for line in path.read_text().splitlines():
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        sid = parts[0].strip()
        feat = parts[1].strip() if len(parts) > 1 else ""
        note = parts[2].strip() if len(parts) > 2 else ""
        if sid:
            table[sid] = (feat or "(untagged)", note)
    return table


# ── core ───────────────────────────────────────────────────────────────────


def weighted_cost(t: dict) -> float:
    return (t["down"] + t["up"] * W_OUTPUT
            + t["cache_read"] * W_CACHE_READ + t["cache_write"] * W_CACHE_WRITE)


def new_bucket() -> dict:
    return {"down": 0, "up": 0, "cache_read": 0, "cache_write": 0}


def parse_session(jl: pathlib.Path, since_ts: float):
    """Return (session_record | None). Sums all usage records (no dedup), to
    stay consistent with session-tokens.sh."""
    mtime = jl.stat().st_mtime
    if mtime < since_ts - 60:
        return None

    first_ts = last_ts = mtime
    messages = 0
    per_model: dict[str, dict] = {}
    totals = new_bucket()
    has_data = False

    try:
        with open(jl) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                msg = entry.get("message", {})
                usage = msg.get("usage") or entry.get("usage") or {}
                inp = usage.get("input_tokens", 0)
                out = usage.get("output_tokens", 0)
                cr = usage.get("cache_read_input_tokens", 0)
                cc = usage.get("cache_creation_input_tokens", 0)
                if not (inp or out or cr or cc):
                    continue
                ts = parse_ts(entry, mtime)
                if ts < since_ts:
                    continue
                messages += 1
                first_ts = min(first_ts, ts)
                last_ts = max(last_ts, ts)
                totals["down"] += inp
                totals["up"] += out
                totals["cache_read"] += cr
                totals["cache_write"] += cc
                has_data = True
                model = short_model(msg.get("model") or entry.get("model") or "")
                if model and model != "<synthetic>":
                    b = per_model.setdefault(model, new_bucket())
                    b["down"] += inp
                    b["up"] += out
                    b["cache_read"] += cr
                    b["cache_write"] += cc
    except OSError:
        return None

    if not has_data:
        return None

    return {
        "session": jl.stem,
        "project": dir_to_project(jl.parent.name),
        "first_ts": first_ts,
        "last_ts": last_ts,
        "date": datetime.datetime.fromtimestamp(last_ts).strftime("%Y-%m-%d %H:%M"),
        "messages": messages,
        "totals": totals,
        "per_model": per_model,
    }


def price_bucket(model: str, b: dict, pricing) -> float:
    if score_pricing is None:
        return 0.0
    return score_pricing.cost(
        model, inp=b["down"], out=b["up"],
        cache_read=b["cache_read"], cache_write=b["cache_write"], pricing=pricing)


def add_into(dst: dict, src: dict):
    for k in ("down", "up", "cache_read", "cache_write"):
        dst[k] += src[k]


def build(since_ts: float, ledger: dict) -> dict:
    pricing = score_pricing.load() if score_pricing else None
    sessions = []
    if CLAUDE_DIR.exists():
        for jl in CLAUDE_DIR.rglob("*.jsonl"):
            rec = parse_session(jl, since_ts)
            if rec:
                sessions.append(rec)
    sessions.sort(key=lambda s: s["last_ts"], reverse=True)

    by_feature: dict[str, dict] = {}
    by_model: dict[str, dict] = {}
    by_project: dict[str, dict] = {}
    grand = new_bucket()
    grand_usd = 0.0
    grand_weighted = 0.0

    out_sessions = []
    for s in sessions:
        feat, note = ledger.get(s["session"], ("(untagged)", ""))
        sess_usd = 0.0
        model_out = {}
        for m, b in s["per_model"].items():
            usd = price_bucket(m, b, pricing)
            sess_usd += usd
            model_out[m] = {**b, "usd": round(usd, 4)}
            # global by_model rollup
            bm = by_model.setdefault(m, {**new_bucket(), "usd": 0.0, "sessions": 0})
            add_into(bm, b)
            bm["usd"] += usd
            bm["sessions"] += 1
        wcost = weighted_cost(s["totals"])

        out_sessions.append({
            "session": s["session"],
            "feature": feat,
            "note": note,
            "project": s["project"],
            "date": s["date"],
            "first_ts": int(s["first_ts"]),
            "last_ts": int(s["last_ts"]),
            "messages": s["messages"],
            **s["totals"],
            "weighted": int(wcost),
            "usd": round(sess_usd, 4),
            "models": model_out,
        })

        # feature rollup
        fr = by_feature.setdefault(feat, {
            **new_bucket(), "sessions": 0, "weighted": 0, "usd": 0.0,
            "models": {}, "notes": []})
        add_into(fr, s["totals"])
        fr["sessions"] += 1
        fr["weighted"] += int(wcost)
        fr["usd"] += sess_usd
        for m, b in s["per_model"].items():
            fm = fr["models"].setdefault(m, new_bucket())
            add_into(fm, b)
        if note and note not in fr["notes"]:
            fr["notes"].append(note)

        # project rollup
        pr = by_project.setdefault(s["project"], {
            **new_bucket(), "sessions": 0, "weighted": 0, "usd": 0.0})
        add_into(pr, s["totals"])
        pr["sessions"] += 1
        pr["weighted"] += int(wcost)
        pr["usd"] += sess_usd

        add_into(grand, s["totals"])
        grand_usd += sess_usd
        grand_weighted += wcost

    # round/sort rollups for output
    def finalize(d, sort_key="usd"):
        for v in d.values():
            v["usd"] = round(v["usd"], 2)
        return dict(sorted(d.items(), key=lambda kv: -kv[1][sort_key]))

    for v in by_model.values():
        v["usd"] = round(v["usd"], 2)

    return {
        "generated": datetime.datetime.now().isoformat(timespec="seconds"),
        "pricing_updated": (pricing or {}).get("updated", "n/a") if pricing else "no-pricing",
        "weighting": {"output_x": W_OUTPUT, "cache_read_x": W_CACHE_READ,
                      "cache_write_x": W_CACHE_WRITE},
        "totals": {
            "sessions": len(out_sessions),
            **grand,
            "weighted": int(grand_weighted),
            "usd": round(grand_usd, 2),
        },
        "by_model": dict(sorted(by_model.items(), key=lambda kv: -kv[1]["usd"])),
        "by_feature": finalize(by_feature),
        "by_project": finalize(by_project),
        "sessions": out_sessions,
    }


# ── output ───────────────────────────────────────────────────────────────────


def fmt_tok(n: int) -> str:
    if n >= 1_000_000:
        return f"{n/1_000_000:.2f}M"
    if n >= 1_000:
        return f"{n/1_000:.1f}K"
    return str(int(n))


def print_summary(data: dict, out_path: pathlib.Path | None):
    t = data["totals"]
    print(f"\n  sCoRE Token Viz — {data['generated']}  "
          f"(pricing {data['pricing_updated']})")
    print(f"  {'─'*64}")
    print(f"  {t['sessions']} sessions · ↓{fmt_tok(t['down'])} down "
          f"↑{fmt_tok(t['up'])} up · cache r{fmt_tok(t['cache_read'])}/"
          f"w{fmt_tok(t['cache_write'])} · ≈${t['usd']:,.2f} API")
    print(f"\n  By model:")
    for m, b in data["by_model"].items():
        print(f"    {m:<14} ↓{fmt_tok(b['down']):>8} ↑{fmt_tok(b['up']):>8}  "
              f"≈${b['usd']:>10,.2f}  ({b['sessions']} sess)")
    print(f"\n  Top features by API cost:")
    for feat, b in list(data["by_feature"].items())[:12]:
        print(f"    {feat:<28} {b['sessions']:>3} sess  ≈${b['usd']:>10,.2f}")
    if out_path:
        print(f"\n  → wrote {out_path}")
    print()


def main():
    ap = argparse.ArgumentParser(description="breadcrumbs → token visualization data")
    ap.add_argument("--since", type=float, default=0,
                    help="only sessions active in the last N days (0 = all)")
    ap.add_argument("--ledger", type=str, default="",
                    help="path to token-ledger.tsv (default: auto-discover)")
    ap.add_argument("--out", type=str, default="",
                    help="output JSON path (default: <grimoire>/log/token-viz.json)")
    ap.add_argument("--stdout", action="store_true", help="print JSON to stdout")
    ap.add_argument("--quiet", action="store_true", help="suppress summary table")
    args = ap.parse_args()

    since_ts = (time.time() - args.since * 86_400) if args.since else 0

    ledger_path = pathlib.Path(args.ledger) if args.ledger else None
    grim_log = None
    if ledger_path is None:
        grim_log = find_grimoire_log()
        if grim_log:
            ledger_path = grim_log / "token-ledger.tsv"
    elif ledger_path.exists():
        grim_log = ledger_path.parent

    ledger = load_ledger(ledger_path)
    data = build(since_ts, ledger)

    if args.stdout:
        print(json.dumps(data, indent=2))
        return

    if args.out:
        out_path = pathlib.Path(args.out)
    elif grim_log:
        out_path = grim_log / "token-viz.json"
    else:
        out_path = pathlib.Path.cwd() / "token-viz.json"

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(data, indent=2))

    if not args.quiet:
        print_summary(data, out_path)


if __name__ == "__main__":
    main()
