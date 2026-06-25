#!/usr/bin/env bash
# ==============================================================================
# RaBbLE-OS-vmctl.sh
# VM lifecycle management spell for RaBbLE-OS development VMs
#
# Creates and manages a Fedora KVM VM so Hyprland/Sway can run inside it.
# Use this to test RaBbLE-OS bootstraps without touching the daily driver.
#
# Usage: ./RaBbLE-OS-vmctl.sh [--quiet] <command> [args]
#   (no command)                              — show status if VM exists, else help
#   partition-setup <device>                  — format BTRFS VM partition
#   setup                                     — one-time host preparation
#   cast <iso>                                — interactive Anaconda install
#   cast-ks [--raw-disk <dev>] [--branch <name>] <iso>  — automated Kickstart install
#   recast  [--raw-disk <dev>] [--branch <name>] <iso>  — destroy + cast-ks in one step
#   status                                    — VM dashboard (state, IP, disk, uptime)
#   start                                     — start the VM
#   stop [--force] [--timeout N]              — graceful shutdown with timeout
#   connect                                   — open SPICE display
#   console                                   — serial console (TUI/CLI, no GUI needed)
#   ssh [cmd]                                 — SSH into VM as rabble
#   logs [unit]                               — tail journalctl (default: rabble-os-setup)
#   snapshot <name>                           — create a named snapshot
#   restore <name>                            — revert to a snapshot
#   snapshots                                 — list all snapshots
#   destroy                                   — delete VM + disk (confirms)
#   help                                      — show categorized help
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
QUIET="${RABBLE_VM_QUIET:-}"
LIBVIRT_URI="qemu:///system"
export LIBVIRT_DEFAULT_URI="$LIBVIRT_URI"

# Repo dir (this script lives at the RaBbLE-OS repo root) — used to resolve the
# default install branch from the current checkout.
REPO_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# Branch the VM clones the Collective/Grimoire/OS from. Defaults to the OS repo's
# current checkout so the VM tests what you're working on. Override with --branch.
RABBLE_BRANCH="${RABBLE_BRANCH:-}"

# ── Colour palette ─────────────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m';     DIM='\033[2m'; RESET='\033[0m'

info()    { [[ -n "$QUIET" ]] && return; echo -e "${CYAN}[vmctl]${RESET}  $*"; }
success() { [[ -n "$QUIET" ]] && return; echo -e "${GREEN}[vmctl]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[vmctl]${RESET}  $*" >&2; }
error()   { echo -e "${RED}[vmctl]${RESET}  $*" >&2; exit 1; }
section() { [[ -n "$QUIET" ]] && return; echo -e "\n${BOLD}${CYAN}── $* ──${RESET}"; }

# ── VM IP helper ──────────────────────────────────────────────────────────────
vm_ip() {
    local mac
    mac=$(virsh domiflist "$VM_NAME" 2>/dev/null | awk '/virtio/{print $5}')
    [[ -z "$mac" ]] && return 1
    virsh net-dhcp-leases default 2>/dev/null \
        | awk -v m="$mac" '$3==m {gsub(/\/.*/, "", $5); print $5; exit}'
}

# ── Partition safety ──────────────────────────────────────────────────────────
# The RaBbLE-VM BTRFS partition is host storage — it must NEVER be handed to a
# VM installer as a raw disk. Doing so lets clearpart/autopart destroy its
# filesystem and label, which can make the daily-driver system unbootable.

is_rabble_vm_partition() {
    local dev="$1"
    [[ ! -b "$dev" ]] && return 1
    local label
    label=$(lsblk -ndo LABEL "$dev" 2>/dev/null || true)
    [[ "$label" == "$VM_PARTITION_LABEL" ]] && return 0
    local resolved
    resolved=$(realpath "$dev" 2>/dev/null || echo "$dev")
    local vm_dev
    vm_dev=$(realpath "/dev/disk/by-label/${VM_PARTITION_LABEL}" 2>/dev/null || true)
    [[ -n "$vm_dev" && "$resolved" == "$vm_dev" ]] && return 0
    return 1
}

reject_raw_disk_if_vm_partition() {
    local dev="$1"
    if is_rabble_vm_partition "$dev"; then
        error "BLOCKED: ${dev} is the RaBbLE-VM host partition.\n" \
              "  The VM installer would destroy its BTRFS label and filesystem,\n" \
              "  which can make the daily-driver unbootable.\n\n" \
              "  Use qcow2 mode instead (omit --raw-disk) — the VM disk image\n" \
              "  will be stored ON the RaBbLE-VM partition at ${VM_PARTITION_MOUNT}/."
    fi
}

