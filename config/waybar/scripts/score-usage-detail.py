#!/usr/bin/env python3
"""
score-usage-detail.py — Full Claude/Codex usage + agent breakdown.
Opened by clicking the waybar llm-status module.

Default (one-shot) mode prints everything once — pipeable into less.
--live keeps the popup open and self-refreshing:
  · Agents panel + usage bars repaint every 2s (cheap: session-state files,
    incremental transcript tails, cached API observations)
  · the heavy sections (per-session 5h/24h/7d token lists, Codex quota)
    recompute every 15s
  · q / Esc closes

The Agents panel reads the per-session state files score-sessions.py
maintains (one per running Claude instance, hook-fed, PID-checked) — state,
project, model, current context size, session token totals, last activity.
"""

import contextlib
import datetime
import io
import json
import os
import pathlib
import subprocess
import sys
import time

CLAUDE_DIR = pathlib.Path.home() / ".claude" / "projects"
CODEX_DIR = pathlib.Path.home() / ".codex" / "sessions"
CACHE_DIR = pathlib.Path.home() / ".cache" / "rabble"
LATEST_OBS = CACHE_DIR / "llm-usage-latest.json"
SESS_DIR = CACHE_DIR / "claude-sessions"
CODEX_CACHE = CACHE_DIR / "score-codex.json"

LIGHT_REFRESH_S = 2
HEAVY_REFRESH_S = 15

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

STATE_META = {
    "needs-input": ("⚑", "needs input", MAGENTA),
    "busy":        ("✦", "busy",        CYAN),
    "ready":       ("▶", "ready",       GREEN),
}


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


def fmt_dur(seconds: float) -> str:
    seconds = max(0, int(seconds))
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h {m:02d}m"
    if m:
        return f"{m}m {s:02d}s"
    return f"{s}s"


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


# ── Agents panel ──────────────────────────────────────────────────────────────


def load_agents(now: float) -> list[dict]:
    """Read score-sessions.py's per-session state files. Read-only mirror of
    its load logic — the engine itself owns pruning; here a dead PID just
    hides the row."""
    agents = []
    if not SESS_DIR.is_dir():
        return agents
    for p in SESS_DIR.glob("*.json"):
        try:
            data = json.loads(p.read_text())
            age = now - p.stat().st_mtime
        except (OSError, json.JSONDecodeError):
            continue

        pid = data.get("pid")
        alive = None
        if pid:
            try:
                alive = (pathlib.Path(f"/proc/{pid}/comm").read_text().strip() == "claude")
            except OSError:
                alive = False
        if alive is False or (alive is None and age > 6 * 3600):
            continue

        state = data.get("state", "ready")
        if state == "busy" and age > (7200 if alive else 600):
            state = "ready"
        data["effective_state"] = state
        data["age_s"] = int(age)
        agents.append(data)

    rank = {"needs-input": 3, "busy": 2, "ready": 1}
    agents.sort(key=lambda d: (-rank.get(d["effective_state"], 0), d["age_s"]))
    return agents


