#!/usr/bin/env bash
# edition-audit.sh — every manifest entry must carry a valid `edition:`.
# Prints per-edition counts (packages visible in each edition). Exit 1 on any gap.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest="${1:-$here/../ansible/packages/manifest.yml}"
python3 -I - "$manifest" <<'PY'
import sys, yaml
pk = yaml.safe_load(open(sys.argv[1]))["packages"]
rank = {"core": 0, "user": 1, "dev": 2, "creative": 2}
bad = [p["name"] for p in pk if p.get("edition") not in rank]
if bad:
    print(f"FAIL: {len(bad)} entries missing/invalid edition: {', '.join(bad)}")
    sys.exit(1)
inc = {"core": {"core"}, "user": {"core", "user"}, "dev": {"core", "user", "dev"},
       "creative": {"core", "user", "creative"}}
def has(ed, e):
    return ed == "full" or e in inc[ed]
for ed in ("core", "user", "dev", "creative", "full"):
    print(f"{ed:9} {sum(has(ed, p['edition']) for p in pk):4} packages")
print(f"OK: {len(pk)} entries, all have edition")
PY
