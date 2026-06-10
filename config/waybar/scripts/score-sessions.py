#!/usr/bin/env python3
"""
score-sessions.py — multi-instance session-state engine for the sCoRE Usage Tracker.

The old design kept ONE global state file (claude-live-state) that every Claude
instance's hooks overwrote — with two agents running, whichever fired last won,
so a blocked agent's "needs-input" flash could be silently clobbered by another
agent's "busy". This engine keeps one state file PER session under
~/.cache/rabble/claude-sessions/<session_id>.json and aggregates them, so the
bar always knows how many agents are running and whether ANY of them is blocked.

Subcommands
  update              stdin = Claude Code hook JSON. Updates that session's
                      state file, prunes dead sessions, rewrites the aggregate,
                      pokes the glyph-stream wake-FIFO, and fires desktop
                      notifications on "needs input" / long-turn-complete.
  codex-notify [JSON] argv = Codex `notify` program payload (agent-turn-complete).
                      Marks the Codex turn done + pokes the codex FIFO.
  summary [--shell]   Prune + rewrite aggregate, print a summary. --shell emits
                      eval-able KEY=value lines for score-status.sh; default is
                      JSON for the popup / other tooling.

State model (per session)
  busy         UserPromptSubmit / PreToolUse / PostToolUse / SubagentStop.
               (SubagentStop maps to busy, NOT ready — a finished subagent
               means the parent is still processing its result. The old
               mapping to "ready" mid-flight was a bug.)
  needs-input  Notification whose message mentions "permission" — hard-blocked
               on YOUR authorization. (The "waiting for your input" idle
               notification maps to ready instead — that's just an open prompt.)
  ready        SessionStart / Stop / non-permission Notification — registered
               and idle, awaiting a prompt.
  (removed)    SessionEnd, or the owning claude process died.

Liveness: `update` records the hook's `claude` ancestor PID. A session whose
PID is gone is pruned on the next pass — a crashed agent can never wedge the
bar. Sessions without a resolvable PID fall back to mtime staleness.

Aggregate file (~/.cache/rabble/claude-agg-state):
  "<state> <total> <busy> <needs-input> <ready>"  — single line; the first
  word keeps it readable by anything that only wants the overall state.
  claude-live-state (single word) is still written for legacy readers.

Notifications: desktop notifications via notify-send (mako). Touch
~/.cache/rabble/score-notifications-off to silence them.
"""

import json
import os
import subprocess
import sys
import time

CACHE_DIR = os.path.expanduser("~/.cache/rabble")
SESS_DIR = os.path.join(CACHE_DIR, "claude-sessions")
AGG_FILE = os.path.join(CACHE_DIR, "claude-agg-state")
LEGACY_FILE = os.path.join(CACHE_DIR, "claude-live-state")
CODEX_STATE_FILE = os.path.join(CACHE_DIR, "codex-live-state")
CLAUDE_FIFO = os.path.join(CACHE_DIR, "score-claude-wake.fifo")
CODEX_FIFO = os.path.join(CACHE_DIR, "score-codex-wake.fifo")
NOTIFY_OFF_FILE = os.path.join(CACHE_DIR, "score-notifications-off")

LONG_TURN_NOTIFY_S = 180      # Stop after a turn at least this long → notification
BUSY_STALE_NO_PID_S = 600     # busy w/o a liveness PID degrades to ready after this
BUSY_STALE_PID_S = 7200       # even with a live PID, busy this stale reads as ready
SESSION_EXPIRE_S = 6 * 3600   # sessions w/o a PID are dropped entirely after this

RANK = {"needs-input": 3, "busy": 2, "ready": 1}
GLYPH = {"needs-input": "⚑", "busy": "✦", "ready": "▶"}
LABEL = {"needs-input": "needs input", "busy": "busy", "ready": "ready"}


def ensure_dirs():
    os.makedirs(SESS_DIR, exist_ok=True)


def atomic_write(path: str, text: str):
    tmp = f"{path}.tmp.{os.getpid()}"
    try:
        with open(tmp, "w") as f:
            f.write(text)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def poke(fifo: str):
    """Wake a glyph-stream loop. O_NONBLOCK means a missing reader (Waybar not
    running) fails instantly with ENXIO instead of blocking the hook."""
    try:
        fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
    except OSError:
        return
    try:
        os.write(fd, b"x")
    except OSError:
        pass
    finally:
        os.close(fd)


def claude_pid_alive(pid):
    """True/False if we can tell, None if the session never resolved a PID."""
    if not pid:
        return None
    try:
        with open(f"/proc/{pid}/comm") as f:
            return f.read().strip() == "claude"
    except OSError:
        return False