# ── VM disk mode initialization ───────────────────────────────────────────────
init_vm_disk_mode() {
    VM_USE_PARTITION=false
    if [[ -n "${RABBLE_VM_DISK_DIR:-}" ]]; then
        VM_DISK_DIR="$RABBLE_VM_DISK_DIR"
    elif mountpoint -q "$VM_PARTITION_MOUNT" 2>/dev/null; then
        VM_DISK_DIR="$VM_PARTITION_MOUNT"
    else
        VM_DISK_DIR="/var/lib/libvirt/images"
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

    # Resolve the real user and their display environment
    local real_user="${SUDO_USER:-$USER}"
    local real_uid
    real_uid=$(id -u "$real_user" 2>/dev/null || id -u)
    local wayland="${WAYLAND_DISPLAY:-}"
    local display="${DISPLAY:-}"
    local xdg_runtime="/run/user/${real_uid}"

    while (( attempt <= max_attempts )); do
        if ! vm_exists; then
            warn "VM not found, retrying... (${attempt}/${max_attempts})"
            sleep 2
            (( attempt++ ))
            continue
        fi

        local viewer_pid
        if [[ $EUID -eq 0 && -n "$SUDO_USER" ]]; then
            # Running as sudo — launch virt-viewer as the real user with their display
            WAYLAND_DISPLAY="$wayland" \
            DISPLAY="$display" \
            XDG_RUNTIME_DIR="$xdg_runtime" \
            sudo -u "$real_user" \
                virt-viewer --connect qemu:///system "$VM_NAME" &>/dev/null &
            viewer_pid=$!
        else
            virt-viewer --connect qemu:///system "$VM_NAME" &>/dev/null &
            viewer_pid=$!
        fi

        # Give virt-viewer a moment to start or fail
        sleep 2
        if kill -0 "$viewer_pid" 2>/dev/null; then
            success "SPICE display opened (pid ${viewer_pid})"
            return 0
        fi

        warn "virt-viewer exited immediately, retrying... (${attempt}/${max_attempts})"
        (( attempt++ ))
        sleep 2
    done

    warn "Could not open SPICE display after ${max_attempts} attempts"
    local spice_uri
    spice_uri=$(virsh domdisplay "$VM_NAME" 2>/dev/null || true)
    if [[ -n "$spice_uri" ]]; then
        info "SPICE URI:      ${spice_uri}"
        info "Try:            virt-viewer '${spice_uri}'"
    fi
    info "Or run:         $0 connect"
    info "Serial console: virsh console ${VM_NAME}"
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

    # Fast non-sudo pre-check: skip if qemu already has read access via either
    # an explicit ACL entry or world-readable mode + parent directory ACL.
    # (sudo -n -u qemu test -r requires passwordless sudoers — too fragile.)
    if getfacl -p "$iso" 2>/dev/null | grep -q "^user:qemu:r"; then
        return
    fi
    local iso_dir
    iso_dir="$(dirname "$iso")"
    local mode
    mode="$(stat -c '%a' "$iso" 2>/dev/null || echo 0)"
    if (( (8#$mode & 4) != 0 )) && \
       getfacl -p "$iso_dir" 2>/dev/null | grep -q "^user:qemu:x"; then
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

    # 5. ISO ACLs — grant qemu traversal to the repo's ISO/ directory so cast-ks
    #    can access ISOs stored outside /var/lib/libvirt/images without needing
    #    interactive sudo at cast time. Safe to re-run (setfacl is idempotent).
    local iso_dir="${REPO_DIR}/ISO"
    if [[ -d "$iso_dir" ]]; then
        info "Setting qemu ACLs for ISO directory..."
        local path=""
        local home_root
        home_root="$(dirname "$HOME")"
        IFS='/' read -ra parts <<< "$(realpath "$iso_dir")"
        for part in "${parts[@]}"; do
            [[ -z "$part" ]] && continue
            path="${path}/${part}"
            [[ "$path" == "$home_root"* ]] || continue
            [[ -d "$path" ]] || break
            sudo setfacl -m u:qemu:x "$path" 2>/dev/null || true
        done
        # Grant read on any ISOs already present
        find "$iso_dir" -maxdepth 1 -name '*.iso' -exec sudo setfacl -m u:qemu:r {} \; 2>/dev/null || true
        success "ISO ACLs: set for ${iso_dir} ✓"
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
                reject_raw_disk_if_vm_partition "$raw_disk"
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
        [[ -f "$VM_DISK" ]] && sudo rm -f "$VM_DISK"
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
        --serial       pty \
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
                reject_raw_disk_if_vm_partition "$raw_disk"
                VM_PARTITION_DEVICE="$raw_disk"
                VM_USE_PARTITION=true
                ;;
            --branch)
                RABBLE_BRANCH="$2"
                shift 2
                [[ -z "$RABBLE_BRANCH" ]] && error "--branch requires a branch name"
                ;;
            --help)
                echo "Usage: $0 cast-ks [--raw-disk <device>] [--branch <name>] <path-to-fedora-netinst.iso>"
                echo ""
                echo "Options:"
                echo "  --raw-disk <device>  Use raw partition device instead of qcow2 (e.g., /dev/nvme0n1p6)"
                echo "  --branch <name>      Git branch the VM clones Collective/Grimoire/OS from"
                echo "                       (default: this OS repo's current checkout)"
                echo ""
                echo "Examples:"
                echo "  $0 cast-ks ISO/Fedora-Everything-netinst.iso"
                echo "  $0 cast-ks --branch new-horizons ISO/Fedora-Everything-netinst.iso"
                echo "  $0 cast-ks --raw-disk /dev/nvme0n1p6 ISO/Fedora-Everything-netinst.iso"
                exit 0
                ;;
            *)
                iso="$1"
                shift
                ;;
        esac
    done

    # Resolve the install branch: explicit --branch wins, else the OS repo's checkout.
    if [[ -z "$RABBLE_BRANCH" ]]; then
        RABBLE_BRANCH="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
        [[ -z "$RABBLE_BRANCH" || "$RABBLE_BRANCH" == "HEAD" ]] && RABBLE_BRANCH="new-horizons"
    fi

    [[ -z "$iso" ]] && error "Usage: $0 cast-ks [--raw-disk <device>] <path-to-fedora-netinst.iso>"
    [[ ! -f "$iso" ]] && error "ISO not found: $iso"
    [[ ! -f "RaBbLE-OS.ks" ]] && error "RaBbLE-OS.ks not found in current directory"

    if vm_exists; then
        warn "VM '${VM_NAME}' already exists — cleaning up before recast..."
        vm_running && virsh destroy "$VM_NAME" 2>/dev/null || true
        virsh undefine "$VM_NAME" --snapshots-metadata --nvram 2>/dev/null || true
        [[ -f "$VM_DISK" ]] && sudo rm -f "$VM_DISK"
        success "Cleaned up previous VM."
    fi

    local os_variant
    os_variant="$(osinfo-query os 2>/dev/null \
        | grep -oP 'fedora\d+' \
        | grep -v 'fedora4\b' \
        | sort -t'a' -k2 -V \
        | tail -1)" || os_variant="fedora43"
    [[ -z "$os_variant" ]] && os_variant="fedora43"

    # KS install is text-only (Anaconda); GL acceleration is unnecessary and
    # breaks when libvirtd's qemu can't reach the user's Wayland socket.
    local graphics="spice"
    local video="virtio"

    ensure_iso_accessible "$iso"

    section "Automated KS Install: ${VM_NAME}"
    info "ISO:      ${iso}"
    info "KS file:  RaBbLE-OS.ks"
    info "Branch:   ${RABBLE_BRANCH}  (Collective/Grimoire/OS clone target)"
    info "Variant:  ${os_variant}"
    info "Graphics: ${graphics} / video: ${video}"
    echo ""

    # Generate password hash + resolve branch, inject both into a temp copy of the KS
    local ks_password="${RABBLE_PASSWORD:-rabble}"
    local ks_hash
    ks_hash="$(openssl passwd -6 "$ks_password")"

    local ks_tmp="/tmp/RaBbLE-OS.ks"
    sed -e "s|__RABBLE_PASSWORD_HASH__|${ks_hash}|g" \
        -e "s|__RABBLE_BRANCH__|${RABBLE_BRANCH}|g" \
        RaBbLE-OS.ks > "$ks_tmp"
    local ks_path="$ks_tmp"
    # Use ${ks_tmp:-} so the trap doesn't error if it fires after the local goes out of scope.
    trap 'rm -f "${ks_tmp:-}"' EXIT

    # Prepare disk configuration
    local disk_arg
    if [[ "$VM_USE_PARTITION" == "true" ]]; then
        section "Using partition: ${VM_PARTITION_DEVICE}"

        # Check if partition is mounted
        local mount_point
        mount_point=$(findmnt -n -o TARGET "$VM_PARTITION_DEVICE" 2>/dev/null || true)
        if [[ -n "$mount_point" ]]; then
            warn "Partition is currently mounted at: ${mount_point}"
            read -rp "  Unmount ${mount_point} before proceeding? [y/N]: " confirm
            [[ "${confirm,,}" != "y" ]] && { info "Cancelled."; exit 0; }

            info "Unmounting ${mount_point}..."
            if sudo umount "$mount_point"; then
                success "Unmounted ${mount_point}"
            else
                error "Failed to unmount ${mount_point}"
            fi
        fi

        warn "KS will clearpart + autopart this device. All data will be lost."
        echo ""
        read -rp "  Use ${VM_PARTITION_DEVICE} for this VM? [y/N]: " confirm
        [[ "${confirm,,}" != "y" ]] && { info "Cancelled."; exit 0; }

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
        --serial       pty \
        --memballoon   virtio \
        --noautoconsole \
        --initrd-inject "$ks_path" \
        --extra-args   "inst.ks=file:/RaBbLE-OS.ks console=tty0 console=ttyS0,115200n8" \
        || return 1

    echo ""
    success "VM '${VM_NAME}' created — KS install starting."
    wait_for_vm 60 true
    connect_to_vm

    info "KS install is running. VM will reboot automatically when done."
    info "After reboot, firstboot service runs Bootstrap (Phase 1: base + boot)."
    info "When SDDM appears, Phase 1 smoke test is done."
}

