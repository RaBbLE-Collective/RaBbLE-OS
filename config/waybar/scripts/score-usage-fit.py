#!/usr/bin/env python3
"""
score-usage-fit.py — Fit a token→usage% formula from logged observations.

Reads ~/.cache/rabble/llm-usage-log.jsonl (written by score-usage-log.sh, one
JSON row per observation: window, observed pct, per-model token breakdown)
and runs a least-squares regression per window (5h / week — each has its own
rolling limit, so they can't share one fit).

Model:  observed_pct ≈ Σ over (model, token_type) of  c[model,type] * tokens

Each fitted coefficient c already bakes together "cost per token of this type"
and "100 / window limit" — which is exactly what's needed to predict %, so the
raw coefficients ARE the tunable formula. We additionally normalize them
against Sonnet's input coefficient (defined as 1.0x) to print interpretable
"model multipliers" and "input/cache/output contribution" ratios, since that's
the form Anthropic talks about its own limits in.

Usage:
    score-usage-fit.py            # fit + report using all logged samples
"""

import datetime
import json
import pathlib
import sys
from collections import defaultdict

import numpy as np

try:
    from scipy.optimize import nnls as _nnls
except Exception:
    _nnls = None

CACHE_DIR = pathlib.Path.home() / ".cache" / "rabble"
LOG_FILE = CACHE_DIR / "llm-usage-log.jsonl"
# Fitted coefficients are exported here for other tools (the popup's est %,
# any future bar tooltip) to consume empirical weights instead of the crude
# hardcoded FIVE_H_LIMIT / WEEKLY_LIMIT division in score-status.sh.
COEFFS_FILE = CACHE_DIR / "llm-usage-coeffs.json"

TOKEN_TYPES = ("input", "cache_creation", "cache_read", "output")
BASELINE_MODEL = "claude-sonnet-4-6"
BASELINE_TYPE  = "input"


def _is_quota_model(model: str) -> bool:
    """Only Anthropic models draw on the Claude quota the % meter tracks.
    sCoRE's OpenRouter providers (deepseek/llama/nvidia/mistral/...) spend no
    Anthropic quota, so their token deltas are noise regressors — including
    them wrecks the fit (e.g. an 'nvidia output = 54.8 %/token' coefficient).
    Filter them out so the regression only explains real Anthropic spend."""
    return model.startswith("claude-")


def _solve(X, y):
    """Non-negative least squares when scipy is present (token costs can't be
    negative — a negative coefficient is non-physical and a sign of noise),
    else fall back to plain lstsq. Returns (coeffs, rank)."""
    if _nnls is not None:
        coeffs, _ = _nnls(X, y)
        rank = int(np.linalg.matrix_rank(X))
        return coeffs, rank
    coeffs, _res, rank, _ = np.linalg.lstsq(X, y, rcond=None)
    return coeffs, int(rank)


def load_rows():
    if not LOG_FILE.exists():
        return []
    rows = []
    with open(LOG_FILE) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


