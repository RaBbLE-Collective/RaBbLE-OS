#!/usr/bin/env bash
# ==============================================================================
# RaBbLE-OS-vmctl.sh
# VM lifecycle management spell for RaBbLE-OS development VMs
#
# Creates and manages a Fedora KVM VM so Hyprland/Sway can run inside it.
# Use this to test RaBbLE-OS bootstraps without touching the daily driver.
#
# Usage:
#   ./RaBbLE-OS-vmctl.sh partition-setup <device> — format and mount a BTRFS partition for VMs
#   ./RaBbLE-OS-vmctl.sh setup                 — prepare the host (run once)
#   ./RaBbLE-OS-vmctl.sh cast <iso-path>       — create the VM from a Fedora ISO (interactive install)
#   ./RaBbLE-OS-vmctl.sh cast-ks <iso-path>    — create the VM with automated KS install (qcow2 default)
#   ./RaBbLE-OS-vmctl.sh cast-ks --raw-disk <device> <iso-path> — cast-ks using raw partition device
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
#   1. Recommended: 32GB BTRFS partition for VMs (e.g., partition-setup /dev/sdX)
#   2. Run the Ansible virtualization role first:
#      ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml -K --tags virtualization
# ==============================================================================
set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
VM_NAME="${RABBLE_VM_NAME:-rabble-os-dev}"
VM_RAM="${RABBLE_VM_RAM:-4096}"             # MB
VM_VCPUS="${RABBLE_VM_VCPUS:-4}"
VM_DISK_SIZE="${RABBLE_VM_DISK_SIZE:-20}"   # GB (for qcow2 mode only)
VM_PARTITION_LABEL="RaBbLE-VM"              # BTRFS partition label for VM direct boot
VM_PARTITION_MOUNT="/mnt/vms"               # Where to mount the VM partition (qcow2 mode)
VM_DISK_DIR="${RABBLE_VM_DISK_DIR:-}"       # Set by detect_vm_partition() if available
VM_PARTITION_DEVICE=""                      # Set by detect_vm_partition() if partition exists
VM_USE_PARTITION=false                      # Use partition directly (true) or qcow2 (false)
FORCE_QCOW2="${RABBLE_VM_FORCE_QCOW2:-}"    # Set to 1 to force qcow2 even if partition exists
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

