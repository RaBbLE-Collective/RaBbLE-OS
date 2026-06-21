#!/usr/bin/env python3
"""score-agy-quota.py — live Antigravity (agy) quota state from the CLI logs.

agy has TWO independent quota pools, neither shared with Claude Code:
  · Gemini API quota          — hit when a Gemini/Flash model is active
  · Antigravity service quota — hit when a Claude/GPT model is active
Both surface the same line: "RESOURCE_EXHAUSTED ... Resets in <dur>".

THE BUG THIS FIXES
------------------
The old readers (score-status.sh bar, score-usage-detail.py popup) flagged a
pool as exhausted whenever *any* RESOURCE_EXHAUSTED line existed in the last
7 days. So once you hit a limit the ⊘ stuck around for a full week — a reset
was invisible. The popup tried to subtract elapsed time but anchored to the
log FILE's mtime (last write), not the event, and never actually cleared the
pool even when the countdown went negative.

WHAT "LIVE" MEANS HERE
----------------------
The discriminator is the OUTCOME of the most recent request per pool, read
straight from the glog lines:

  · A request is "server.go:1058] Sending user message to conversation". The
    model it ran under is the last model_config_manager.go:157 "label=..." seen
    before it (that fixes its pool: Gemini/Flash → gemini, else → service).
  · If a RESOURCE_EXHAUSTED follows that send before the next send, the send
    FAILED. Otherwise it SUCCEEDED.
  · Watching the bare model-selection line instead does NOT work: agy re-emits
    one right after an exhaustion (quota refresh re-propagates the model), so it
    is not proof the pool recovered. Only a *send with no exhaustion after it* is.

Each RESOURCE_EXHAUSTED carries "Resets in <dur>" relative to *the moment it was
logged*; we anchor it to that line's own glog timestamp (Emmdd HH:MM:SS, year
from the filename) → an absolute reset epoch. But that estimate is often
pessimistic (Google has reset a pool well before its stated time), so it is only
a secondary cap, never the primary signal.

A pool is reported exhausted IFF its most recent outcome was a failure
(last_exhausted >= last_success) AND the reset epoch is still in the future.
That clears the ⊘ the instant a request goes through again — even if the stale
"Resets in" countdown still has days on it.

Emits JSON (default) or `--shell` env-assignments for the bash bar. Stdlib only.
"""

from __future__ import annotations

import datetime
import json
import pathlib
import re
import sys
import time

LOG_DIR = pathlib.Path.home() / ".gemini" / "antigravity-cli" / "log"

# Reset windows run ~7 days; an event up to 7 days old can still be active, so
# scan a fortnight of files to be safe. Older logs can't describe a live limit.
SCAN_WINDOW_S = 14 * 86400

_FNAME_RE = re.compile(r"cli-(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})\.log$")
_GLOG_RE = re.compile(r"^[IWEF](\d{2})(\d{2})\s+(\d{2}):(\d{2}):(\d{2})")
_LABEL_RE = re.compile(r'model_config_manager.*label="([^"]+)"')
_SEND_RE = re.compile(r"Sending user message to conversation")
_RESETS_RE = re.compile(r"RESOURCE_EXHAUSTED.*?Resets in (\w+)")
_DUR_RE = re.compile(r"(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?")


def _parse_dur(s: str) -> int:
    m = _DUR_RE.match(s)
    if not m:
        return 0
    h, mn, sec = (int(x or 0) for x in m.groups())
    return h * 3600 + mn * 60 + sec


def _file_base_year(path: pathlib.Path) -> tuple[int, float] | None:
    """(year, file_start_epoch) parsed from the cli-YYYYMMDD_HHMMSS.log name."""
    m = _FNAME_RE.search(path.name)
    if not m:
        return None
    y, mo, d, h, mi, s = (int(x) for x in m.groups())
    try:
        start = datetime.datetime(y, mo, d, h, mi, s)
    except ValueError:
        return None
    return y, start.timestamp()


def _event_epoch(line: str, year: int, file_start: float) -> float | None:
    """Absolute epoch of a glog line. glog timestamps carry no year, so we take
    it from the filename and bump by one across a Dec->Jan rollover."""
    m = _GLOG_RE.match(line)
    if not m:
        return None
    mo, d, h, mi, s = (int(x) for x in m.groups())
    try:
        dt = datetime.datetime(year, mo, d, h, mi, s)
    except ValueError:
        return None
    ep = dt.timestamp()
    if ep < file_start - 2 * 86400:  # line predates file start -> next calendar year
        try:
            ep = dt.replace(year=year + 1).timestamp()
        except ValueError:
            return None
    return ep