def fit_window_deltas(rows, window_label):
    """Fit on consecutive-poll deltas from the automatic API-poll log.

    Why deltas instead of absolute (tokens-since-reset, pct) pairs: the old
    approach (fit_window below) needed you to manually flag whether claude.ai
    web chat was active during each sample ("clean" vs "--web mixed"), because
    a single absolute sample can't separate "CC tokens explain this %" from
    "web chat also ran in the background". A continuous series sidesteps that
    entirely — for each short interval between polls we know exactly how many
    CC tokens were spent (Δtokens) and exactly how much the official % moved
    (Δpct). Whatever Δpct isn't explained by Δtokens in THAT interval must
    have come from something else (web chat, other clients) — no flag needed,
    it falls out of the residual automatically, interval by interval.

    Samples are grouped by `window_start` (each group = one reset-to-reset
    instance of the window) so deltas never straddle a reset, where pct drops
    back toward zero and would otherwise look like a huge negative cost.
    """
    samples = [r for r in rows
               if r.get("window") == window_label
               and r.get("source") == "api-poll"
               and r.get("models")
               and r.get("window_start") is not None]

    if len(samples) < 3:
        print(f"  not enough api-poll samples for '{window_label}' yet "
              f"(have {len(samples)}, need ≥3 to form ≥2 deltas) — "
              f"the poller logs one every ~5 minutes, just let it run")
        return None

    by_epoch = defaultdict(list)
    for s in samples:
        by_epoch[round(s["window_start"])].append(s)

    features_set = {
        (model, ttype)
        for s in samples
        for model, counts in s["models"].items()
        for ttype in TOKEN_TYPES
        if counts.get(ttype, 0) > 0 and _is_quota_model(model)
    }
    features = sorted(features_set)
    if not features:
        print(f"  no non-zero token features for '{window_label}'")
        return None

    def vec(models):
        return np.array([models.get(m, {}).get(t, 0) for (m, t) in features], dtype=float)

    X_rows, y_rows, residual_meta = [], [], []
    for epoch_start, group in by_epoch.items():
        group.sort(key=lambda s: s["ts"])
        for prev, cur in zip(group, group[1:]):
            d_pct = cur["pct"] - prev["pct"]
            d_tok = vec(cur["models"]) - vec(prev["models"])
            # Skip pairs straddling a reset (pct drops, tokens "shrink"
            # because the new epoch's window_start moved) or with no token
            # movement (degenerate — every model/type delta would be 0).
            if d_pct < 0 or np.any(d_tok < 0) or not np.any(d_tok):
                continue
            X_rows.append(d_tok)
            y_rows.append(d_pct)
            residual_meta.append((cur.get("date", "?"), d_pct))

    if len(X_rows) < 2:
        print(f"  not enough usable deltas for '{window_label}' yet "
              f"(have {len(X_rows)}, need ≥2) — keep the poller running")
        return None

    X = np.array(X_rows)
    y = np.array(y_rows)

    coeffs, rank = _solve(X, y)
    pred = X @ coeffs
    errs = pred - y
    rmse = float(np.sqrt(np.mean(errs ** 2)))

    method = "nnls" if _nnls is not None else "lstsq"
    print(f"  {len(samples)} sample(s) across {len(by_epoch)} window-instance(s) "
          f"→ {len(X_rows)} usable delta(s), rank {rank}/{len(features)} features, "
          f"RMSE {rmse:.3f} pct-points/interval  [{method}, Anthropic-only]")
    print(f"  fitted formula  Δpct ≈ Σ c[model,type] · Δtokens   (paste these as the tuned weights):")
    for (model, ttype), c in zip(features, coeffs):
        print(f"    c[{model:<22} {ttype:<14}] = {c:.6e}")

    baseline_c = next((c for (m, t), c in zip(features, coeffs)
                       if m == BASELINE_MODEL and t == BASELINE_TYPE), None)
    if baseline_c and abs(baseline_c) > 1e-12:
        print(f"\n  normalized to {BASELINE_MODEL} {BASELINE_TYPE} = 1.0x:")
        by_model = defaultdict(dict)
        for (model, ttype), c in zip(features, coeffs):
            by_model[model][ttype] = c / baseline_c
        for model, types in by_model.items():
            parts = ", ".join(f"{t}={v:.2f}x" for t, v in types.items())
            print(f"    {model:<22} {parts}")
            if "input" in types and "output" in types and types["input"]:
                print(f"      → output costs ~{types['output']/types['input']:.1f}x its input within this model")

    # Per-interval residual: the slice of each Δpct the CC token deltas don't
    # explain — i.e. usage from claude.ai web chat or any other client that
    # leaves no trace in ~/.claude/projects. Summed up, this is a direct,
    # ongoing read on "how much of my quota goes to places I can't see".
    web_total = float(np.sum(errs))
    cc_total = float(np.sum(pred))
    observed_total = float(np.sum(y))
    print(f"\n  understanding spend over the {len(X_rows)} observed interval(s):")
    print(f"    total Δ% observed         : {observed_total:+.1f}pp")
    print(f"    Δ% explained by CC tokens : {cc_total:+.1f}pp ({100*cc_total/observed_total:.0f}% of total)" if observed_total else "")
    print(f"    Δ% unexplained (web/other): {web_total:+.1f}pp ({100*web_total/observed_total:.0f}% of total)" if observed_total else "")
    biggest = sorted(zip(residual_meta, errs), key=lambda x: abs(x[1]), reverse=True)[:3]
    if biggest:
        print(f"    largest unexplained jumps:")
        for (date, d_pct), err in biggest:
            print(f"      {date:<22} Δ%={d_pct:+.2f}pp  unexplained ≈ {err:+.2f}pp")

    # Coefficient table for export: {model: {token_type: %-per-token}}
    coeff_table = defaultdict(dict)
    for (model, ttype), c in zip(features, coeffs):
        coeff_table[model][ttype] = float(c)
    return {
        "method": "nnls-delta" if _nnls is not None else "lstsq-delta",
        "n_samples": len(samples),
        "n_deltas": len(X_rows),
        "rank": int(rank),
        "rmse_pp": round(rmse, 4),
        "coeffs": dict(coeff_table),
    }


