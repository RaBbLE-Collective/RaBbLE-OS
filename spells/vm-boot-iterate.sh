#!/usr/bin/env bash
# vm-boot-iterate.sh — tight boot-theme dev loop for RaBbLE-OS
#
# Syncs working-tree ansible/roles/boot/ to the dev VM, applies the boot
# layer, reboots, and captures the GRUB→Plymouth→SDDM sequence via
# virsh screenshot. Saves frames to BaBbLE/captures/Boot/vm-<timestamp>/.
#
# Usage:
#   ./spells/vm-boot-iterate.sh                 full loop: sync→apply→reboot→capture
#   ./spells/vm-boot-iterate.sh --no-reboot     sync+apply only (no reboot or capture)
#   ./spells/vm-boot-iterate.sh --capture-only  screenshot loop (VM already rebooting)
#   ./spells/vm-boot-iterate.sh --restore       revert boot-clean first, then full loop
#
# Tuning env vars:
#   RABBLE_CAPTURE_SECS=45   seconds of screenshots (default 45 — covers full boot)
#   RABBLE_VM_NAME=foo        override VM name (default rabble-os-dev)
#   RABBLE_VM_SNAPSHOT=name   override clean snapshot name (default boot-clean)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
COLLECTIVE_DIR="$(dirname "$REPO_DIR")"

VM_NAME="${RABBLE_VM_NAME:-rabble-os-dev}"
VM_SNAPSHOT="${RABBLE_VM_SNAPSHOT:-boot-clean}"
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

GUEST_REPO="/home/rabble/RaBbLE/RaBbLE-OS"
SSH_USER="rabble"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

CAPTURES_DIR="${COLLECTIVE_DIR}/BaBbLE/captures/Boot"
CAPTURE_SECS="${RABBLE_CAPTURE_SECS:-45}"

RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m';     RESET='\033[0m'

info()    { echo -e "${CYAN}[boot-iter]${RESET}  $*"; }
success() { echo -e "${GREEN}[boot-iter]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[boot-iter]${RESET}  $*" >&2; }
error()   { echo -e "${RED}[boot-iter]${RESET}  $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}── $* ──${RESET}"; }

# ── Flags ──────────────────────────────────────────────────────────────────────
DO_SYNC=true
DO_APPLY=true
DO_REBOOT=true
DO_CAPTURE=true
DO_RESTORE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-reboot)    DO_REBOOT=false; DO_CAPTURE=false ;;
        --capture-only) DO_SYNC=false; DO_APPLY=false; DO_REBOOT=false ;;
        --restore)      DO_RESTORE=true ;;
        --help|-h)
            sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
            exit 0 ;;
        *) error "Unknown flag: $1" ;;
    esac
    shift
done

# ── Helpers ────────────────────────────────────────────────────────────────────
vm_ip() {
    local mac
    mac=$(virsh domiflist "$VM_NAME" 2>/dev/null | awk '/virtio/{print $5}')
    [[ -z "$mac" ]] && return 1
    virsh net-dhcp-leases default 2>/dev/null \
        | awk -v m="$mac" '$3==m {gsub(/\/.*/, "", $5); print $5; exit}'
}

vm_running() { virsh domstate "$VM_NAME" 2>/dev/null | grep -q "running"; }

wait_for_ssh() {
    local ip="$1" label="${2:-VM}" deadline=$(( SECONDS + 120 ))
    info "Waiting for SSH on ${label} (${ip})..."
    while (( SECONDS < deadline )); do
        # shellcheck disable=SC2086
        ssh $SSH_OPTS -o ConnectTimeout=3 -q "${SSH_USER}@${ip}" true 2>/dev/null && return 0
        sleep 3
    done
    error "SSH timeout after 120s waiting for ${ip}"
}

# ── Deps ───────────────────────────────────────────────────────────────────────
for cmd in virsh rsync ssh; do
    command -v "$cmd" &>/dev/null || error "Missing dependency: $cmd"
done