# ── status ─────────────────────────────────────────────────────────────────────
cmd_status() {
    check_deps
    if ! vm_exists; then
        warn "VM '${VM_NAME}' does not exist. Run: $0 cast <iso>"
        exit 0
    fi

    local state
    state=$(virsh domstate "$VM_NAME" 2>/dev/null | head -1)

    local state_color="$YELLOW"
    case "$state" in
        running)  state_color="$GREEN" ;;
        shut*)    state_color="$DIM"   ;;
        paused)   state_color="$YELLOW" ;;
        crashed)  state_color="$RED"   ;;
    esac

    section "VM Status: ${VM_NAME}"
    echo -e "  State:      ${state_color}${state}${RESET}"

    if [[ "$state" == "running" ]]; then
        local ip
        ip=$(vm_ip)
        if [[ -n "$ip" ]]; then
            echo -e "  IP:         ${CYAN}${ip}${RESET}"
        else
            echo -e "  IP:         ${DIM}(waiting for DHCP)${RESET}"
        fi

        local pid
        pid=$(virsh dominfo "$VM_NAME" 2>/dev/null | awk '/^Id:/{print $2}')
        if [[ -n "$pid" && "$pid" != "-" ]]; then
            local qemu_pid
            qemu_pid=$(pgrep -f "qemu.*${VM_NAME}" 2>/dev/null | head -1)
            if [[ -n "$qemu_pid" ]]; then
                local uptime_sec
                uptime_sec=$(ps -o etimes= -p "$qemu_pid" 2>/dev/null | tr -d ' ')
                if [[ -n "$uptime_sec" ]]; then
                    local h=$((uptime_sec / 3600)) m=$(((uptime_sec % 3600) / 60)) s=$((uptime_sec % 60))
                    printf "  Uptime:     %dh %dm %ds\n" "$h" "$m" "$s"
                fi
            fi
        fi
    fi

    local dominfo
    dominfo=$(virsh dominfo "$VM_NAME" 2>/dev/null)
    local ram
    ram=$(echo "$dominfo" | awk '/^Max memory:/{printf "%.0f", $3/1024}')
    local vcpus
    vcpus=$(echo "$dominfo" | awk '/^CPU\(s\):/{print $2}')
    echo "  RAM:        ${ram} MB"
    echo "  vCPUs:      ${vcpus}"

    local disk_path
    disk_path=$(virsh domblklist "$VM_NAME" 2>/dev/null | awk 'NR>2 && $2 && $2!="-" {print $2; exit}' || true)
    if [[ -n "$disk_path" && -f "$disk_path" ]]; then
        local disk_size
        disk_size=$(du -h "$disk_path" 2>/dev/null | cut -f1)
        local disk_alloc
        disk_alloc=$(qemu-img info "$disk_path" 2>/dev/null | awk '/virtual size/{print $3, $4}' || true)
        echo "  Disk:       ${disk_size} used (${disk_alloc:-unknown} virtual)"
    elif [[ -n "$disk_path" && -b "$disk_path" ]]; then
        local blk_size
        blk_size=$(lsblk -ndo SIZE "$disk_path" 2>/dev/null || true)
        echo "  Disk:       ${disk_path} (${blk_size:-unknown} raw)"
    fi

    local snapshot_count
    snapshot_count=$(virsh snapshot-list "$VM_NAME" --count 2>/dev/null || echo 0)
    echo "  Snapshots:  ${snapshot_count}"

    if [[ "$state" == "running" ]]; then
        local spice_port
        spice_port=$(virsh domdisplay "$VM_NAME" 2>/dev/null | grep -oP ':\K\d+')
        if [[ -n "$spice_port" ]]; then
            echo -e "  SPICE:      ${DIM}spice://localhost:${spice_port}${RESET}"
        fi
    fi
    echo ""
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

    local force=false
    local timeout=60
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f)  force=true; shift ;;
            --timeout|-t) timeout="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ "$force" == "true" ]]; then
        warn "Force-stopping VM '${VM_NAME}'..."
        virsh destroy "$VM_NAME"
        success "VM force-stopped."
        return
    fi

    info "Sending graceful shutdown to '${VM_NAME}' (timeout: ${timeout}s)..."
    virsh shutdown "$VM_NAME"

    local elapsed=0
    while (( elapsed < timeout )); do
        if ! vm_running; then
            success "VM shut down cleanly."
            return
        fi
        sleep 2
        (( elapsed += 2 ))
    done

    warn "VM did not shut down within ${timeout}s."
    read -rp "  Force stop? [y/N]: " confirm
    if [[ "${confirm,,}" == "y" ]]; then
        virsh destroy "$VM_NAME"
        success "VM force-stopped."
    else
        info "VM is still shutting down in the background."
    fi
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

    connect_to_vm
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
        sudo rm -f "$VM_DISK"
        success "Disk image removed: ${VM_DISK}"
    fi

    success "VM '${VM_NAME}' destroyed."

    # Check RaBbLE-VM partition health after destroy
    local vm_dev
    vm_dev=$(realpath "/dev/disk/by-label/${VM_PARTITION_LABEL}" 2>/dev/null || true)
    if [[ -z "$vm_dev" ]]; then
        warn "RaBbLE-VM partition label not found — it may need to be restored."
        warn "Run: $0 partition-setup <device>"
    fi
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
            echo "/dev/disk/by-label/${VM_PARTITION_LABEL}  ${VM_PARTITION_MOUNT}  btrfs  nofail,x-systemd.device-timeout=5s,defaults,compress=zstd  0 0" | sudo tee -a /etc/fstab > /dev/null
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

