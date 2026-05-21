#!/usr/bin/env bash
# ==============================================================================
# RaBbLE-OS-vmctl.sh
# VM lifecycle management spell for RaBbLE-OS development VMs
#
# Creates and manages a Fedora KVM VM so Hyprland/Sway can run inside it.
# Use this to test RaBbLE-OS bootstraps without touching the daily driver.
#
# Usage:
#   ./RaBbLE-OS-vmctl.sh setup                 — prepare the host (run once)
#   ./RaBbLE-OS-vmctl.sh cast <iso-path>       — create the VM from a Fedora ISO
#   ./RaBbLE-OS-vmctl.sh status                — show VM status
#   ./RaBbLE-OS-vmctl.sh start                 — start the VM
#   ./RaBbLE-OS-vmctl.sh stop                  — graceful shutdown
#   ./RaBbLE-OS-vmctl.sh connect               — open SPICE display (virt-viewer)
#   ./RaBbLE-OS-vmctl.sh snapshot <name>       — create a named snapshot
#   ./RaBbLE-OS-vmctl.sh restore  <name>       — restore to a named snapshot
#   ./RaBbLE-OS-vmctl.sh snapshots             — list all snapshots
#   ./RaBbLE-OS-vmctl.sh destroy               — delete the VM (prompts for confirmation)
#   ./RaBbLE-OS-vmctl.sh help                  — show this message
#
# Prerequisites:
#   Run the Ansible virtualization role first:
#   ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml -K --tags virtualization
# ==============================================================================
set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
VM_NAME="${RABBLE_VM_NAME:-rabble-os-dev}"
VM_RAM="${RABBLE_VM_RAM:-4096}"             # MB
VM_VCPUS="${RABBLE_VM_VCPUS:-4}"
VM_DISK_SIZE="${RABBLE_VM_DISK_SIZE:-40}"   # GB
VM_PARTITION_LABEL="vm-storage"             # BTRFS partition label for VM images
VM_PARTITION_MOUNT="/mnt/vms"               # Where to mount the VM partition
VM_DISK_DIR="${RABBLE_VM_DISK_DIR:-}"       # Set by detect_vm_partition() if available
LIBVIRT_URI="qemu:///system"
export LIBVIRT_DEFAULT_URI="$LIBVIRT_URI"

# ── Colour palette ─────────────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m';     RESET='\033[0m'

info()    { echo -e "${CYAN}[vmctl]${RESET}  $*"; }
success() { echo -e "${GREEN}[vmctl]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[vmctl]${RESET}  $*" >&2; }
error()   { echo -e "${RED}[vmctl]${RESET}  $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}── $* ──${RESET}"; }

# ── VM partition detection and mounting ───────────────────────────────────────
detect_vm_partition() {
    local device partition_uuid

    # Look for BTRFS partition with vm-storage label
    device=$(lsblk -nlo NAME,LABEL | grep "$VM_PARTITION_LABEL" | awk '{print $1}' | head -1)

    if [[ -z "$device" ]]; then
        # No VM partition found; use default directory
        VM_DISK_DIR="${RABBLE_VM_DISK_DIR:-/var/lib/libvirt/images}"
        return
    fi

    device="/dev/$device"

    # Check if partition is already mounted
    if mountpoint -q "$VM_PARTITION_MOUNT" 2>/dev/null; then
        success "VM partition already mounted at ${VM_PARTITION_MOUNT}"
        VM_DISK_DIR="$VM_PARTITION_MOUNT"
        return
    fi

    # Try to mount it
    info "Detected VM partition: ${device}"
    info "Mounting ${device} to ${VM_PARTITION_MOUNT}..."

    sudo mkdir -p "$VM_PARTITION_MOUNT"
    if sudo mount -L "$VM_PARTITION_LABEL" "$VM_PARTITION_MOUNT" 2>/dev/null; then
        success "VM partition mounted at ${VM_PARTITION_MOUNT}"
        VM_DISK_DIR="$VM_PARTITION_MOUNT"
    else
        warn "Could not mount VM partition. Using default: /var/lib/libvirt/images"
        VM_DISK_DIR="${RABBLE_VM_DISK_DIR:-/var/lib/libvirt/images}"
    fi
}

# ── Dependency check ───────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in virsh virt-install virt-viewer setfacl; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        error "Missing tools: ${missing[*]}\nRun the Ansible virtualization role first:\n  ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml -K --tags virtualization"
    fi
}

