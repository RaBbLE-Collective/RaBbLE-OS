// RaBbLE — Claude usage meter relay (console / DevTools-Snippet version)
//
// No extension needed. Paste into Firefox DevTools console on
// claude.ai/new#settings/usage, or save as a Snippet (DevTools → ... →
// "New Snippet") and run it with one click each time you check usage.
//
// Scans rendered text for "<number>%" near "session"/"week" keywords and
// POSTs readings to the local bridge (llm-usage-bridge.py, loopback only).
// Logs everything it finds — look for "[rabble-usage]" lines to debug
// matching if claude.ai's wording/layout differs from what's expected.

(function () {
    const BRIDGE_URL = 'http://127.0.0.1:8765/log';
    const PCT_RE = /(\d{1,3}(?:\.\d+)?)\s*%/;
    const SESSION_KEYWORDS = /session|5[\s-]?hour|5h/i;
    const WEEK_KEYWORDS = /week|7[\s-]?day/i;

    async function relay(window_, pct) {
        // Reading this FROM claude.ai means web usage is in play for this
        // window by definition — flag it so llm-usage-fit.py keeps it out
        // of the regression and instead uses it to estimate the web-driven
        // contribution against the CC-only baseline.
        console.log(`[rabble-usage] relaying ${window_} = ${pct}% (web_used=true)`);
        try {
            const res = await fetch(BRIDGE_URL, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ window: window_, pct, web_used: true }),
            });
            console.log('[rabble-usage] bridge replied:', await res.json());
        } catch (e) {
            console.warn('[rabble-usage] bridge unreachable (is llm-usage-bridge.py running?)', e);
        }
    }

    function scan() {
        const candidates = [];
        document.querySelectorAll('*').forEach((el) => {
            if (el.children.length > 0) return;
            const text = el.textContent || '';
            const m = text.match(PCT_RE);
            if (!m) return;
            candidates.push({ el, pct: parseFloat(m[1]) });
        });

        if (!candidates.length) {
            console.log('[rabble-usage] no "%" text found on this page — are you on /settings/usage?');
            return;
        }

        for (const { el, pct } of candidates) {
            let ctx = '';
            let node = el;
            for (let i = 0; node && i < 5; i++, node = node.parentElement) {
                ctx += ' ' + (node.textContent || '');
            }
            if (SESSION_KEYWORDS.test(ctx)) {
                relay('5h', pct);
            } else if (WEEK_KEYWORDS.test(ctx)) {
                relay('week', pct);
            } else {
                console.log(`[rabble-usage] unclassified ${pct}% near: "${ctx.trim().slice(0, 80)}…"`);
            }
        }
    }

    scan();
})();