def update_transcript_stats(cache: dict, path: str) -> dict:
    """Incremental per-session transcript totals. Remembers the byte offset
    between live-mode refreshes so each repaint only parses new lines. Never
    consumes a trailing partial line (the file is being written mid-turn)."""
    st = cache.get(path)
    if st is None:
        st = {"offset": 0, "in": 0, "out": 0, "model": "", "ctx": 0, "last_ts": 0.0}
        cache[path] = st
    try:
        size = os.stat(path).st_size
    except OSError:
        return st
    if size < st["offset"]:  # truncated/rotated — start over
        st.update(offset=0, **{"in": 0, "out": 0, "ctx": 0})
    if size == st["offset"]:
        return st

    try:
        with open(path, "rb") as f:
            f.seek(st["offset"])
            chunk = f.read()
    except OSError:
        return st
    nl = chunk.rfind(b"\n")
    if nl == -1:
        return st
    st["offset"] += nl + 1

    for line in chunk[: nl + 1].decode("utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        msg = entry.get("message", {})
        usage = msg.get("usage") or entry.get("usage") or {}
        if not usage:
            continue
        inp = usage.get("input_tokens", 0)
        out = usage.get("output_tokens", 0)
        st["in"] += inp
        st["out"] += out
        # Current context size = the latest request's full input picture
        st["ctx"] = (
            inp
            + usage.get("cache_read_input_tokens", 0)
            + usage.get("cache_creation_input_tokens", 0)
        )
        if msg.get("model"):
            st["model"] = msg["model"]
        st["last_ts"] = parse_any_ts(entry, st["last_ts"])
    return st


def codex_instance_count() -> int:
    try:
        out = subprocess.run(
            ["pgrep", "-cx", "codex"], capture_output=True, text=True, timeout=2
        ).stdout.strip()
        return int(out)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return 0


def codex_bar_state() -> str:
    """Codex state as the bar sees it — read from the heavy-tier cache."""
    try:
        cls = json.loads(CODEX_CACHE.read_text()).get("class", "")
    except (OSError, json.JSONDecodeError):
        return ""
    return cls.removeprefix("llm-")


def short_model(model: str) -> str:
    m = model.removeprefix("claude-")
    return m if len(m) <= 18 else m[:17] + "…"


def print_agents(now: float, tcache: dict):
    agents = load_agents(now)
    codex_n = codex_instance_count()

    n_blocked = sum(1 for a in agents if a["effective_state"] == "needs-input")
    n_busy = sum(1 for a in agents if a["effective_state"] == "busy")
    head = f"{len(agents)} claude · {codex_n} codex"
    if n_blocked:
        head += f"  {MAGENTA}⚑{n_blocked} blocked{RESET}"

    print(f"\n{VIOLET}{'─'*60}{RESET}")
    print(f"{VIOLET}Agents{RESET}  {TEXT}{head}{RESET}")
    print(f"{VIOLET}{'─'*60}{RESET}")

    if not agents and codex_n == 0:
        print(f"  {MUTED}no agents running{RESET}")

    for a in agents:
        state = a["effective_state"]
        glyph, label, color = STATE_META.get(state, ("·", state, MUTED))
        project = (a.get("project") or "?")[:22]
        sid = (a.get("session_id") or "")[-6:]

        stats = {}
        if a.get("transcript"):
            stats = update_transcript_stats(tcache, a["transcript"])

        last_ts = max(
            float(stats.get("last_ts") or 0), now - a["age_s"]
        )
        detail = []
        if stats.get("model"):
            detail.append(short_model(stats["model"]))
        if stats.get("ctx"):
            detail.append(f"ctx {fmt_tokens(stats['ctx'])}")
        if stats.get("in") or stats.get("out"):
            detail.append(f"Σ {fmt_tokens(stats['in'] + stats['out'])}")
        if state == "busy" and a.get("busy_since"):
            detail.append(f"turn {fmt_dur(now - float(a['busy_since']))}")
        if state == "needs-input" and a.get("note"):
            note = a["note"].strip()
            detail.append(note if len(note) <= 48 else note[:47] + "…")

        print(
            f"  {color}{glyph} {label:<11}{RESET} {TEXT}{project:<22}{RESET} "
            f"{MUTED}{fmt_age(now - last_ts):>10} · {' · '.join(detail) or '—'} · {sid}{RESET}"
        )

    if codex_n:
        state = codex_bar_state() or "ready"
        glyph, label, color = STATE_META.get(state, (">_", state or "?", CYAN))
        print(
            f"  {color}{glyph} {label:<11}{RESET} {TEXT}{'codex':<22}{RESET} "
            f"{MUTED}{codex_n} instance{'s' if codex_n != 1 else ''}{RESET}"
        )

    # Hook-less stragglers: claude processes with no session registration
    try:
        claude_procs = int(subprocess.run(
            ["pgrep", "-cx", "claude"], capture_output=True, text=True, timeout=2
        ).stdout.strip())
    except (OSError, ValueError, subprocess.TimeoutExpired):
        claude_procs = 0
    if claude_procs > len(agents):
        extra = claude_procs - len(agents)
        print(f"  {MUTED}· {extra} claude process(es) without session hooks (pre-wiring){RESET}")


# ── Usage bars (official API observations) ───────────────────────────────────


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
            entry = {"pct": pct, "age": now - ts, "web_used": bool(row.get("web_used"))}
            raw_reset = row.get("resets_at")
            if raw_reset:
                try:
                    if isinstance(raw_reset, str):
                        entry["resets_at"] = datetime.datetime.fromisoformat(
                            raw_reset.replace("Z", "+00:00")
                        ).timestamp()
                    else:
                        entry["resets_at"] = float(raw_reset)
                except Exception:
                    pass
            out[label] = entry
    return out


def make_bar(pct: float, width: int = 26) -> str:
    pct = max(0.0, min(100.0, pct))
    filled = round(pct / 100 * width)
    color = GREEN if pct < 60 else YELLOW if pct < 85 else MAGENTA
    return f"{color}{'█' * filled}{MUTED}{'░' * (width - filled)}{RESET}"


def print_usage_bars(now: float):
    observations = latest_web_observations(now)
    if not observations:
        return

    print(f"\n{VIOLET}{'─'*60}{RESET}")
    print(f"{VIOLET}Claude quota{RESET}  {MUTED}(Anthropic's own meter){RESET}")
    print(f"{VIOLET}{'─'*60}{RESET}")
    for label in ("5h", "week"):
        row = observations.get(label)
        if not row:
            continue
        reset_txt = ""
        if row.get("resets_at"):
            left = int(row["resets_at"] - now)
            reset_txt = " · resets now" if left <= 0 else (
                f" · resets {left // 3600}h {(left % 3600) // 60:02d}m"
            )
        print(
            f"  {CYAN}{label:<5}{RESET} {make_bar(row['pct'])} "
            f"{TEXT}{row['pct']:>5.1f}%{RESET}"
            f"{MUTED}{reset_txt} · {fmt_age(row['age'])}{RESET}"
        )


# ── Heavy sections (per-session token lists, Codex quota) ────────────────────


def _short_model(m: str) -> str:
    return m.replace("claude-", "").replace("-20251001", "")


def parse_sessions(since_s: float) -> list[dict]:
    """Return list of {path, first_ts, last_ts, input, output, models} for each session."""
    sessions = []
    if not CLAUDE_DIR.exists():
        return sessions

    for jl in CLAUDE_DIR.rglob("*.jsonl"):
        try:
            mtime = jl.stat().st_mtime
            if mtime < since_s - 60:
                continue

            first_ts  = mtime
            last_ts   = mtime
            total_in  = 0
            total_out = 0
            has_data  = False
            models: dict[str, int] = {}  # short_name -> output tokens

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
                        model = msg.get("model") or entry.get("model") or ""
                        if model and model != "<synthetic>":
                            ms = _short_model(model)
                            models[ms] = models.get(ms, 0) + out

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
                    "models":   models,
                })
        except Exception:
            continue

    sessions.sort(key=lambda s: s["last_ts"], reverse=True)
    return sessions


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


