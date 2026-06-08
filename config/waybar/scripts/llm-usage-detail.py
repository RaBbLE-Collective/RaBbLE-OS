#!/usr/bin/env python3
"""
llm-usage-detail.py — Full Claude/Codex usage breakdown.
Opened by clicking the waybar llm-status module.
Shows per-session token counts for the current 5h window and the past 7 days.
"""

import json
import pathlib
import time
import datetime
import os
import sys

CLAUDE_DIR = pathlib.Path.home() / ".claude" / "projects"
CODEX_DIR = pathlib.Path.home() / ".codex" / "sessions"
LATEST_OBS = pathlib.Path.home() / ".cache" / "rabble" / "llm-usage-latest.json"

# Strip ANSI when piped, unless FORCE_COLOR is set (e.g. piped into less -R)
_tty = sys.stdout.isatty() or bool(os.environ.get("FORCE_COLOR"))
CYAN    = "\033[38;2;0;245;255m"    if _tty else ""
VIOLET  = "\033[38;2;191;95;255m"   if _tty else ""
GREEN   = "\033[38;2;80;250;123m"   if _tty else ""
YELLOW  = "\033[38;2;241;250;140m"  if _tty else ""
MUTED   = "\033[38;2;107;64;128m"   if _tty else ""
TEXT    = "\033[38;2;232;213;255m"  if _tty else ""
MAGENTA = "\033[38;2;255;45;120m"   if _tty else ""
RESET   = "\033[0m"                  if _tty else ""


def fmt_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n/1_000_000:.2f}M"
    if n >= 1_000:
        return f"{n/1_000:.1f}K"
    return str(n)


def fmt_ts(ts: float) -> str:
    return datetime.datetime.fromtimestamp(ts).strftime("%a %H:%M")


def fmt_age(seconds: float) -> str:
    seconds = max(0, int(seconds))
    h, rem = divmod(seconds, 3600)
    m = rem // 60
    if h:
        return f"{h}h {m:02d}m ago"
    if m:
        return f"{m}m ago"
    return f"{seconds}s ago"


def parse_any_ts(row: dict, fallback: float) -> float:
    raw = row.get("timestamp") or row.get("ts")
    if isinstance(raw, (int, float)):
        return float(raw)
    if raw:
        try:
            return datetime.datetime.fromisoformat(str(raw).replace("Z", "+00:00")).timestamp()
        except Exception:
            pass
    return fallback


def parse_sessions(since_s: float) -> list[dict]:
    """Return list of {path, first_ts, last_ts, input, output} for each session."""
    sessions = []
    if not CLAUDE_DIR.exists():
        return sessions

    for jl in CLAUDE_DIR.rglob("*.jsonl"):
        try:
            mtime = jl.stat().st_mtime
            if mtime < since_s - 60:
                continue

            first_ts = mtime
            last_ts  = mtime
            total_in = 0
            total_out = 0
            has_data  = False

            with open(jl) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        entry = json.loads(line)
                    except json.JSONDecodeError:
                        continue

                    ts = parse_any_ts(entry, mtime)

                    if ts < since_s:
                        continue

                    msg   = entry.get("message", {})
                    usage = msg.get("usage") or entry.get("usage") or {}
                    inp   = usage.get("input_tokens", 0)
                    out   = usage.get("output_tokens", 0)

                    if inp or out:
                        total_in  += inp
                        total_out += out
                        has_data   = True
                        if ts < first_ts:
                            first_ts = ts
                        if ts > last_ts:
                            last_ts = ts

            if has_data:
                proj_name = jl.parent.name
                sessions.append({
                    "path":     str(jl),
                    "project":  proj_name.replace("-", "/").lstrip("/"),
                    "first_ts": first_ts,
                    "last_ts":  last_ts,
                    "input":    total_in,
                    "output":   total_out,
                    "total":    total_in + total_out,
                })
        except Exception:
            continue

    sessions.sort(key=lambda s: s["last_ts"], reverse=True)
    return sessions