def find_claude_ancestor():
    """Walk this hook process's parent chain looking for the owning `claude`."""
    pid = os.getppid()
    for _ in range(15):
        if pid <= 1:
            return None
        try:
            with open(f"/proc/{pid}/comm") as f:
                if f.read().strip() == "claude":
                    return pid
            with open(f"/proc/{pid}/status") as f:
                pid = next(
                    int(line.split()[1]) for line in f if line.startswith("PPid:")
                )
        except (OSError, StopIteration, ValueError, IndexError):
            return None
    return None


def notify(summary: str, body: str = "", urgency: str = "normal"):
    if os.path.exists(NOTIFY_OFF_FILE):
        return
    try:
        subprocess.Popen(
            ["notify-send", "-a", "sCoRE", "-u", urgency, summary, body],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        pass


EVENT_LOG = os.path.join(CACHE_DIR, "score-hook-events.log")


def log_event(event: str, sid: str, state, message: str):
    """Rolling debug log of every hook event — the data for tuning state
    mappings (e.g. what a permission Notification's message actually says)."""
    try:
        line = (
            f"{time.strftime('%Y-%m-%d %H:%M:%S')} {event:<18} "
            f"{(sid or '?')[-6:]} -> {state or '-'}"
            f"{' | ' + message if message else ''}\n"
        )
        with open(EVENT_LOG, "a") as f:
            f.write(line)
        if os.path.getsize(EVENT_LOG) > 256 * 1024:
            with open(EVENT_LOG) as f:
                tail = f.readlines()[-500:]
            atomic_write(EVENT_LOG, "".join(tail))
    except OSError:
        pass


def fmt_age(seconds: int) -> str:
    seconds = max(0, int(seconds))
    if seconds < 60:
        return f"{seconds}s"
    m, s = divmod(seconds, 60)
    if m < 60:
        return f"{m}m {s:02d}s" if m < 10 else f"{m}m"
    h, m = divmod(m, 60)
    return f"{h}h {m:02d}m"


def load_sessions(prune: bool = True) -> list[dict]:
    """Read all session files, prune the dead, demote the stale-busy."""
    now = time.time()
    out = []
    try:
        names = os.listdir(SESS_DIR)
    except OSError:
        return out

    for name in names:
        if not name.endswith(".json"):
            continue
        path = os.path.join(SESS_DIR, name)
        try:
            with open(path) as f:
                data = json.load(f)
            age = now - os.stat(path).st_mtime
        except (OSError, json.JSONDecodeError):
            if prune:
                try:
                    os.unlink(path)
                except OSError:
                    pass
            continue

        alive = claude_pid_alive(data.get("pid"))
        if alive is False or (alive is None and age > SESSION_EXPIRE_S):
            if prune:
                try:
                    os.unlink(path)
                except OSError:
                    pass
            continue

        state = data.get("state", "ready")
        if state == "busy":
            limit = BUSY_STALE_PID_S if alive else BUSY_STALE_NO_PID_S
            if age > limit:
                state = "ready"
        data["effective_state"] = state
        data["age_s"] = int(age)
        out.append(data)

    out.sort(key=lambda d: (-RANK.get(d["effective_state"], 0), d["age_s"]))
    return out


def aggregate(sessions: list[dict]):
    counts = {"busy": 0, "needs-input": 0, "ready": 0}
    for s in sessions:
        counts[s["effective_state"]] = counts.get(s["effective_state"], 0) + 1
    overall = "idle"
    for st in ("needs-input", "busy", "ready"):
        if counts[st]:
            overall = st
            break
    atomic_write(
        AGG_FILE,
        f"{overall} {len(sessions)} {counts['busy']} "
        f"{counts['needs-input']} {counts['ready']}\n",
    )
    atomic_write(LEGACY_FILE, overall)
    return overall, counts


# ── Subcommands ───────────────────────────────────────────────────────────────


def cmd_update():
    try:
        d = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return

    event = d.get("hook_event_name", "")
    sid = d.get("session_id") or ""
    path = os.path.join(SESS_DIR, f"{sid}.json") if sid else None

    prev = {}
    if path and os.path.exists(path):
        try:
            with open(path) as f:
                prev = json.load(f)
        except (OSError, json.JSONDecodeError):
            prev = {}

    now = time.time()
    cwd = d.get("cwd") or prev.get("cwd") or ""
    project = os.path.basename(cwd.rstrip("/")) or "?"

    new_state = None
    if event == "SessionEnd":
        if path:
            try:
                os.unlink(path)
            except OSError:
                pass
    elif event == "SessionStart":
        new_state = "ready"
    elif event in ("UserPromptSubmit", "PreToolUse", "PostToolUse",
                   "SubagentStop", "PreCompact"):
        new_state = "busy"
    elif event == "Notification":
        # Blocked by default — a notification means Claude wants attention,
        # and the exact permission-prompt wording varies between Claude Code
        # versions, so allow-listing "permission" misses real blocks. The ONE
        # known non-blocking notification is the idle reminder ("Claude is
        # waiting for your input", fired after sitting at an empty prompt):
        # that maps to ready — but never demotes an existing needs-input
        # (a still-pending permission dialog idles too; only the user acting
        # — prompt submit / tool start / stop — clears a block).
        msg = (d.get("message") or "").lower()
        if "waiting for your input" in msg or "awaiting your input" in msg:
            new_state = "needs-input" if prev.get("state") == "needs-input" else "ready"
        else:
            new_state = "needs-input"
    elif event == "Stop":
        new_state = "ready"

    if new_state and path:
        busy_since = prev.get("busy_since")
        if event == "UserPromptSubmit":
            busy_since = now

        if new_state == "needs-input" and prev.get("state") != "needs-input":
            notify(
                f"Claude needs you — {project}",
                d.get("message") or "Awaiting your input",
                urgency="critical",
            )
        if event == "Stop":
            if busy_since and now - busy_since >= LONG_TURN_NOTIFY_S:
                dur = int(now - busy_since)
                notify(
                    f"Claude finished — {project}",
                    f"turn ran {fmt_age(dur)}",
                )
            busy_since = None

        rec = {
            "session_id": sid,
            "state": new_state,
            "event": event,
            "ts": now,
            "cwd": cwd,
            "project": project,
            "transcript": d.get("transcript_path") or prev.get("transcript"),
            "pid": prev.get("pid") or find_claude_ancestor(),
            "busy_since": busy_since,
            # Why it's blocked — surfaced by the popup's Agents panel
            "note": (d.get("message") or "") if new_state == "needs-input" else "",
        }
        atomic_write(path, json.dumps(rec))

    log_event(event, sid, new_state, d.get("message") or "")
    aggregate(load_sessions())
    poke(CLAUDE_FIFO)


def cmd_codex_notify(argv: list[str]):
    payload = {}
    for arg in argv:
        try:
            candidate = json.loads(arg)
            if isinstance(candidate, dict):
                payload = candidate
                break
        except (json.JSONDecodeError, ValueError):
            continue

    atomic_write(CODEX_STATE_FILE, "ready")
    poke(CODEX_FIFO)

    if payload.get("type") == "agent-turn-complete":
        body = (payload.get("last-assistant-message") or "").strip()
        if len(body) > 160:
            body = body[:157] + "…"
        notify("Codex turn complete", body)


def cmd_summary(shell: bool):
    sessions = load_sessions()
    overall, counts = aggregate(sessions)

    if shell:
        import shlex

        lines = []
        for s in sessions:
            st = s["effective_state"]
            sid = (s.get("session_id") or "")[-6:]
            line = (
                f"{GLYPH.get(st, '·')} {s.get('project', '?')} · "
                f"{LABEL.get(st, st)} · {fmt_age(s['age_s'])} ago"
            )
            if sid:
                line += f" · {sid}"
            lines.append(line)
        print(f"CL_STATE={overall}")
        print(f"CL_TOTAL={len(sessions)}")
        print(f"CL_BUSY={counts['busy']}")
        print(f"CL_NEEDS={counts['needs-input']}")
        print(f"CL_READY={counts['ready']}")
        print("CL_AGENTS=" + shlex.quote("\n".join(lines)))
    else:
        print(json.dumps({
            "state": overall,
            "total": len(sessions),
            "busy": counts["busy"],
            "needs_input": counts["needs-input"],
            "ready": counts["ready"],
            "sessions": [
                {
                    "session_id": s.get("session_id"),
                    "state": s["effective_state"],
                    "project": s.get("project"),
                    "cwd": s.get("cwd"),
                    "transcript": s.get("transcript"),
                    "pid": s.get("pid"),
                    "event": s.get("event"),
                    "age_s": s["age_s"],
                    "busy_since": s.get("busy_since"),
                }
                for s in sessions
            ],
        }, ensure_ascii=False))


def main():
    ensure_dirs()
    cmd = sys.argv[1] if len(sys.argv) > 1 else "summary"
    if cmd == "update":
        cmd_update()
    elif cmd == "codex-notify":
        cmd_codex_notify(sys.argv[2:])
    elif cmd == "summary":
        cmd_summary("--shell" in sys.argv[2:])
    else:
        print(f"usage: {os.path.basename(sys.argv[0])} "
              "{update|codex-notify|summary [--shell]}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # A hook must never break the agent that called it.
        sys.exit(0)
