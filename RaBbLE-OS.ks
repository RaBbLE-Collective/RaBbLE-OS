# ==============================================================================
# RaBbLE-OS.ks — Tier 1 Kickstart
# Phase 4 installer deliverable (Plot C — Installer)
#
# USAGE:
#   Boot Fedora 44 Everything netinstall ISO with inst.ks pointing here.
#
#   VM (automated — recommended):
#     ./RaBbLE-OS-vmctl.sh cast-ks ISO/Fedora-Everything-netinst-x86_64-44-1.7.iso
#
#   VM (manual virt-install with initrd injection):
#     virt-install \
#       --name rabble-os-dev \
#       --ram 4096 --vcpus 2 --disk size=20 \
#       --location /path/to/Fedora-Everything-netinst-x86_64-44-1.7.iso \
#       --initrd-inject RaBbLE-OS.ks \
#       --extra-args "inst.ks=file:/RaBbLE-OS.ks"
#
# WHAT THIS DOES:
#   1. Installs Fedora 44 minimal base
#   2. Sets up user 'rabble' with passwordless sudo
#   3. Enables a firstboot systemd service (After=network-online.target) that
#      clones Collective/Grimoire/OS (retry with backoff) and then runs Bootstrap
#   NOTE: the clone happens on FIRST BOOT, not during %post — installer-chroot
#   networking is a race even with `network --activate`; a post-boot systemd
#   target is a real guarantee. See fix/RaBbLE-OS-KnownIssues.md if you land at
#   a blank TTY with no ~/RaBbLE and no rabble-os-setup.service.
#   After first boot: Ansible installs base + boot + desktop (Hyprland + GNOME)
#   Result: SDDM greeter listing both a Hyprland and a GNOME session on first login
#   — GNOME ships here as a first-class fallback DE (vanilla Shell, zero
#   extensions, Aether-themed, no GDM — see RaBbLE-Grimoire
#   RaBbLE-OS/desktop/RaBbLE-OS-Desktop-Gnome.md). `apply all`/upgrade on an
#   already-installed system still treats it as opt-in (`layerctl apply gnome`)
#   — only this firstboot path defaults it on, via RABBLE_EXTRA_VARS below.
#
# PARTITIONING:
#   Default: auto LVM on btrfs (good for VMs)
#   Bare metal: remove the clearpart/autopart lines and Anaconda will
#   show its graphical partitioner interactively.
#
# PASSWORD:
#   The placeholder __RABBLE_PASSWORD_HASH__ is replaced at cast time by vmctl.
#   vmctl uses 'rabble' as the default VM password (override with RABBLE_PASSWORD env var).
#   For bare metal: set RABBLE_PASSWORD before casting, or edit the generated KS.
# ==============================================================================

# ── Locale & keyboard ──────────────────────────────────────────────────────────
lang en_US.UTF-8
keyboard --vckeymap=us --xlayouts='us'
timezone America/Los_Angeles --utc

# ── Network ───────────────────────────────────────────────────────────────────
network --bootproto=dhcp --device=link --activate --onboot=yes
network --hostname=rabble-os

# ── Installation source ──────────────────────────────────────────────────────
# Netinstall ISO has no packages — fetch from Fedora mirrors
url --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-44&arch=x86_64

# ── Users ─────────────────────────────────────────────────────────────────────
# Lock root — all access via sudo
rootpw --lock

# Main user. Password hash injected at cast time by vmctl.
# Placeholder __RABBLE_PASSWORD_HASH__ is replaced with: openssl passwd -6 '<password>'
user --name=rabble --groups=wheel --gecos="RaBbLE" --password=__RABBLE_PASSWORD_HASH__ --iscrypted

# ── Bootloader ────────────────────────────────────────────────────────────────
bootloader --location=mbr --append="quiet rhgb console=tty0 console=ttyS0,115200n8"

# ── Partitioning ──────────────────────────────────────────────────────────────
# VM: auto LVM/btrfs — remove these two lines for interactive Anaconda partitioning
clearpart --all --initlabel --disklabel=gpt
autopart --type=btrfs