def _classify(model_label: str) -> str:
    """Which quota pool a model belongs to."""
    low = model_label.lower()
    if not model_label or "gemini" in low or "flash" in low:
        return "gemini"
    return "service"


def compute(now: float | None = None) -> dict:
    if now is None:
        now = time.time()

    pools = {
        "gemini":  {"last_exhausted": 0.0, "reset_epoch": 0.0, "last_success": 0.0, "model": ""},
        "service": {"last_exhausted": 0.0, "reset_epoch": 0.0, "last_success": 0.0, "model": ""},
    }

    # A send is "pending" until we know its outcome: a RESOURCE_EXHAUSTED before
    # the next send means it failed; anything else (next send / end of log) means
    # it went through. Tracked across files in chronological order.
    pend_pool = None
    pend_ts = 0.0

    def _commit_success():
        nonlocal pend_pool, pend_ts
        if pend_pool is not None:
            p = pools[pend_pool]
            if pend_ts > p["last_success"]:
                p["last_success"] = pend_ts
        pend_pool = None
        pend_ts = 0.0

    if LOG_DIR.is_dir():
        for lf in sorted(LOG_DIR.glob("cli-*.log")):
            try:
                if now - lf.stat().st_mtime > SCAN_WINDOW_S:
                    continue
                base = _file_base_year(lf)
                if base is None:
                    continue
                year, file_start = base
                cur_mdl = ""
                for line in lf.read_text(errors="replace").splitlines():
                    lm = _LABEL_RE.search(line)
                    if lm:
                        cur_mdl = lm.group(1)
                        continue
                    if _SEND_RE.search(line):
                        ep = _event_epoch(line, year, file_start)
                        if ep is None:
                            continue
                        _commit_success()          # previous send had no error → success
                        pend_pool = _classify(cur_mdl)
                        pend_ts = ep
                        continue
                    rm = _RESETS_RE.search(line)
                    if rm:
                        ep = _event_epoch(line, year, file_start)
                        if ep is None:
                            continue
                        p = pools[_classify(cur_mdl)]
                        if ep >= p["last_exhausted"]:
                            p["last_exhausted"] = ep
                            p["reset_epoch"] = ep + _parse_dur(rm.group(1))
                            p["model"] = cur_mdl
                        # this send failed — drop it so it can't count as success
                        if pend_pool == _classify(cur_mdl):
                            pend_pool = None
                            pend_ts = 0.0
            except OSError:
                continue
    _commit_success()  # a final un-erroneous send counts as a success

    out = {}
    for name, p in pools.items():
        exhausted = (
            p["last_exhausted"] > 0
            and p["last_exhausted"] >= p["last_success"]    # most recent outcome was a failure
            and now < p["reset_epoch"]                       # window not yet rolled (secondary cap)
        )
        remaining = int(p["reset_epoch"] - now) if exhausted else 0
        out[name] = {
            "exhausted": exhausted,
            "reset_epoch": p["reset_epoch"] if exhausted else None,
            "remaining_s": max(remaining, 0),
            "resets_in": _fmt_remaining(remaining) if exhausted else "",
            "model": p["model"] if exhausted else "",
        }
    return out


def _fmt_remaining(secs: int) -> str:
    if secs <= 0:
        return "soon"
    h, rem = divmod(secs, 3600)
    mn = rem // 60
    if h:
        return f"{h}h{mn:02d}m"
    return f"{mn}m"


def _sh_quote(s: str) -> str:
    return "'" + s.replace("'", "'\\''") + "'"


def main() -> None:
    state = compute()
    if "--shell" in sys.argv[1:]:
        g, s = state["gemini"], state["service"]
        print(f"AGY_GEMINI_RL={1 if g['exhausted'] else 0}")
        print(f"AGY_GEMINI_RESETS={_sh_quote(g['resets_in'])}")
        print(f"AGY_GEMINI_MODEL={_sh_quote(g['model'])}")
        print(f"AGY_SERVICE_RL={1 if s['exhausted'] else 0}")
        print(f"AGY_SERVICE_RESETS={_sh_quote(s['resets_in'])}")
        print(f"AGY_SERVICE_MODEL={_sh_quote(s['model'])}")
    else:
        print(json.dumps(state, ensure_ascii=False))


if __name__ == "__main__":
    main()