def fit_window(rows, window_label):
    all_samples = [r for r in rows if r.get("window") == window_label and r.get("models")]
    samples = [s for s in all_samples if not s.get("web_used")]
    mixed   = [s for s in all_samples if s.get("web_used")]

    if mixed:
        print(f"  excluding {len(mixed)} web-contaminated sample(s) from the fit "
              f"(web chat draws on the same pool but leaves no local token trace —")
        print(f"  including them would wrongly attribute web-driven % moves to CC tokens)")

    if len(samples) < 2:
        print(f"  not enough CLEAN (CC-only) samples for '{window_label}' "
              f"(have {len(samples)}, need ≥2) — keep logging with score-usage-log.sh (no --web)")
        return

    # Stable, sorted feature ordering: (model, token_type)
    features = sorted({
        (model, ttype)
        for s in samples
        for model, counts in s["models"].items()
        for ttype in TOKEN_TYPES
        if counts.get(ttype, 0) > 0 and _is_quota_model(model)
    })

    if not features:
        print(f"  no non-zero token features for '{window_label}'")
        return

    X = np.array([
        [s["models"].get(model, {}).get(ttype, 0) for (model, ttype) in features]
        for s in samples
    ], dtype=float)
    y = np.array([s["pct"] for s in samples], dtype=float)

    # Non-negative least squares would be more correct (token costs can't be
    # negative), but plain lstsq is fine to start tuning with — coefficients
    # going negative is itself a signal you need more/better samples.
    coeffs, residuals, rank, _ = np.linalg.lstsq(X, y, rcond=None)

    pred = X @ coeffs
    errs = pred - y
    rmse = float(np.sqrt(np.mean(errs ** 2)))

    print(f"  {len(samples)} sample(s), rank {rank}/{len(features)} features, RMSE {rmse:.2f} pct-points")
    print(f"  fitted formula  pct ≈ Σ c[model,type] · tokens   (paste these as the tuned weights):")
    for (model, ttype), c in zip(features, coeffs):
        print(f"    c[{model:<22} {ttype:<14}] = {c:.6e}")

    # Normalize against baseline (Sonnet input = 1.0x) for interpretability
    baseline_c = next((c for (m, t), c in zip(features, coeffs)
                       if m == BASELINE_MODEL and t == BASELINE_TYPE), None)
    if baseline_c and abs(baseline_c) > 1e-12:
        print(f"\n  normalized to {BASELINE_MODEL} {BASELINE_TYPE} = 1.0x:")
        by_model = defaultdict(dict)
        for (model, ttype), c in zip(features, coeffs):
            by_model[model][ttype] = c / baseline_c
        for model, types in by_model.items():
            parts = ", ".join(f"{t}={v:.2f}x" for t, v in types.items())
            print(f"    {model:<22} {parts}")
            if "input" in types and "output" in types and types["input"]:
                print(f"      → output costs ~{types['output']/types['input']:.1f}x its input within this model")
        if BASELINE_MODEL in by_model:
            base_total = sum(by_model[BASELINE_MODEL].values())
            for model, types in by_model.items():
                if model == BASELINE_MODEL:
                    continue
                tot = sum(types.values())
                if base_total:
                    print(f"      → {model} overall multiplier vs {BASELINE_MODEL} ≈ {tot/base_total:.2f}x")
    else:
        print(f"\n  (no {BASELINE_MODEL}/{BASELINE_TYPE} samples yet — can't normalize to a baseline)")

    # Score the web-contaminated samples against the clean fit: whatever %
    # the CC tokens alone don't explain is our best estimate of what the
    # invisible web-chat usage cost — the only way to size that "hole".
    if mixed:
        print(f"\n  estimated web-driven contribution (observed % − CC-only prediction):")
        for s in mixed:
            x = np.array([s["models"].get(model, {}).get(ttype, 0) for (model, ttype) in features], dtype=float)
            cc_pred = float(x @ coeffs)
            web_est = s["pct"] - cc_pred
            print(f"    {s.get('date', '?'):<22} observed {s['pct']:.1f}%  "
                  f"CC-explains ~{cc_pred:.1f}%  → web ≈ {web_est:+.1f}pp")


def main():
    rows = load_rows()
    if not rows:
        print(f"No observations logged yet. Record some with:")
        print(f"  score-usage-log.sh 5h <pct>")
        print(f"  score-usage-log.sh week <pct>")
        print(f"(read <pct> off the Claude web usage meter when you run it)")
        return

    api_poll_rows = [r for r in rows if r.get("source") == "api-poll"]
    manual_rows   = [r for r in rows if r.get("source") != "api-poll"]

    print(f"Loaded {len(rows)} observation(s) from {LOG_FILE} "
          f"({len(api_poll_rows)} automatic api-poll, {len(manual_rows)} manual)\n")

    exported = {}
    if api_poll_rows:
        print(f"═══ Delta fit — automatic api-poll samples (preferred) ═══════")
        for window_label in ("5h", "week"):
            print(f"── {window_label} window ──────────────────────────────────────")
            result = fit_window_deltas(rows, window_label)
            if result:
                exported[window_label] = result
            print()

    if exported:
        payload = {
            "generated": datetime.datetime.now().isoformat(timespec="seconds"),
            "source": str(LOG_FILE),
            "note": ("%-per-token coefficients per Anthropic model/token-type. "
                     "predicted_pct = Σ coeff[model][type] · tokens. Non-Anthropic "
                     "(OpenRouter) models are excluded — they spend no Claude quota."),
            "windows": exported,
        }
        try:
            COEFFS_FILE.write_text(json.dumps(payload, indent=2))
            print(f"→ exported fitted coefficients to {COEFFS_FILE}\n")
        except OSError as e:
            print(f"  (could not write {COEFFS_FILE}: {e})\n")

    if manual_rows:
        print(f"═══ Absolute fit — manually logged samples (legacy) ═══════════")
        for window_label in ("5h", "week"):
            print(f"── {window_label} window ──────────────────────────────────────")
            fit_window(manual_rows, window_label)
            print()


if __name__ == "__main__":
    sys.exit(main())