# ── Restore snapshot ───────────────────────────────────────────────────────────
if $DO_RESTORE; then
    section "Restoring snapshot '${VM_SNAPSHOT}'"
    virsh snapshot-list "$VM_NAME" --name 2>/dev/null | grep -qF "$VM_SNAPSHOT" \
        || error "Snapshot '${VM_SNAPSHOT}' not found.
  Create it at the SDDM greeter:
    LIBVIRT_DEFAULT_URI=qemu:///system virsh snapshot-create-as ${VM_NAME} ${VM_SNAPSHOT} --atomic"
    vm_running && virsh destroy "$VM_NAME" 2>/dev/null || true
    virsh snapshot-revert "$VM_NAME" --snapshotname "$VM_SNAPSHOT"
    virsh start "$VM_NAME"
    success "Reverted to '${VM_SNAPSHOT}' and started VM."
fi

# ── Get IP (needed for sync / apply / reboot) ──────────────────────────────────
if $DO_SYNC || $DO_APPLY || $DO_REBOOT; then
    vm_running || error "VM '${VM_NAME}' is not running.
  Start it:       LIBVIRT_DEFAULT_URI=qemu:///system virsh start ${VM_NAME}
  Or restore:     $0 --restore"

    ip=$(vm_ip)
    [[ -z "$ip" ]] && error "No DHCP lease for '${VM_NAME}' yet. Try again in a few seconds."
    info "VM at ${ip}"

    # After restore the VM needs time to boot before SSH is ready
    if $DO_RESTORE; then
        wait_for_ssh "$ip" "restored VM"
    fi
fi

# ── Sync boot roles ────────────────────────────────────────────────────────────
if $DO_SYNC; then
    section "Syncing ansible/roles/boot/ → guest"
    # shellcheck disable=SC2086
    rsync -az --delete \
        -e "ssh $SSH_OPTS" \
        "${REPO_DIR}/ansible/roles/boot/" \
        "${SSH_USER}@${ip}:${GUEST_REPO}/ansible/roles/boot/"
    success "Boot roles synced."
fi

# ── Apply boot layer ───────────────────────────────────────────────────────────
if $DO_APPLY; then
    section "Applying boot layer on guest"
    $DO_SYNC || wait_for_ssh "$ip" "VM"  # only wait if we didn't just rsync (which implies SSH was up)
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${SSH_USER}@${ip}" \
        "cd ${GUEST_REPO} && sudo ./RaBbLE-OS-layerctl.sh apply boot"
    success "Boot layer applied (grub2-mkconfig + dracut)."
fi

# ── Reboot ─────────────────────────────────────────────────────────────────────
if $DO_REBOOT; then
    section "Rebooting guest"
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${SSH_USER}@${ip}" "sudo reboot" 2>/dev/null || true
    info "Reboot sent. Screenshot loop starting..."
fi

# ── Capture boot sequence ──────────────────────────────────────────────────────
if $DO_CAPTURE; then
    ts=$(date +%Y%m%d-%H%M%S)
    out_dir="${CAPTURES_DIR}/vm-${ts}"
    mkdir -p "$out_dir"

    [[ "$DO_REBOOT" == "false" ]] && section "Capturing boot sequence"
    info "Recording ${CAPTURE_SECS}s → ${out_dir}"
    info "GRUB timeout (~10s) → Plymouth (~15s) → SDDM"

    frame=0
    end_t=$(( SECONDS + CAPTURE_SECS ))
    while (( SECONDS < end_t )); do
        fname="${out_dir}/frame-$(printf '%04d' "$frame").png"
        virsh screenshot "$VM_NAME" --file "$fname" &>/dev/null || true
        frame=$(( frame + 1 ))
        sleep 0.5
    done

    count=$(find "${out_dir}" -name 'frame-*.png' | wc -l)
    last=$(printf '%04d' $(( frame - 1 )))

    echo ""
    success "Captured ${count} frames (${CAPTURE_SECS}s at 2fps)"
    info "Output: ${out_dir}/"
    info "Last frame: ${out_dir}/frame-${last}.png"
    echo ""
    info "Quick review:"
    info "  ls ${out_dir}/"
    info "  eog ${out_dir}/frame-${last}.png          # last frame (should be SDDM)"
    info "  for f in ${out_dir}/frame-*.png; do eog \"\$f\"; done  # slideshow"
fi