# ── VM disk mode initialization ───────────────────────────────────────────────
init_vm_disk_mode() {
    # Default to qcow2 unless --raw-disk is specified
    VM_DISK_DIR="${RABBLE_VM_DISK_DIR:-/var/lib/libvirt/images}"
    VM_USE_PARTITION=false
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

# ── Wait for VM to be registered and optionally running ──────────────────────
wait_for_vm() {
    local timeout="${1:-60}"
    local require_running="${2:-false}"
    local elapsed=0

    info "Waiting for VM to be registered..."
    while (( elapsed < timeout )); do
        if vm_exists; then
            success "VM registered: $VM_NAME"

            if [[ "$require_running" == "true" ]]; then
                info "Waiting for VM to start..."
                while (( elapsed < timeout )); do
                    if vm_running; then
                        success "VM is running"
                        return 0
                    fi
                    sleep 2
                    (( elapsed += 2 ))
                done
                error "VM did not start within ${timeout}s"
            fi
            return 0
        fi
        sleep 2
        (( elapsed += 2 ))
    done

    error "VM not registered within ${timeout}s"
}

# ── Connect to VM display with retries ───────────────────────────────────────
connect_to_vm() {
    local max_attempts=5
    local attempt=1

    info "Connecting to SPICE display..."

    while (( attempt <= max_attempts )); do
        if ! vm_exists; then
            warn "VM not found, retrying... (${attempt}/${max_attempts})"
            sleep 2
            (( attempt++ ))
            continue
        fi

        local real_user="${SUDO_USER:-$USER}"
        if WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
           DISPLAY="${DISPLAY:-}" \
           XDG_RUNTIME_DIR="/run/user/$(id -u "$real_user")" \
           sudo -u "$real_user" virt-viewer --connect qemu:///system "$VM_NAME" 2>/dev/null &
        then
            success "SPICE display opened in background"
            return 0
        fi

        warn "Failed to open display, retrying... (${attempt}/${max_attempts})"
        (( attempt++ ))
        sleep 2
    done

    warn "Could not open SPICE display after ${max_attempts} attempts"
    info "Connect manually: virt-viewer --connect qemu:///system ${VM_NAME}"
    return 1
}

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
    local iso=""
    local raw_disk=""

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --raw-disk)
                raw_disk="$2"
                shift 2
                [[ ! -b "$raw_disk" ]] && error "Invalid block device: ${raw_disk}"
                VM_PARTITION_DEVICE="$raw_disk"
                VM_USE_PARTITION=true
                ;;
            --help)
                echo "Usage: $0 cast [--raw-disk <device>] <path-to-fedora-netinst.iso>"
                echo ""
                echo "Options:"
                echo "  --raw-disk <device>  Use raw partition device instead of qcow2"
                exit 0
                ;;
            *)
                iso="$1"
                shift
                ;;
        esac
    done

    [[ -z "$iso" ]] && error "Usage: $0 cast [--raw-disk <device>] <path-to-fedora-netinst.iso>"
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
    info "ISO:      ${iso}"
    info "Variant:  ${os_variant}"
    info "Graphics: ${graphics} / video: ${video}"

    local disk_arg
    if [[ "$VM_USE_PARTITION" == "true" ]]; then
        section "Raw disk safeguards: ${VM_PARTITION_DEVICE}"

        # Check if partition is mounted
        local mount_point
        mount_point=$(findmnt -n -o TARGET "$VM_PARTITION_DEVICE" 2>/dev/null || true)
        if [[ -n "$mount_point" ]]; then
            warn "Device is currently mounted at: ${mount_point}"
            read -rp "  Unmount ${mount_point} before proceeding? [y/N]: " confirm
            [[ "${confirm,,}" != "y" ]] && { info "Cancelled."; exit 0; }

            info "Unmounting ${mount_point}..."
            if sudo umount "$mount_point"; then
                success "Unmounted ${mount_point}"
            else
                error "Failed to unmount ${mount_point}"
            fi
        fi

        info "Disk:     ${VM_PARTITION_DEVICE} (raw partition)"
        disk_arg="path=${VM_PARTITION_DEVICE},bus=virtio"
    else
        info "Disk:     ${VM_DISK_SIZE} GB → ${VM_DISK} (qcow2)"
        mkdir -p "$VM_DISK_DIR"
        disk_arg="path=${VM_DISK},size=${VM_DISK_SIZE},format=qcow2,bus=virtio"
    fi
    echo ""

    virt-install \
        --name         "$VM_NAME" \
        --ram          "$VM_RAM" \
        --vcpus        "$VM_VCPUS" \
        --cpu          host-passthrough \
        --os-variant   "$os_variant" \
        --disk         "$disk_arg" \
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
    wait_for_vm 120 true
    connect_to_vm

    info "After the Fedora install completes inside the VM:"
    info "  1. Take a clean snapshot: $0 snapshot clean-install"
    info "  2. Run the RaBbLE-OS install: $0 connect → bash RaBbLE-OS-Install.sh"
}