def window_reset(sessions: list[dict], window_s: float, now: float, reset_override: float | None = None) -> str:
    if reset_override is not None:
        resets_at = reset_override
    else:
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


def print_section(title: str, sessions: list[dict], window_s: float, now: float, reset_override: float | None = None):
    total = sum(s["total"] for s in sessions)
    reset = window_reset(sessions, window_s, now, reset_override)

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

    # Per-model breakdown: aggregate output tokens across all sessions shown,
    # then display as a share of total output (ratios hold despite duplicate records)
    if sessions:
        model_totals: dict[str, int] = {}
        for s in sessions:
            for m, toks in s.get("models", {}).items():
                model_totals[m] = model_totals.get(m, 0) + toks
        total_mtok = sum(model_totals.values())
        if total_mtok > 0:
            parts = []
            for m, toks in sorted(model_totals.items(), key=lambda x: -x[1]):
                pct = 100 * toks / total_mtok
                if pct >= 1:
                    parts.append(f"{YELLOW}{m}{RESET} {fmt_tokens(toks)} ({pct:.0f}%)")
            if parts:
                print(f"  {MUTED}{'─'*58}{RESET}")
                print(f"  {MUTED}By model (output share): {RESET}{'  '.join(parts)}")


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
        print(f"  {make_bar(float(pct))} {TEXT}{float(pct):>5.1f}%{RESET}", end="")
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