def latest_web_observations(now: float) -> dict:
    if not LATEST_OBS.exists():
        return {}
    try:
        data = json.loads(LATEST_OBS.read_text())
    except (OSError, json.JSONDecodeError):
        return {}

    out = {}
    for label, max_age in (("5h", 18_000), ("week", 604_800)):
        row = data.get(label) or {}
        try:
            ts = float(row["ts"])
            pct = float(row["pct"])
        except (KeyError, TypeError, ValueError):
            continue
        if now - ts <= max_age:
            out[label] = {"pct": pct, "age": now - ts, "web_used": bool(row.get("web_used"))}
    return out


def parse_codex(now: float) -> dict | None:
    if not CODEX_DIR.exists():
        return None

    latest = None
    buckets = {
        "5h": {"input": 0, "cached": 0, "output": 0, "reasoning": 0, "total": 0},
        "7d": {"input": 0, "cached": 0, "output": 0, "reasoning": 0, "total": 0},
    }

    def add_tokens(bucket: dict, usage: dict):
        bucket["input"] += int(usage.get("input_tokens", 0) or 0)
        bucket["cached"] += int(usage.get("cached_input_tokens", 0) or 0)
        bucket["output"] += int(usage.get("output_tokens", 0) or 0)
        bucket["reasoning"] += int(usage.get("reasoning_output_tokens", 0) or 0)
        bucket["total"] += int(usage.get("total_tokens", 0) or 0)

    for jl in CODEX_DIR.rglob("*.jsonl"):
        try:
            mtime = jl.stat().st_mtime
            if mtime < now - 604_800 - 3600:
                continue
            with open(jl) as f:
                for line in f:
                    try:
                        row = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    payload = row.get("payload") or {}
                    if payload.get("type") != "token_count":
                        continue
                    ts = parse_any_ts(row, mtime)
                    info = payload.get("info") or {}
                    usage = info.get("last_token_usage") or {}
                    if usage:
                        if ts >= now - 604_800:
                            add_tokens(buckets["7d"], usage)
                        if ts >= now - 18_000:
                            add_tokens(buckets["5h"], usage)
                    rate = payload.get("rate_limits") or {}
                    if rate.get("primary") and (latest is None or ts > latest["ts"]):
                        latest = {"ts": ts, "rate": rate}
        except Exception:
            continue

    if not latest:
        return None
    return {"latest": latest, "tokens": buckets}


def window_reset(sessions: list[dict], window_s: float, now: float) -> str:
    if not sessions:
        return "—"
    oldest = min(s["first_ts"] for s in sessions)
    resets_at = oldest + window_s
    left = int(resets_at - now)
    if left <= 0:
        return "now"
    h, m = divmod(left, 3600)
    m = m // 60
    return f"{h}h {m:02d}m" if h else f"{m}m"


def print_section(title: str, sessions: list[dict], window_s: float, now: float):
    total = sum(s["total"] for s in sessions)
    reset = window_reset(sessions, window_s, now)

    print(f"\n{VIOLET}{'─'*60}{RESET}")
    print(f"{VIOLET}{title}{RESET}  {TEXT}{fmt_tokens(total)} tokens{RESET}", end="")
    if sessions and window_s < 86400 * 2:
        print(f"  {MUTED}(window resets in {reset}){RESET}", end="")
    print()
    print(f"{VIOLET}{'─'*60}{RESET}")

    if not sessions:
        print(f"  {MUTED}no activity{RESET}")
        return

    for s in sessions:
        label = s["project"][:40]
        age   = fmt_ts(s["last_ts"])
        tok   = fmt_tokens(s["total"])
        inp   = fmt_tokens(s["input"])
        out   = fmt_tokens(s["output"])
        print(f"  {CYAN}{age}{RESET}  {TEXT}{tok:>7}{RESET}  {MUTED}↓{inp} ↑{out}{RESET}  {MUTED}{label}{RESET}")


