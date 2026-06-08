#!/usr/bin/env python3
"""
llm-usage-detail.py — Full Claude Code usage breakdown.
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

                    ts_raw = entry.get("timestamp") or entry.get("ts") or ""
                    ts = mtime
                    if ts_raw:
                        try:
                            ts = datetime.datetime.fromisoformat(
                                ts_raw.replace("Z", "+00:00")
                            ).timestamp()
                        except Exception:
                            pass

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


def main():
    now = time.time()
    five_h  = now - 18_000
    one_day = now - 86_400
    seven_d = now - 604_800

    print(f"\n{MAGENTA}  RaBbLE — Claude Code Usage{RESET}")
    print(f"{MUTED}  {datetime.datetime.now().strftime('%Y-%m-%d %H:%M')}{RESET}")

    sessions_5h  = parse_sessions(five_h)
    sessions_24h = parse_sessions(one_day)
    sessions_7d  = parse_sessions(seven_d)

    print_section("5-hour window", sessions_5h,  18_000,   now)
    print_section("Last 24 hours", sessions_24h, 86_400,   now)
    print_section("Last 7 days",   sessions_7d,  604_800,  now)

    total_week = sum(s["total"] for s in sessions_7d)
    print(f"\n{MUTED}  Weekly total: {fmt_tokens(total_week)} tokens across {len(sessions_7d)} session(s){RESET}\n")


if __name__ == "__main__":
    main()