# ── Render orchestration ──────────────────────────────────────────────────────


def five_h_window_start(now: float):
    """Anchor the 5h section to Anthropic's real window when known."""
    web_obs = latest_web_observations(now)
    five_h_reset = (web_obs.get("5h") or {}).get("resets_at")
    five_h_start = now - 18_000
    if five_h_reset is not None:
        candidate_start = five_h_reset - 18_000
        if candidate_start <= now:
            five_h_start = candidate_start
        else:
            five_h_reset = None  # snapshot hasn't caught up with a fresh reset yet
    return five_h_start, five_h_reset


def _capture(fn, *args, **kwargs) -> str:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        fn(*args, **kwargs)
    return buf.getvalue()


def render_light(now: float, tcache: dict, live: bool) -> str:
    def body():
        hint = "live" if live else "q to close"
        print(
            f"\n{MAGENTA}  sCoRE Usage Tracker{RESET}  "
            f"{MUTED}{datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}{RESET}  "
            f"{CYAN}{hint}{RESET}"
        )
        print_agents(now, tcache)
        print_usage_bars(now)
    return _capture(body)


def print_antigravity(now: float) -> None:
    cache = CACHE_DIR / "score-antigravity.json"
    print(f"\n{VIOLET}{'─'*60}{RESET}")
    print(f"{VIOLET}Antigravity (agy){RESET}")
    print(f"{VIOLET}{'─'*60}{RESET}")
    if not cache.is_file():
        print(f"  {MUTED}No cache — start score-status-daemon to populate{RESET}")
        return
    age = now - cache.stat().st_mtime
    try:
        data = json.loads(cache.read_text())
    except (OSError, json.JSONDecodeError):
        print(f"  {MUTED}Cache unreadable{RESET}")
        return
    cls = data.get("class", "llm-idle")
    state_color = MAGENTA if "needs" in cls else (CYAN if "busy" in cls else (GREEN if "ready" in cls else MUTED))
    for line in data.get("tooltip", "").split("\n"):
        if line.startswith("═"):
            continue
        if not line.strip():
            continue
        key, _, val = line.partition(":")
        if val:
            print(f"  {MUTED}{key.rstrip()}:{RESET} {state_color if 'Status' in key else TEXT}{val.strip()}{RESET}")
        else:
            print(f"  {TEXT}{line}{RESET}")
    if age > 30:
        print(f"\n  {YELLOW}⚠ cache is {int(age)}s old — daemon may be down{RESET}")


def render_heavy(now: float, mode: str) -> str:
    def body():
        five_h_start, five_h_reset = five_h_window_start(now)
        sessions_5h  = parse_sessions(five_h_start)
        sessions_24h = parse_sessions(now - 86_400)
        sessions_7d  = parse_sessions(now - 604_800)

        def claude_sections():
            print_separator("Claude Code")
            print_section("5-hour window", sessions_5h,  18_000,  now, five_h_reset)
            print_section("Last 24 hours", sessions_24h, 86_400,  now)
            print_section("Last 7 days",   sessions_7d,  604_800, now)

        def codex_sections():
            print_separator("Codex")
            print_codex(now)

        def antigravity_sections():
            print_antigravity(now)

        if mode == "antigravity":
            antigravity_sections()
        elif mode == "codex":
            codex_sections()
        else:
            claude_sections()
            codex_sections()
            total_week = sum(s["total"] for s in sessions_7d)
            print(f"\n{MUTED}  Weekly total: {fmt_tokens(total_week)} tokens across {len(sessions_7d)} session(s){RESET}\n")
    return _capture(body)


