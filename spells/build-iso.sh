#!/usr/bin/env bash
# ==============================================================================
# spells/build-iso.sh — bake RaBbLE-OS.ks into a bootable RaBbLE-OS netinstall ISO
#
# Renders the bare-metal variant of RaBbLE-OS.ks (branch filled in, #@VM@ lines
# left commented so disk/user/WiFi stay interactive), validates it, then uses
# mkksiso (lorax — installed by the virtualization layer) to embed it in a stock
# Fedora netinstall ISO. The result boots straight into the KS: no OEMDRV
# partition, no ks.cfg renaming, no boot-line editing.
#
# Usage:
#   spells/build-iso.sh [--branch <name>] [--out <path>] <fedora-netinst.iso>
#
# Example:
#   spells/build-iso.sh ISO/Fedora-Everything-netinst-x86_64-44-1.7.iso
#   → ISO/RaBbLE-OS-new-horizons.iso
#
# Flash with Fedora Media Writer or dd. Ventoy is untested with an embedded KS
# (it re-hosts the ISO, and the KS is found by volume label) — prefer a plain flash.
# ==============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KS_SRC="${REPO_DIR}/RaBbLE-OS.ks"

info()  { echo -e "\033[0;36m[build-iso]\033[0m $*"; }
error() { echo -e "\033[0;31m[build-iso]\033[0m $*" >&2; exit 1; }

branch="" out="" iso=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch) branch="${2:?--branch needs a name}"; shift 2 ;;
        --out)    out="${2:?--out needs a path}";       shift 2 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)        iso="$1"; shift ;;
    esac
done

[[ -n "$iso" ]]   || error "Usage: $0 [--branch <name>] [--out <path>] <fedora-netinst.iso>"
[[ -f "$iso" ]]   || error "ISO not found: $iso"
[[ -f "$KS_SRC" ]] || error "KS not found: $KS_SRC"
command -v mkksiso &>/dev/null || \
    error "mkksiso not found (lorax). Install via: ./RaBbLE-OS-layerctl.sh apply virtualization"

if [[ -z "$branch" ]]; then
    branch="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    [[ -z "$branch" || "$branch" == "HEAD" ]] && branch="new-horizons"
fi
[[ -n "$out" ]] || out="$(dirname "$iso")/RaBbLE-OS-${branch//\//-}.iso"

# The installed system clones from GitHub, not this checkout — warn if unpushed.
if git -C "$REPO_DIR" rev-parse "origin/${branch}" &>/dev/null; then
    ahead="$(git -C "$REPO_DIR" rev-list --count "origin/${branch}..HEAD" 2>/dev/null || echo 0)"
    (( ahead > 0 )) && info "WARNING: ${ahead} local commit(s) not on origin/${branch} — the install won't see them."
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ks="${work}/ks.cfg"

sed -e "s|__RABBLE_BRANCH__|${branch}|g" "$KS_SRC" > "$ks"

info "Validating rendered KS..."
python3 - "$ks" <<'PYEOF' || error "KS failed validation."
import sys
from pykickstart.parser import KickstartParser
from pykickstart.version import makeVersion
KickstartParser(makeVersion()).readKickstart(sys.argv[1])
print("  ok")
PYEOF

info "Base ISO: $iso"
info "Branch:   $branch"
info "Output:   $out"
rm -f "$out"
# mkksiso rebuilds images/efiboot.img (mkefiboot, needs root) so the inst.ks
# arg also lands in the ESP's grub.cfg — UEFI USB boots read that copy, so
# --skip-mkefiboot would silently boot without the KS. Only this step is sudo.
SUDO=""; (( EUID == 0 )) || SUDO="sudo"
$SUDO mkksiso --ks "$ks" "$iso" "$out"
[[ -n "$SUDO" ]] && sudo chown "$(id -u):$(id -g)" "$out"

info "Done: $out"
info "Flash it, boot it, then: pick the disk, create your user (tick 'administrator'),"
info "join WiFi if needed. Bootstrap runs before the reboot (Alt+F2 →"
info "tail -f /mnt/sysroot/var/log/rabble-os-install.log). Pull the USB at reboot."