# ── cast-ks ── automated kickstart install ────────────────────────────────────────
cmd_cast_ks() {
    local iso=""
    local raw_disk=""

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --raw-disk)
                raw_disk="$2"
                shift 2
                [[ ! -b "$raw_disk" ]] && error "Invalid block device: ${raw_disk}"
                VM_PARTITION_DEVICE="$raw_disk"
                VM_USE_PARTITION=true
                ;;
            --help)
                echo "Usage: $0 cast-ks [--raw-disk <device>] <path-to-fedora-netinst.iso>"
                echo ""
                echo "Options:"
                echo "  --raw-disk <device>  Use raw partition device instead of qcow2 (e.g., /dev/nvme0n1p6)"
                echo ""
                echo "Examples:"
                echo "  $0 cast-ks ISO/Fedora-Everything-netinst.iso"
                echo "  $0 cast-ks --raw-disk /dev/nvme0n1p6 ISO/Fedora-Everything-netinst.iso"
                exit 0
                ;;
            *)
                iso="$1"
                shift
                ;;
        esac
    done

    [[ -z "$iso" ]] && error "Usage: $0 cast-ks [--raw-disk <device>] <path-to-fedora-netinst.iso>"
    [[ ! -f "$iso" ]] && error "ISO not found: $iso"
    [[ ! -f "RaBbLE-OS.ks" ]] && error "RaBbLE-OS.ks not found in current directory"

    if vm_exists; then
        warn "VM '${VM_NAME}' already exists — cleaning up before recast..."
        vm_running && virsh destroy "$VM_NAME" 2>/dev/null || true
        virsh undefine "$VM_NAME" --snapshots-metadata --nvram 2>/dev/null || true
        [[ -f "$VM_DISK" ]] && rm -f "$VM_DISK"
        success "Cleaned up previous VM."
    fi

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

    section "Automated KS Install: ${VM_NAME}"
    info "ISO:      ${iso}"
    info "KS file:  RaBbLE-OS.ks"
    info "Variant:  ${os_variant}"
    info "Graphics: ${graphics} / video: ${video}"
    echo ""

    # Use libvirt bridge host IP (always reachable from VM on NAT network)
    local host_ip="192.168.122.1"
    info "Using libvirt bridge host IP: ${host_ip}"

    # Start HTTP server in background to serve KS file
    info "Starting HTTP server on port 8888 to serve KS file..."
    local ks_dir
    ks_dir="$(pwd)"
    python3 -m http.server 8888 --directory "$ks_dir" > /tmp/rabble-ks-http.log 2>&1 &
    local http_pid=$!
    info "HTTP server PID: ${http_pid}"
    sleep 1

    # Prepare disk configuration
    local disk_arg
    if [[ "$VM_USE_PARTITION" == "true" ]]; then
        section "Using partition: ${VM_PARTITION_DEVICE}"

        # Check if partition is mounted
        local mount_point
        mount_point=$(findmnt -n -o TARGET "$VM_PARTITION_DEVICE" 2>/dev/null || true)
        if [[ -n "$mount_point" ]]; then
            warn "Partition is currently mounted at: ${mount_point}"
            read -rp "  Unmount ${mount_point} before formatting? [y/N]: " confirm
            [[ "${confirm,,}" != "y" ]] && { info "Cancelled."; kill $http_pid 2>/dev/null || true; exit 0; }

            info "Unmounting ${mount_point}..."
            if sudo umount "$mount_point"; then
                success "Unmounted ${mount_point}"
            else
                error "Failed to unmount ${mount_point}"
            fi
        fi

        warn "This will format ${VM_PARTITION_DEVICE} and overwrite all data on it."
        echo ""
        read -rp "  Format and use ${VM_PARTITION_DEVICE} for this VM? [y/N]: " confirm
        [[ "${confirm,,}" != "y" ]] && { info "Cancelled."; kill $http_pid 2>/dev/null || true; exit 0; }

        info "Formatting partition as ext4..."
        if sudo mkfs.ext4 -F "$VM_PARTITION_DEVICE"; then
            success "Partition formatted successfully"
        else
            error "Failed to format ${VM_PARTITION_DEVICE}"
        fi
        disk_arg="path=${VM_PARTITION_DEVICE},bus=virtio"
    else
        mkdir -p "$VM_DISK_DIR"
        disk_arg="path=${VM_DISK},size=${VM_DISK_SIZE},format=qcow2,bus=virtio"
        section "Using qcow2: ${VM_DISK}"
    fi

    section "Creating VM with virt-install..."
    virt-install \
        --name         "$VM_NAME" \
        --ram          "$VM_RAM" \
        --vcpus        "$VM_VCPUS" \
        --cpu          host-passthrough \
        --os-variant   "$os_variant" \
        --disk         "$disk_arg" \
        --location     "$iso" \
        --boot         uefi \
        --network      "network=default,model=virtio" \
        --graphics     "$graphics" \
        --video        "$video" \
        --channel      "spicevmc" \
        --memballoon   virtio \
        --noautoconsole \
        --extra-args   "inst.ks=http://${host_ip}:8888/RaBbLE-OS.ks console=tty0 console=ttyS0,115200n8" \
        --wait         -1 || {
        warn "virt-install failed. Killing HTTP server..."
        kill $http_pid 2>/dev/null || true
        return 1
    }

    echo ""
    success "VM '${VM_NAME}' created with KS automation."
    wait_for_vm 120 true
    connect_to_vm

    info "Installation is automated. HTTP server will stay active during install."
    info "HTTP server PID: ${http_pid}"
    info "When install completes and SDDM appears, kill it: kill ${http_pid}"
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

