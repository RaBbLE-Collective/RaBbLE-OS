#!/usr/bin/env python3
"""
spells/generate-kickstart.py — manifest → KS %packages block

Reads ansible/packages/manifest.yml and prints the %packages block
for inclusion in RaBbLE-OS.ks.

Usage:
  python3 spells/generate-kickstart.py
  python3 spells/generate-kickstart.py --platform generic_x64
  python3 spells/generate-kickstart.py --all          # include ks:false packages too
  python3 spells/generate-kickstart.py --show-skipped # explain why packages were omitted
"""

import yaml
import sys
import argparse
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(
        description="Generate KS %%packages block from manifest.yml"
    )
    parser.add_argument(
        "--manifest",
        default="ansible/packages/manifest.yml",
        help="Path to manifest.yml (default: ansible/packages/manifest.yml)",
    )
    parser.add_argument(
        "--platform",
        default="all",
        choices=["all", "generic_x64", "asus_proart_p16"],
        help="Target platform filter (default: all — includes platform:all packages only)",
    )
    parser.add_argument(
        "--all",
        dest="include_all",
        action="store_true",
        help="Include packages with ks:false (for reference/full installs)",
    )
    parser.add_argument(
        "--show-skipped",
        action="store_true",
        help="Print skipped packages and reasons to stderr",
    )
    args = parser.parse_args()

    script_dir = Path(__file__).parent
    manifest_path = script_dir.parent / args.manifest

    if not manifest_path.exists():
        print(f"ERROR: manifest not found: {manifest_path}", file=sys.stderr)
        sys.exit(1)

    with open(manifest_path) as f:
        data = yaml.safe_load(f)

    packages = []
    skipped = []

    for pkg in data.get("packages", []):
        name = pkg["name"]
        ks_flag = pkg.get("ks", False)
        platform = pkg.get("platform", "all")
        source = pkg.get("source", "fedora")

        # Platform filter: include if platform is "all" or matches requested platform
        if platform != "all" and platform != args.platform:
            skipped.append((name, f"platform={platform} (targeting {args.platform})"))
            continue

        # Skip non-Fedora sources — COPR/rpmfusion not available in KS %packages
        if source.startswith("copr:") or source.startswith("rpmfusion"):
            skipped.append((name, f"source={source} (COPR/rpmfusion not in KS)"))
            continue

        # Honor ks: flag unless --all
        if not ks_flag and not args.include_all:
            skipped.append((name, "ks:false"))
            continue

        packages.append(name)

    if args.show_skipped:
        for name, reason in skipped:
            print(f"# SKIPPED: {name} — {reason}", file=sys.stderr)

    print("%packages")
    # @core, not @^minimal-environment — Fedora 44 comps groups changed
    # (see Grimoire RaBbLE-OS-AgentGuide.md, Kickstart lessons)
    print("@core")
    for pkg in sorted(set(packages)):
        print(pkg)
    print("%end")


if __name__ == "__main__":
    main()
