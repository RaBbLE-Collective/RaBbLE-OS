#!/usr/bin/env python3
"""score_pricing.py — shared dollar-cost helper for the sCoRE usage tracker.

Single source of truth is score-pricing.json (sibling file): published Claude
API list prices in USD per million tokens. Consumers (score-usage-detail.py
popup, score-token-viz.py builder) import this module to turn raw per-model
token counts into dev-pricing dollar estimates.

These are *list-price API* estimates — what the same usage WOULD cost on the
pay-as-you-go API. They are not what a Claude Pro/Max subscription bills (that
is a flat seat price metered as a quota %, which the web observations track).
The dollar figure answers "how much compute am I actually spending", which the
quota % alone can't, since it hides the model mix and the in/out split.
"""

import json
import pathlib

_PRICING_PATH = pathlib.Path(__file__).resolve().parent / "score-pricing.json"

# Conservative fallback (Sonnet-tier) if the JSON is missing/unreadable, so a
# consumer never crashes just because the config moved.
_FALLBACK = {
    "cache_read_mult": 0.1,
    "cache_write_mult": 1.25,
    "models": {},
    "default": {"input": 3.0, "output": 15.0},
}

_cache = None


def load(refresh: bool = False) -> dict:
    """Load and memoize the pricing table. Never raises."""
    global _cache
    if _cache is not None and not refresh:
        return _cache
    try:
        _cache = json.loads(_PRICING_PATH.read_text())
        _cache.setdefault("models", {})
        _cache.setdefault("default", _FALLBACK["default"])
        _cache.setdefault("cache_read_mult", _FALLBACK["cache_read_mult"])
        _cache.setdefault("cache_write_mult", _FALLBACK["cache_write_mult"])
    except (OSError, ValueError):
        _cache = dict(_FALLBACK)
    return _cache


def rates_for(model: str, pricing: dict | None = None) -> dict:
    """Return {input, output} $/MTok for a short model name (e.g. 'opus-4-8').
    Unknown models fall back to the configured default."""
    p = pricing or load()
    return p["models"].get(model, p["default"])


def cost(model: str, inp: int = 0, out: int = 0, cache_read: int = 0,
         cache_write: int = 0, pricing: dict | None = None) -> float:
    """Dollar cost for one model's token counts. inp = NON-cached input
    (tokens down), out = output (tokens up), cache_read/cache_write priced as
    multiples of the model's input rate."""
    p = pricing or load()
    r = rates_for(model, p)
    in_rate = r["input"]
    return (
        inp * in_rate
        + out * r["output"]
        + cache_read * in_rate * p["cache_read_mult"]
        + cache_write * in_rate * p["cache_write_mult"]
    ) / 1_000_000.0


def fmt_usd(amount: float) -> str:
    """Compact dollar formatting for narrow bar/popup columns."""
    if amount >= 100:
        return f"${amount:,.0f}"
    if amount >= 1:
        return f"${amount:.2f}"
    if amount >= 0.01:
        return f"${amount:.2f}"
    if amount > 0:
        return f"${amount:.3f}"
    return "$0"