# ── partition-setup ───────────────────────────────────────────────────────────
cmd_partition_setup() {
    local device="${1:-}"
    [[ -z "$device" ]] && error "Usage: $0 partition-setup <device>\nExample: $0 partition-setup /dev/nvme0n1p6"

    # Normalize device path
    [[ ! "$device" =~ ^/dev/ ]] && device="/dev/$device"
    [[ ! -b "$device" ]] && error "Device not found: $device"

    section "BTRFS VM Partition Setup"
    warn "⚠ WARNING: This will ERASE all data on ${device}"
    echo ""

    # Show what's on the device
    echo "Current state of ${device}:"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$device" || true
    echo ""

    # Get partition info
    local size
    size=$(lsblk -ndo SIZE "$device" 2>/dev/null || echo "unknown")

    echo ""
    warn "About to format:"
    warn "  Device:      ${device}"
    warn "  Size:        ${size}"
    warn "  Label:       ${VM_PARTITION_LABEL} (fixed for auto-detection)"
    warn "  Filesystem:  BTRFS"
    warn "  Mount point: ${VM_PARTITION_MOUNT}"
    echo ""
    warn "⚠ This is a POINT OF NO RETURN. All data on ${device} will be destroyed."
    echo ""

    # Triple confirmation
    read -rp "Type the device name (e.g. nvme0n1p6) to confirm: " confirm_device
    if [[ "$confirm_device" != "${device##*/}" ]]; then
        warn "Device confirmation failed."
        exit 1
    fi

    read -rp "Type 'yes' to proceed with formatting: " confirm_yes
    if [[ "$confirm_yes" != "yes" ]]; then
        info "Format cancelled."
        exit 0
    fi

    # Format the partition
    echo ""
    info "Formatting ${device} as BTRFS..."
    if ! sudo mkfs.btrfs -L "$VM_PARTITION_LABEL" -f "$device" 2>&1 | tee /tmp/mkfs.log; then
        error "Format failed. Check /tmp/mkfs.log for details."
    fi

    echo ""
    success "Partition formatted successfully."

    # Try to mount it
    echo ""
    info "Attempting to mount at ${VM_PARTITION_MOUNT}..."

    sudo mkdir -p "$VM_PARTITION_MOUNT"
    if sudo mount -L "$VM_PARTITION_LABEL" "$VM_PARTITION_MOUNT" 2>/dev/null; then
        success "Mounted at ${VM_PARTITION_MOUNT}"

        # Add to fstab if not already there
        if ! grep -q "LABEL=${VM_PARTITION_LABEL}" /etc/fstab; then
            info "Adding to /etc/fstab..."
            echo "/dev/disk/by-label/${VM_PARTITION_LABEL}  ${VM_PARTITION_MOUNT}  btrfs  defaults,compress=zstd  0 0" | sudo tee -a /etc/fstab > /dev/null
            success "Added to /etc/fstab"
        else
            info "Already in /etc/fstab"
        fi

        echo ""
        success "VM partition ready at ${VM_PARTITION_MOUNT}"
        info "Run '$0 setup' to configure the host, then '$0 cast <iso>' to create a VM."
    else
        error "Could not mount ${device}. Try manually: sudo mount -L ${VM_PARTITION_LABEL} ${VM_PARTITION_MOUNT}"
    fi
}

# ── help ───────────────────────────────────────────────────────────────────────
cmd_help() {
    sed -n '/^# Usage:/,/^# Prerequisites:/p' "$0" | sed 's/^# \{0,2\}//'
}

# ── Main dispatch ──────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift || true

    # Initialize disk mode (default: qcow2)
    if [[ "$cmd" != "help" && "$cmd" != "--help" && "$cmd" != "-h" && "$cmd" != "partition-setup" ]]; then
        init_vm_disk_mode
    fi

    # Set VM_DISK after detecting partition location
    VM_DISK="${VM_DISK_DIR}/${VM_NAME}.qcow2"

    case "$cmd" in
        partition-setup) cmd_partition_setup "$@" ;;
        setup)      check_deps; cmd_setup "$@" ;;
        cast)       check_deps; cmd_cast "$@" ;;
        cast-ks)    check_deps; cmd_cast_ks "$@" ;;
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