# ── console ───────────────────────────────────────────────────────────────────
cmd_console() {
    check_deps
    vm_exists || error "VM '${VM_NAME}' not found."

    if ! vm_running; then
        info "VM is not running. Starting it first..."
        virsh start "$VM_NAME"
        sleep 2
    fi

    info "Attaching serial console to '${VM_NAME}'..."
    info "Escape sequence: Ctrl+]  (or Ctrl+5 on some terminals)"
    echo ""
    virsh console "$VM_NAME"
}

# ── ssh ───────────────────────────────────────────────────────────────────────
cmd_ssh() {
    check_deps
    vm_exists || error "VM '${VM_NAME}' not found."
    vm_running || error "VM '${VM_NAME}' is not running."

    local ip
    ip=$(vm_ip)
    [[ -z "$ip" ]] && error "No IP address yet — VM may still be booting. Try: $0 console"

    info "SSH to ${VM_NAME} at ${ip}..."
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "rabble@${ip}" "$@"
}

# ── logs ──────────────────────────────────────────────────────────────────────
cmd_logs() {
    check_deps
    vm_exists || error "VM '${VM_NAME}' not found."
    vm_running || error "VM '${VM_NAME}' is not running."

    local ip
    ip=$(vm_ip)
    [[ -z "$ip" ]] && error "No IP address yet — VM may still be booting. Try: $0 console"

    local unit="${1:-rabble-os-setup}"
    info "Tailing ${unit} on ${VM_NAME} (${ip})..."
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "rabble@${ip}" "sudo journalctl -u ${unit} -f --no-pager"
}