# ── VM existence helpers ────────────────────────────────────────────────────────
vm_exists()  { virsh dominfo "$VM_NAME" &>/dev/null; }
vm_running() { virsh domstate "$VM_NAME" 2>/dev/null | grep -q "running"; }

# ── Graphics auto-detect ───────────────────────────────────────────────────────
# virgl 3D needs: non-root, active display session, DRI render node.
# Falls back to software rendering (llvmpipe) silently otherwise.
detect_graphics() {
    if [[ $EUID -eq 0 ]]; then
        warn "Running as root — virgl 3D disabled (no display session); using software rendering."
        echo "spice"
        return
    fi
    if [[ -z "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
        warn "No display session detected — virgl 3D disabled; using software rendering."
        echo "spice"
        return
    fi
    if ! ls /dev/dri/renderD* &>/dev/null; then
        warn "No DRI render node found — virgl 3D disabled; using software rendering."
        echo "spice"
        return
    fi
    echo "spice,gl=on"
}

detect_video() {
    local graphics="$1"
    [[ "$graphics" == "spice,gl=on" ]] && echo "virtio,accel3d=yes" || echo "virtio"
}

# ── ISO ACL setup ──────────────────────────────────────────────────────────────
# Grants the qemu user traversal + read access to reach an ISO outside
# /var/lib/libvirt/images without moving it.
ensure_iso_accessible() {
    local iso
    iso="$(realpath "$1")"

    # If qemu can already read it, nothing to do.
    if sudo -n -u qemu test -r "$iso" 2>/dev/null; then
        return
    fi

    info "Granting qemu ACL access to ISO path..."

    # Walk every directory component from / to the ISO, adding execute (traverse)
    # permission where we're inside a home directory.
    local path=""
    local home_root
    home_root="$(dirname "$HOME")"   # e.g. /home

    IFS='/' read -ra parts <<< "$iso"
    for part in "${parts[@]}"; do
        [[ -z "$part" ]] && continue
        path="${path}/${part}"
        # Only set ACL on directories at or below the home parent
        [[ "$path" == "$home_root"* ]] || continue
        [[ -d "$path" ]] || break
        sudo setfacl -m u:qemu:x "$path" \
            || error "Could not set ACL on ${path} — try: sudo setfacl -m u:qemu:x ${path}"
    done

    # Read access on the ISO itself
    sudo setfacl -m u:qemu:r "$iso" \
        || error "Could not set ACL on ${iso} — try: sudo setfacl -m u:qemu:r ${iso}"

    success "ACL set — qemu can read ISO."
}

# ── setup ── one-time host preparation ────────────────────────────────────────
cmd_setup() {
    section "RaBbLE-OS VM Host Setup"

    local real_user="${SUDO_USER:-$USER}"
    local ok=true

    # 1. VM storage
    info "VM storage directory: ${VM_DISK_DIR}"
    echo ""

    # 2. Group membership
    if id -nG "$real_user" | grep -qw libvirt; then
        success "libvirt group: ${real_user} ✓"
    else
        warn "${real_user} is not in the libvirt group."
        info "Run: sudo usermod -aG libvirt,kvm ${real_user}"
        info "Then open a new terminal for it to take effect."
        ok=false
    fi

    # 3. libvirtd
    if systemctl is-active --quiet libvirtd; then
        success "libvirtd: running ✓"
    else
        info "Starting libvirtd..."
        sudo systemctl enable --now libvirtd
        success "libvirtd: started ✓"
    fi

    # 4. Default NAT network
    if virsh net-info default &>/dev/null && \
       virsh net-info default 2>/dev/null | grep -q "Active:.*yes"; then
        success "Default NAT network: active ✓"
    else
        info "Configuring default NAT network..."
        if ! virsh net-info default &>/dev/null; then
            sudo virsh net-define /usr/share/libvirt/networks/default.xml
        fi
        sudo virsh net-start default    2>/dev/null || true
        sudo virsh net-autostart default
        success "Default NAT network: active ✓"
    fi

    echo ""
    if [[ "$ok" == "true" ]]; then
        success "Host is ready. Cast a VM with: $0 cast <iso-path>"
    else
        warn "Fix the issues above, then re-run setup to verify."
    fi
}

# ── cast ── create VM from ISO ─────────────────────────────────────────────────
cmd_cast() {
    local iso="${1:-}"
    [[ -z "$iso" ]] && error "Usage: $0 cast <path-to-fedora-sway-spin.iso>"
    [[ ! -f "$iso" ]] && error "ISO not found: $iso"

    if vm_exists; then
        warn "VM '${VM_NAME}' already exists — cleaning up before recast..."
        vm_running && virsh destroy "$VM_NAME" 2>/dev/null || true
        virsh undefine "$VM_NAME" --snapshots-metadata --nvram 2>/dev/null || true
        [[ -f "$VM_DISK" ]] && rm -f "$VM_DISK"
        success "Cleaned up previous VM."
    fi

    # Resolve best available os-variant (osinfo-db may lag behind Fedora releases)
    local os_variant
    os_variant="$(osinfo-query os 2>/dev/null \
        | grep -oP 'fedora\d+' \
        | grep -v 'fedora4\b' \
        | sort -t'a' -k2 -V \
        | tail -1)" || os_variant="fedora43"
    [[ -z "$os_variant" ]] && os_variant="fedora43"

    local graphics video
    graphics="$(detect_graphics)"
    video="$(detect_video "$graphics")"

    ensure_iso_accessible "$iso"

    section "Creating RaBbLE-OS dev VM: ${VM_NAME}"
    info "RAM:      ${VM_RAM} MB"
    info "vCPUs:    ${VM_VCPUS}"
    info "Disk:     ${VM_DISK_SIZE} GB → ${VM_DISK}"
    info "ISO:      ${iso}"
    info "Variant:  ${os_variant}"
    info "Graphics: ${graphics} / video: ${video}"
    echo ""

    mkdir -p "$VM_DISK_DIR"

    virt-install \
        --name         "$VM_NAME" \
        --ram          "$VM_RAM" \
        --vcpus        "$VM_VCPUS" \
        --cpu          host-passthrough \
        --os-variant   "$os_variant" \
        --disk         "path=${VM_DISK},size=${VM_DISK_SIZE},format=qcow2,bus=virtio" \
        --cdrom        "$iso" \
        --boot         uefi \
        --network      "network=default,model=virtio" \
        --graphics     "$graphics" \
        --video        "$video" \
        --channel      "spicevmc" \
        --memballoon   virtio \
        --noautoconsole \
        --wait         -1

    echo ""
    success "VM '${VM_NAME}' created."
    info "Opening SPICE display..."
    local real_user="${SUDO_USER:-$USER}"
    sudo -u "$real_user" \
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
        DISPLAY="${DISPLAY:-}" \
        XDG_RUNTIME_DIR="/run/user/$(id -u "$real_user")" \
        virt-viewer --connect qemu:///system "$VM_NAME" &
    info "After the Fedora install completes inside the VM:"
    info "  1. Take a clean snapshot: $0 snapshot clean-install"
    info "  2. Run the RaBbLE-OS install: $0 connect → bash RaBbLE-OS-Install.sh"
}

# ── status ─────────────────────────────────────────────────────────────────────
cmd_status() {
    check_deps
    if ! vm_exists; then
        warn "VM '${VM_NAME}' does not exist. Run: $0 cast <iso>"
        exit 0
    fi

    section "VM Status: ${VM_NAME}"
    virsh dominfo "$VM_NAME"
    echo ""

    local snapshot_count
    snapshot_count=$(virsh snapshot-list "$VM_NAME" --count 2>/dev/null || echo 0)
    info "Snapshots: ${snapshot_count}"
}

# ── start ──────────────────────────────────────────────────────────────────────
cmd_start() {
    check_deps
    vm_exists || error "VM '${VM_NAME}' not found. Run: $0 cast <iso>"

    if vm_running; then
        success "VM '${VM_NAME}' is already running."
        return
    fi

    info "Starting VM '${VM_NAME}'..."
    virsh start "$VM_NAME"
    success "VM started."
}

# ── stop ───────────────────────────────────────────────────────────────────────
cmd_stop() {
    check_deps
    vm_exists || error "VM '${VM_NAME}' not found."

    if ! vm_running; then
        success "VM '${VM_NAME}' is already stopped."
        return
    fi

    info "Sending graceful shutdown to '${VM_NAME}'..."
    virsh shutdown "$VM_NAME"
    success "Shutdown signal sent. The VM will stop when the guest OS completes shutdown."
}

# ── connect ─────────────────────────────────────────────────────────────────────
cmd_connect() {
    check_deps
    vm_exists || error "VM '${VM_NAME}' not found."

    if ! vm_running; then
        info "VM is not running. Starting it first..."
        virsh start "$VM_NAME"
        sleep 2
    fi

    info "Opening SPICE display for '${VM_NAME}'..."
    virt-viewer --connect qemu:///system "$VM_NAME" &
    success "Display launched."
}

# ── snapshot ───────────────────────────────────────────────────────────────────
cmd_snapshot() {
    local name="${1:-}"
    [[ -z "$name" ]] && error "Usage: $0 snapshot <name>\nExample: $0 snapshot clean-install"

    check_deps
    vm_exists || error "VM '${VM_NAME}' not found."

    info "Creating snapshot '${name}' on '${VM_NAME}'..."
    virsh snapshot-create-as "$VM_NAME" \
        --name "$name" \
        --description "RaBbLE-OS vmctl snapshot: ${name}" \
        --atomic
    success "Snapshot '${name}' created."
}

# ── restore ────────────────────────────────────────────────────────────────────
cmd_restore() {
    local name="${1:-}"
    [[ -z "$name" ]] && error "Usage: $0 restore <name>\nExample: $0 restore clean-install"

    check_deps
    vm_exists || error "VM '${VM_NAME}' not found."

    warn "Restoring '${VM_NAME}' to snapshot '${name}'..."
    warn "Any unsaved state since that snapshot will be lost."
    echo ""
    read -rp "  Continue? [y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && { info "Restore cancelled."; exit 0; }

    virsh snapshot-revert "$VM_NAME" --snapshotname "$name"
    success "Restored to snapshot '${name}'."
}

# ── snapshots ──────────────────────────────────────────────────────────────────
cmd_snapshots() {
    check_deps
    vm_exists || error "VM '${VM_NAME}' not found."

    section "Snapshots: ${VM_NAME}"
    virsh snapshot-list "$VM_NAME" --tree
}

# ── destroy ────────────────────────────────────────────────────────────────────
cmd_destroy() {
    check_deps
    vm_exists || error "VM '${VM_NAME}' not found."

    warn "This will permanently delete the VM '${VM_NAME}' and its disk image."
    warn "Disk: ${VM_DISK}"
    echo ""
    read -rp "  Type the VM name to confirm deletion: " confirm_name
    [[ "$confirm_name" != "$VM_NAME" ]] && { info "Destroy cancelled."; exit 0; }

    if vm_running; then
        info "Forcing VM off before removal..."
        virsh destroy "$VM_NAME" 2>/dev/null || true
    fi

    virsh undefine "$VM_NAME" \
        --snapshots-metadata \
        --nvram \
        2>/dev/null || true

    if [[ -f "$VM_DISK" ]]; then
        rm -f "$VM_DISK"
        success "Disk image removed: ${VM_DISK}"
    fi

    success "VM '${VM_NAME}' destroyed."
}

# ── help ───────────────────────────────────────────────────────────────────────
cmd_help() {
    sed -n '/^# Usage:/,/^# Prerequisites:/p' "$0" | sed 's/^# \{0,2\}//'
}

# ── Main dispatch ──────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift || true

    # Auto-detect VM partition for all commands except help
    if [[ "$cmd" != "help" && "$cmd" != "--help" && "$cmd" != "-h" ]]; then
        detect_vm_partition
    fi

    # Set VM_DISK after detecting partition location
    VM_DISK="${VM_DISK_DIR}/${VM_NAME}.qcow2"

    case "$cmd" in
        setup)      check_deps; cmd_setup "$@" ;;
        cast)       check_deps; cmd_cast "$@" ;;
        status)     cmd_status "$@" ;;
        start)      cmd_start "$@" ;;
        stop)       cmd_stop "$@" ;;
        connect)    cmd_connect "$@" ;;
        snapshot)   cmd_snapshot "$@" ;;
        restore)    cmd_restore "$@" ;;
        snapshots)  cmd_snapshots "$@" ;;
        destroy)    cmd_destroy "$@" ;;
        help|--help|-h) cmd_help ;;
        *) error "Unknown command: ${cmd}\nRun: $0 help" ;;
    esac
}

main "$@"