def print_web_observations(now: float):
    observations = latest_web_observations(now)
    if not observations:
        return

    print(f"\n{VIOLET}{'─'*60}{RESET}")
    print(f"{VIOLET}Claude web readings{RESET}")
    print(f"{VIOLET}{'─'*60}{RESET}")
    for label in ("5h", "week"):
        row = observations.get(label)
        if not row:
            continue
        source = "mixed web+code sample" if row["web_used"] else "clean code-only sample"
        print(f"  {CYAN}{label:<5}{RESET} {TEXT}{row['pct']:>5.1f}%{RESET}  {MUTED}{fmt_age(row['age'])} · {source}{RESET}")


def print_separator(title: str):
    label = f" {title} "
    width = 60
    side = max(4, (width - len(title) - 2) // 2)
    line = f"{'═' * side}{label}{'═' * (width - side - len(label))}"
    print(f"\n{VIOLET}{line}{RESET}")


def print_codex(now: float):
    codex = parse_codex(now)
    if not codex:
        return

    rate = codex["latest"]["rate"]
    primary = rate.get("primary") or {}
    pct = primary.get("used_percent")
    reset = primary.get("resets_at")
    reset_text = ""
    if reset:
        left = int(float(reset) - now)
        reset_text = "now" if left <= 0 else f"{left // 3600}h {(left % 3600) // 60:02d}m"

    print(f"\n{VIOLET}{'─'*60}{RESET}")
    print(f"{VIOLET}Codex quota{RESET}", end="")
    if pct is not None:
        print(f"  {TEXT}{pct}% used{RESET}", end="")
    if reset_text:
        print(f"  {MUTED}(resets in {reset_text}){RESET}", end="")
    print()
    print(f"{VIOLET}{'─'*60}{RESET}")
    plan = rate.get("plan_type")
    if plan:
        print(f"  {MUTED}plan: {plan}{RESET}")
    for label in ("5h", "7d"):
        bucket = codex["tokens"][label]
        print(
            f"  {CYAN}{label:<5}{RESET} {TEXT}{fmt_tokens(bucket['total']):>7}{RESET}  "
            f"{MUTED}↓{fmt_tokens(bucket['input'])} cached {fmt_tokens(bucket['cached'])} "
            f"↑{fmt_tokens(bucket['output'])} reason {fmt_tokens(bucket['reasoning'])}{RESET}"
        )


def main():
    mode = (sys.argv[1] if len(sys.argv) > 1 else "claude").strip().lower()
    now = time.time()
    five_h  = now - 18_000
    one_day = now - 86_400
    seven_d = now - 604_800

    print(f"\n{MAGENTA}  RaBbLE — LLM Usage{RESET}  {MUTED}{datetime.datetime.now().strftime('%Y-%m-%d %H:%M')}{RESET}  {CYAN}q to close{RESET}")

    sessions_5h  = parse_sessions(five_h)
    sessions_24h = parse_sessions(one_day)
    sessions_7d  = parse_sessions(seven_d)

    if mode == "codex":
        print_separator("Codex")
        print_codex(now)
        print_separator("Claude Code")
        print_web_observations(now)
        print_section("5-hour window", sessions_5h,  18_000,   now)
        print_section("Last 24 hours", sessions_24h, 86_400,   now)
        print_section("Last 7 days",   sessions_7d,  604_800,  now)
    else:
        print_separator("Claude Code")
        print_web_observations(now)
        print_section("5-hour window", sessions_5h,  18_000,   now)
        print_section("Last 24 hours", sessions_24h, 86_400,   now)
        print_section("Last 7 days",   sessions_7d,  604_800,  now)
        print_separator("Codex")
        print_codex(now)

    total_week = sum(s["total"] for s in sessions_7d)
    print(f"\n{MUTED}  Weekly total: {fmt_tokens(total_week)} tokens across {len(sessions_7d)} session(s){RESET}\n")


if __name__ == "__main__":
    main()