# ── Reboot after install ─────────────────────────────────────────────────────
reboot

# ── Software selection ────────────────────────────────────────────────────────
# Generated from manifest.yml (ks: true, platform: all, source: fedora)
# Regenerate with: python3 spells/generate-kickstart.py
%packages
@core
NetworkManager
NetworkManager-wifi
ansible
curl
git
polkit
python3
%end

# ── Post-install ──────────────────────────────────────────────────────────────
%post --erroronfail
#!/bin/bash
set -euo pipefail

echo "[RaBbLE-OS KS] Starting post-install setup..."

# ── Passwordless sudo for setup phase ─────────────────────────────────────────
# Bootstrap.sh removes this after hardening (future: Phase 5 idempotency gate)
echo "rabble ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/10-rabble-setup
chmod 440 /etc/sudoers.d/10-rabble-setup

# ── Firstboot script: clone Collective/Grimoire/OS, then run Bootstrap ───────
# Deliberately NOT done here in %post: this script runs inside the installer's
# own chroot, where network state is whatever DHCP/NetworkManager happened to
# reach by this instant — a race, even with `network --activate` set above.
# One earlier version cloned here directly with no retry; a single lost race
# meant a silent early exit (exit 0 "succeeds" under --erroronfail) and NONE
# of Grimoire/OS/the firstboot service/serial console got set up — landing at
# a blank TTY with no ~/RaBbLE at all. A post-boot systemd unit gated on
# network-online.target is a real guarantee instead of a race, so the clone
# moves there, with retry/backoff as defense in depth.
# Canonical structure once it runs: ~/RaBbLE/ (Collective root)
#   ~/RaBbLE/RaBbLE-Grimoire/   (knowledge layer)
#   ~/RaBbLE/RaBbLE-OS/         (this member)
mkdir -p /usr/local/sbin
cat > /usr/local/sbin/rabble-os-firstboot.sh << 'FIRSTBOOTEOF'
#!/usr/bin/env bash
# rabble-os-firstboot.sh — clone Collective/Grimoire/OS, then hand off to
# Bootstrap. Runs as 'rabble' via rabble-os-setup.service (network-online.target).
set -uo pipefail

RABBLE_ROOT="/home/rabble/RaBbLE"
GH_BASE="https://github.com/markm1206"
# Branch placeholders replaced at cast time by vmctl (--branch). All three
# members track the same branch in lockstep. Fallback if KS used without vmctl.
COLLECTIVE_BRANCH="__RABBLE_BRANCH__"
GRIMOIRE_BRANCH="__RABBLE_BRANCH__"
OS_BRANCH="__RABBLE_BRANCH__"
[[ "$COLLECTIVE_BRANCH" == __RABBLE_BRANCH__ ]] && COLLECTIVE_BRANCH="new-horizons"
[[ "$GRIMOIRE_BRANCH"   == __RABBLE_BRANCH__ ]] && GRIMOIRE_BRANCH="new-horizons"
[[ "$OS_BRANCH"         == __RABBLE_BRANCH__ ]] && OS_BRANCH="new-horizons"

log() { echo "[rabble-os-firstboot] $*"; }

wait_for_network() {
    log "Waiting for network..."
    local tries=0 max=60   # up to 5 min (5s * 60)
    until getent hosts github.com &>/dev/null; do
        if (( tries++ >= max )); then
            log "WARNING: github.com never resolved after $((max*5))s — trying anyway."
            return 0
        fi
        sleep 5
    done
    log "Network is up (github.com resolves) after $((tries*5))s."
}

