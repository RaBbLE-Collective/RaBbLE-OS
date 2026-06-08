#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "browser-cookie3>=0.20.1",
#   "curl-cffi>=0.13.0",
# ]
# ///
"""
score-usage-api-poll.py — Pulls Claude's *official* 5h/7d usage % straight from
Anthropic's own API and feeds it to the Waybar tracker.

Why this exists: the local transcript-token estimate (score-status.sh) can't see
claude.ai web-chat usage, and scraping the rendered usage page (the original
userscript+bridge plan) means parsing UI text that breaks on every redesign.

Anthropic's web client itself calls an internal endpoint —
    GET https://claude.ai/api/organizations/{org_id}/usage
— authenticated with the same session cookie your browser already holds. We
read that cookie straight out of Firefox's cookies.sqlite (read-only, scoped
to the claude.ai domain — exactly what the browser tab does, no separate
OAuth dance) and call the endpoint directly with curl_cffi impersonating
Chrome's TLS fingerprint (Anthropic's edge blocks plain `requests`/`curl`).
This returns Anthropic's own computed percentages — exact, not estimated.

Approach lifted from github.com/NihilDigit/waybar-ai-usage (claude.py/common.py).

Runs as a persistent loop (see hypr/conf.d/autostart.conf exec-once) and
writes straight into ~/.cache/rabble/llm-usage-latest.json — the same
"observed" cache score-status.sh already prefers over its token estimate, so no
changes to the bar script are needed.

Fragility notes (the parts that CAN break):
  - Undocumented internal API: Anthropic could change the path/shape any time.
  - TLS fingerprint: curl_cffi's "chrome" impersonation may need bumping if
    Cloudflare tightens checks.
  - Needs an active claude.ai session in Firefox (you're logged in anyway).
The cookie read itself is not the fragile part — it's a verbatim copy of what
your browser already sends.
"""

from __future__ import annotations

import glob
import json
import os
import sys
import time
from pathlib import Path

import browser_cookie3
from curl_cffi import requests

POLL_INTERVAL_S = 300  # 5 min — comfortably under score-status.sh's 1200s staleness cutoff
CLAUDE_DOMAIN = "claude.ai"
CLAUDE_DIR = Path.home() / ".claude" / "projects"
CACHE_DIR = Path.home() / ".cache" / "rabble"
LATEST_FILE = CACHE_DIR / "llm-usage-latest.json"
LOG_FILE = CACHE_DIR / "llm-usage-api-poll.log"

# Same regression-sample log score-usage-log.sh writes to — score-usage-fit.py
# reads from here to fit token→% coefficients per model/token-type.
REG_LOG_FILE = CACHE_DIR / "llm-usage-log.jsonl"

TOKEN_TYPES = ("input", "cache_creation", "cache_read", "output")

BASE_HEADERS = {
    "Referer": "https://claude.ai/chats",
    "Origin": "https://claude.ai",
    "Accept": "application/json, text/plain, */*",
}

# Map Anthropic's window keys -> the labels score-status.sh's OBS_FILE expects
WINDOW_MAP = {"five_hour": "5h", "seven_day": "week"}


def log(msg: str) -> None:
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(line, flush=True)
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def _firefox_xdg_fallback(domain: str):
    """browser_cookie3 doesn't check ~/.config/mozilla/firefox (XDG layout
    used by Fedora/Arch/etc.) — locate cookies.sqlite ourselves."""
    xdg_dir = os.path.expanduser("~/.config/mozilla/firefox")
    if not os.path.isdir(xdg_dir):
        return None
    try:
        profile_path = browser_cookie3.Firefox.get_default_profile(xdg_dir)
        cookie_files = glob.glob(os.path.join(profile_path, "cookies.sqlite"))
        if cookie_files:
            return browser_cookie3.firefox(cookie_file=cookie_files[0], domain_name=domain)
    except Exception:
        return None
    return None


def load_claude_cookies() -> dict:
    try:
        cj = browser_cookie3.firefox(domain_name=CLAUDE_DOMAIN)
        cookies = {c.name: c.value for c in cj}
    except Exception:
        cookies = {}

    if not cookies:
        cj = _firefox_xdg_fallback(CLAUDE_DOMAIN)
        if cj is not None:
            cookies = {c.name: c.value for c in cj}

    if not cookies:
        raise RuntimeError(
            "No claude.ai cookies found in Firefox — make sure you're logged "
            "in at https://claude.ai in this browser."
        )
    return cookies


def fetch_usage() -> dict:
    cookies = load_claude_cookies()
    org_id = cookies.get("lastActiveOrg")
    if not org_id:
        raise RuntimeError(
            "Missing 'lastActiveOrg' cookie — refresh claude.ai in Firefox "
            "(or switch organizations) so the cookie gets set, then retry."
        )

    url = f"https://{CLAUDE_DOMAIN}/api/organizations/{org_id}/usage"
    last_error = None
    for attempt in range(2):
        try:
            resp = requests.get(
                url, cookies=cookies, headers=BASE_HEADERS,
                impersonate="chrome", timeout=10,
            )
            if resp.status_code == 403:
                raise RuntimeError("403 Forbidden — session cookie may be stale; refresh claude.ai")
            resp.raise_for_status()
            return resp.json()
        except Exception as e:
            last_error = e
            if attempt == 0:
                time.sleep(2)
                continue
    raise RuntimeError(f"usage request failed: {last_error}")