# ── recast ────────────────────────────────────────────────────────────────────
cmd_recast() {
    check_deps

    if vm_exists; then
        warn "Destroying existing VM '${VM_NAME}' before recast..."
        vm_running && virsh destroy "$VM_NAME" 2>/dev/null || true
        virsh undefine "$VM_NAME" --snapshots-metadata --nvram 2>/dev/null || true
        [[ -f "$VM_DISK" ]] && sudo rm -f "$VM_DISK"
        success "Previous VM cleaned up."
    fi

    cmd_cast_ks "$@"
}

# ── help ───────────────────────────────────────────────────────────────────────
cmd_help() {
    echo -e "${BOLD}${CYAN}RaBbLE-OS vmctl${RESET} — VM lifecycle spell"
    echo ""
    echo -e "${BOLD}Setup${RESET}"
    echo "  partition-setup <dev>       Format BTRFS VM partition"
    echo "  setup                       One-time host preparation"
    echo ""
    echo -e "${BOLD}Create & Destroy${RESET}"
    echo "  cast <iso>                  Interactive Anaconda install"
    echo "  cast-ks <iso>               Automated Kickstart install"
    echo "  recast <iso>                Destroy + cast-ks in one step"
    echo "  destroy                     Delete VM and disk (confirms)"
    echo ""
    echo -e "${BOLD}Lifecycle${RESET}"
    echo "  status                      VM dashboard (state, IP, disk, uptime)"
    echo "  start                       Start the VM"
    echo "  stop [--force] [--timeout]  Graceful shutdown (waits, then offers force)"
    echo "  connect                     Open SPICE display (needs GUI)"
    echo "  console                     Serial console (TUI/CLI, no GUI needed)"
    echo "  ssh [cmd]                   SSH into the VM as rabble"
    echo "  logs [unit]                 Tail journalctl (default: rabble-os-setup)"
    echo ""
    echo -e "${BOLD}Snapshots${RESET}"
    echo "  snapshot <name>             Create a named snapshot"
    echo "  restore <name>              Revert to a snapshot"
    echo "  snapshots                   List all snapshots"
    echo ""
    echo -e "${BOLD}Options${RESET}"
    echo "  --quiet                     Suppress info/success output"
    echo "  --raw-disk <dev>            Use raw partition for cast/cast-ks"
    echo ""
    echo -e "${DIM}Environment: RABBLE_VM_NAME, RABBLE_VM_RAM, RABBLE_VM_VCPUS, RABBLE_VM_DISK_SIZE${RESET}"
}