def read_key(timeout: float):
    """One keypress, with arrow/page escape sequences decoded — a bare Esc is
    distinguishable from the \\x1b that starts every arrow key, so scrolling
    never accidentally closes the popup (the `less` failure mode)."""
    import select

    r, _, _ = select.select([sys.stdin], [], [], timeout)
    if not r:
        return None
    ch = sys.stdin.read(1)
    if ch != "\x1b":
        return ch
    r, _, _ = select.select([sys.stdin], [], [], 0.03)
    if not r:
        return "ESC"
    if sys.stdin.read(1) != "[":
        return "ESC"
    final = sys.stdin.read(1)
    if final.isdigit():
        num = final
        while True:
            c = sys.stdin.read(1)
            if not c.isdigit():
                break
            num += c
        return {"5": "PGUP", "6": "PGDN", "1": "HOME", "4": "END"}.get(num)
    return {"A": "UP", "B": "DOWN", "H": "HOME", "F": "END"}.get(final)


def run_live(mode: str):
    import shutil

    tcache: dict = {}
    heavy = ""
    heavy_ts = 0.0
    offset = 0
    frame_lines: list[str] = []

    old_attrs = None
    fd = None
    try:
        import termios
        import tty
        fd = sys.stdin.fileno()
        old_attrs = termios.tcgetattr(fd)
        tty.setcbreak(fd)
    except Exception:
        old_attrs = None

    def draw():
        nonlocal offset
        cols, rows = shutil.get_terminal_size()
        view_h = max(5, rows - 1)  # last row is the status bar
        max_off = max(0, len(frame_lines) - view_h)
        offset = max(0, min(offset, max_off))
        visible = frame_lines[offset:offset + view_h]
        pos = "all" if max_off == 0 else f"{offset + 1}-{offset + len(visible)}/{len(frame_lines)}"
        status = (
            f"{MUTED}  [{pos}] ↑↓/jk PgUp/PgDn scroll · g/G top/bottom · "
            f"q close · refresh {LIGHT_REFRESH_S}s{RESET}"
        )
        sys.stdout.write("\x1b[H\x1b[2J" + "\n".join(visible) + "\n" + status)
        sys.stdout.flush()

    sys.stdout.write("\x1b[?1049h\x1b[?25l")  # alt screen, hide cursor
    try:
        while True:
            now = time.time()
            if now - heavy_ts > HEAVY_REFRESH_S:
                heavy = render_heavy(now, mode)
                heavy_ts = now
            if mode == "claude":
                frame_lines = (render_light(now, tcache, live=True) + heavy).splitlines()
            else:
                frame_lines = heavy.splitlines()
            draw()

            if old_attrs is None:
                time.sleep(LIGHT_REFRESH_S)
                continue

            # Keys act instantly (redraw the same data at the new offset);
            # the data refresh itself waits for the cadence timeout.
            deadline = time.time() + LIGHT_REFRESH_S
            quit_now = False
            while True:
                remaining = deadline - time.time()
                if remaining <= 0:
                    break
                key = read_key(remaining)
                if key is None:
                    continue
                page = max(5, shutil.get_terminal_size().lines - 2)
                if key in ("q", "Q", "ESC"):
                    quit_now = True
                    break
                elif key in ("UP", "k"):
                    offset -= 1
                elif key in ("DOWN", "j"):
                    offset += 1
                elif key in ("PGUP",):
                    offset -= page
                elif key in ("PGDN", " "):
                    offset += page
                elif key in ("HOME", "g"):
                    offset = 0
                elif key in ("END", "G"):
                    offset = 10**9
                else:
                    continue
                draw()
            if quit_now:
                break
    except KeyboardInterrupt:
        pass
    finally:
        sys.stdout.write("\x1b[?25h\x1b[?1049l")
        sys.stdout.flush()
        if old_attrs is not None:
            import termios
            termios.tcsetattr(fd, termios.TCSADRAIN, old_attrs)


def main():
    args = [a for a in sys.argv[1:]]
    live = "--live" in args
    mode = next((a for a in args if not a.startswith("-")), "claude").strip().lower()

    if live:
        run_live(mode)
        return

    now = time.time()
    if mode == "claude":
        sys.stdout.write(render_light(now, {}, live=False))
    sys.stdout.write(render_heavy(now, mode))


if __name__ == "__main__":
    main()