def count_tokens_by_model(since_ts: float) -> dict:
    """Per-model token breakdown for everything Claude Code has spent since
    `since_ts` — the same shape score-usage-log.sh records, so score-usage-fit.py
    can fit on either source interchangeably."""
    import datetime

    models: dict[str, dict[str, int]] = {}
    if not CLAUDE_DIR.exists():
        return models

    cutoff = since_ts - 60
    for jl in CLAUDE_DIR.rglob("*.jsonl"):
        try:
            if jl.stat().st_mtime < cutoff:
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
                                str(ts_raw).replace("Z", "+00:00")
                            ).timestamp()
                        except Exception:
                            pass
                    if ts < since_ts:
                        continue

                    msg = entry.get("message", {})
                    usage = msg.get("usage") or entry.get("usage") or {}
                    if not usage:
                        continue

                    model = msg.get("model", "unknown")
                    m = models.setdefault(model, {t: 0 for t in TOKEN_TYPES})
                    m["input"] += usage.get("input_tokens", 0)
                    m["cache_creation"] += usage.get("cache_creation_input_tokens", 0)
                    m["cache_read"] += usage.get("cache_read_input_tokens", 0)
                    m["output"] += usage.get("output_tokens", 0)
        except Exception:
            continue

    return {m: v for m, v in models.items() if any(v.values())}


def append_regression_sample(window_label: str, pct: float, window_start, resets_at) -> None:
    """Append a (cumulative tokens-since-window-start, official %) sample to
    the same log score-usage-fit.py already fits on. Unlike the old manual
    score-usage-log.sh entries — sparse, single-point-in-time, and requiring you
    to flag whether web chat was "contaminating" the sample — these arrive
    automatically every poll, are anchored to Anthropic's own window-start
    (not a guess), and (critically) are NOT pre-judged as clean/mixed: with a
    continuous series, the fitter can instead look at consecutive deltas and
    let whatever % isn't explained by CC token deltas reveal itself as the
    web/other contribution for that interval — no manual flagging needed.
    """
    if window_start is None:
        return

    models = count_tokens_by_model(window_start)
    row = {
        "ts": time.time(),
        "date": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "window": window_label,
        "pct": pct,
        "window_start": window_start,
        "resets_at": resets_at,
        "source": "api-poll",
        "models": models,
    }
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        with open(REG_LOG_FILE, "a") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    except OSError as e:
        log(f"WARN: failed to append regression sample: {e}")


WINDOW_LENGTHS_S = {"5h": 18000, "week": 604800}


def _resets_at_epoch(raw_reset):
    if not raw_reset:
        return None
    try:
        import datetime
        if isinstance(raw_reset, str):
            return datetime.datetime.fromisoformat(raw_reset.replace("Z", "+00:00")).timestamp()
        return float(raw_reset)
    except Exception:
        return None


def write_observation(usage: dict) -> None:
    now = time.time()

    latest = {}
    if LATEST_FILE.exists():
        try:
            latest = json.loads(LATEST_FILE.read_text())
        except (OSError, json.JSONDecodeError):
            latest = {}

    summary = []
    for api_key, obs_label in WINDOW_MAP.items():
        window = usage.get(api_key) or {}
        pct = window.get("utilization")
        if pct is None:
            continue
        pct = float(pct)
        raw_reset = window.get("resets_at")
        latest[obs_label] = {
            "ts": now,
            "date": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "pct": pct,
            "web_used": True,
            "source": "api",
            "resets_at": raw_reset,
        }
        summary.append(f"{obs_label}={pct:g}%")

        # Feed the regression log: anchor "tokens since window start" to
        # Anthropic's own resets_at (window_start = resets_at - length), not
        # a guess — so the fitter compares official % against the exact same
        # span the meter is measuring.
        reset_epoch = _resets_at_epoch(raw_reset)
        window_len = WINDOW_LENGTHS_S.get(obs_label)
        if reset_epoch is not None and window_len is not None:
            window_start = reset_epoch - window_len
            if window_start <= now:
                append_regression_sample(obs_label, pct, window_start, raw_reset)

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    LATEST_FILE.write_text(json.dumps(latest, ensure_ascii=False, indent=2) + "\n")
    log(f"wrote observation: {', '.join(summary) or 'no windows in response'}")


def main() -> None:
    once = "--once" in sys.argv[1:]
    log("llm-usage-api-poll starting" + (" (--once)" if once else f" (interval {POLL_INTERVAL_S}s)"))
    while True:
        try:
            usage = fetch_usage()
            write_observation(usage)
        except Exception as e:
            log(f"ERROR: {e}")
        if once:
            return
        time.sleep(POLL_INTERVAL_S)


if __name__ == "__main__":
    main()