# ── Main dispatch ──────────────────────────────────────────────────────────────
main() {
    local args=()
    for arg in "$@"; do
        case "$arg" in
            --quiet|-q) QUIET=1 ;;
            *) args+=("$arg") ;;
        esac
    done
    set -- "${args[@]+"${args[@]}"}"

    local cmd="${1:-}"
    shift || true

    # No command: show status if VM exists, otherwise help
    if [[ -z "$cmd" ]]; then
        init_vm_disk_mode
        VM_DISK="${VM_DISK_DIR}/${VM_NAME}.qcow2"
        if vm_exists 2>/dev/null; then
            cmd_status "$@"
        else
            cmd_help
        fi
        return
    fi

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
        recast)     check_deps; cmd_recast "$@" ;;
        status)     cmd_status "$@" ;;
        start)      cmd_start "$@" ;;
        stop)       cmd_stop "$@" ;;
        connect)    cmd_connect "$@" ;;
        console)    cmd_console "$@" ;;
        ssh)        cmd_ssh "$@" ;;
        logs)       cmd_logs "$@" ;;
        snapshot)   cmd_snapshot "$@" ;;
        restore)    cmd_restore "$@" ;;
        snapshots)  cmd_snapshots "$@" ;;
        destroy)    cmd_destroy "$@" ;;
        help|--help|-h) cmd_help ;;
        *) error "Unknown command: ${cmd}\nRun: $0 help" ;;
    esac
}

main "$@"