clone_with_retry() {
    local url="$1" dest="$2" branch="$3"
    if [[ -d "$dest/.git" ]]; then
        log "Already cloned: $dest — skipping."
        return 0
    fi
    [[ -e "$dest" ]] && { log "Removing incomplete $dest"; rm -rf "$dest"; }

    local attempt=1 max=6 delay=10
    while (( attempt <= max )); do
        log "Cloning $url -> $dest (attempt $attempt/$max)"
        git clone -b "$branch" "$url" "$dest" && return 0
        log "Clone failed, retrying in ${delay}s..."
        sleep "$delay"
        (( attempt++ ))
        (( delay *= 2 ))
    done
    log "ERROR: giving up on $url after $max attempts."
    return 1
}

wait_for_network
mkdir -p "$RABBLE_ROOT"

clone_with_retry "${GH_BASE}/RaBbLE-Collective.git" "$RABBLE_ROOT" "$COLLECTIVE_BRANCH" || exit 1
clone_with_retry "${GH_BASE}/RaBbLE-Grimoire.git" "${RABBLE_ROOT}/RaBbLE-Grimoire" "$GRIMOIRE_BRANCH" || exit 1
clone_with_retry "${GH_BASE}/RaBbLE-OS.git" "${RABBLE_ROOT}/RaBbLE-OS" "$OS_BRANCH" || exit 1

log "Clone complete — handing off to Bootstrap."
cd "${RABBLE_ROOT}/RaBbLE-OS"
exec ./RaBbLE-OS-Bootstrap.sh --unattended --inventory ansible/inventory/vm.hosts.yml
FIRSTBOOTEOF
chmod 755 /usr/local/sbin/rabble-os-firstboot.sh

# ── Firstboot setup service ───────────────────────────────────────────────────
# Clones the repos (retry with backoff) and runs Bootstrap (base + boot +
# desktop + gnome) once network is genuinely up post-boot.
# gnome's play is gated by rabble_enable_gnome_desktop (default false, so
# `apply all`/upgrade on an already-installed system never adds it silently) —
# RABBLE_EXTRA_VARS flips it on for this firstboot run only, same mechanism
# layerctl's `apply gnome` uses (see RaBbLE-OS-layerctl.sh LAYER_EXTRA_VARS).
# Monitor with: journalctl -u rabble-os-setup -f
# After completion: SDDM greeter appears listing both Hyprland and GNOME.
cat > /etc/systemd/system/rabble-os-setup.service << 'SVCEOF'
[Unit]
Description=RaBbLE-OS First-Boot Setup (clone + base + boot + desktop + gnome)
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/rabble-os/.setup-complete

[Service]
Type=oneshot
User=rabble
Environment=RABBLE_TAGS=base,boot,desktop,gnome
Environment=RABBLE_EXTRA_VARS=rabble_enable_gnome_desktop=true
Environment=TERM=xterm-256color
ExecStartPre=+/bin/mkdir -p /var/lib/rabble-os
ExecStart=/usr/local/sbin/rabble-os-firstboot.sh
ExecStartPost=+/bin/touch /var/lib/rabble-os/.setup-complete
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl enable rabble-os-setup.service

# ── Serial console for TUI/CLI access ────────────────────────────────────────
# Enables `vmctl console` (virsh console) without needing a GUI/SPICE session.
systemctl enable serial-getty@ttyS0.service

echo "[RaBbLE-OS KS] Post-install complete."
echo ""
echo "  Structure (created on FIRST BOOT, not during install):"
echo "    ~/RaBbLE/                  (Collective root)"
echo "    ~/RaBbLE/RaBbLE-Grimoire/  (knowledge layer)"
echo "    ~/RaBbLE/RaBbLE-OS/        (OS member)"
echo ""
echo "  Next: reboot → firstboot service clones the repos, then runs Bootstrap"
echo "  (base + boot + desktop + gnome). Watch it with:"
echo "    journalctl -u rabble-os-setup -f"
echo "  After completion: SDDM greeter lists Hyprland and GNOME sessions."
echo "  To install apps post-login:"
echo "    cd ~/RaBbLE/RaBbLE-OS"
echo "    RABBLE_TAGS=apps ./RaBbLE-OS-Bootstrap.sh \\"
echo "        --inventory ansible/inventory/vm.hosts.yml"
echo ""

%end
