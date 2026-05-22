# ==============================================================================
# RaBbLE-OS.ks — Tier 1 Kickstart
# Phase 4 installer deliverable (Plot C — Installer)
#
# USAGE:
#   Boot Fedora 44 Everything netinstall ISO with inst.ks pointing here.
#
#   VM (virt-install):
#     virt-install \
#       --name rabble-os-dev \
#       --ram 4096 --vcpus 2 --disk size=40 \
#       --cdrom /path/to/Fedora-Everything-netinst-x86_64-44-1.7.iso \
#       --extra-args "inst.ks=file:///path/to/RaBbLE-OS.ks"
#
#   Or serve this file over HTTP and pass:
#     inst.ks=http://<host>/RaBbLE-OS.ks
#
# WHAT THIS DOES:
#   1. Installs Fedora 44 minimal base
#   2. Sets up user 'rabble' with passwordless sudo
#   3. Clones the RaBbLE-OS repo
#   4. Enables a firstboot systemd service that runs Bootstrap (Phase 1)
#   After first boot: SDDM greeter appears (Phase 1 done)
#   After login: run Bootstrap with desktop,apps tags for full DE
#
# PARTITIONING:
#   Default: auto LVM on btrfs (good for VMs)
#   Bare metal: remove the clearpart/autopart lines and Anaconda will
#   show its graphical partitioner interactively.
#
# PASSWORD:
#   Default plaintext password: rabble
#   Change before bare-metal use:
#     openssl passwd -6 'yourpassword'
#   Then replace --password=__RABBLE_PASSWORD_HASH__ --iscrypted with --password=<hash>
# ==============================================================================

# ── Locale & keyboard ──────────────────────────────────────────────────────────
lang en_US.UTF-8
keyboard --vckeymap=us --xlayouts='us'
timezone America/Los_Angeles --utc

# ── Network ───────────────────────────────────────────────────────────────────
network --bootproto=dhcp --device=link --activate --onboot=yes
network --hostname=rabble-os

# ── Users ─────────────────────────────────────────────────────────────────────
# Lock root — all access via sudo
rootpw --lock

# Main user. For VMs: --plaintext is fine.
# For bare metal: replace with --password=<openssl passwd -6 hash>
user --name=rabble --groups=wheel --gecos="RaBbLE" --password=__RABBLE_PASSWORD_HASH__ --iscrypted

# ── Bootloader ────────────────────────────────────────────────────────────────
bootloader --location=mbr --append="quiet rhgb"

# ── Partitioning ──────────────────────────────────────────────────────────────
# VM: auto LVM/btrfs — remove these two lines for interactive Anaconda partitioning
clearpart --all --initlabel --disklabel=gpt
autopart --type=btrfs

# ── Software selection ────────────────────────────────────────────────────────
# Generated from manifest.yml (ks: true, platform: all, source: fedora)
# Regenerate with: python3 spells/generate-kickstart.py
%packages
@^minimal-environment
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

# ── Clone RaBbLE-OS repo ──────────────────────────────────────────────────────
REPO_URL="https://github.com/markm1206/RaBbLE-OS.git"
REPO_DIR="/home/rabble/RaBbLE-OS"

echo "[RaBbLE-OS KS] Cloning ${REPO_URL} → ${REPO_DIR}"
sudo -u rabble git clone "${REPO_URL}" "${REPO_DIR}" || {
    echo "[RaBbLE-OS KS] WARNING: git clone failed — check network in %post"
    echo "[RaBbLE-OS KS] After first boot, manually run:"
    echo "  git clone ${REPO_URL} ~/RaBbLE-OS && cd ~/RaBbLE-OS"
    echo "  RABBLE_TAGS=base,boot ./RaBbLE-OS-Bootstrap.sh --inventory ansible/inventory/vm.hosts.yml"
    exit 0  # non-fatal — firstboot service will notice missing dir
}

# ── Firstboot setup service ───────────────────────────────────────────────────
# Runs Bootstrap (Phase 1: base + boot → SDDM) on first boot after network is up.
# Monitor with: journalctl -u rabble-os-setup -f
# After SDDM: log in and run the desktop layer manually (see below).
cat > /etc/systemd/system/rabble-os-setup.service << 'SVCEOF'
[Unit]
Description=RaBbLE-OS First-Boot Setup (Phase 1 — base + boot)
After=network-online.target
Wants=network-online.target
ConditionPathExists=/home/rabble/RaBbLE-OS/RaBbLE-OS-Bootstrap.sh
ConditionPathExists=!/var/lib/rabble-os/.setup-complete

[Service]
Type=oneshot
User=rabble
WorkingDirectory=/home/rabble/RaBbLE-OS
Environment=RABBLE_TAGS=base,boot
ExecStartPre=/bin/mkdir -p /var/lib/rabble-os
ExecStart=/home/rabble/RaBbLE-OS/RaBbLE-OS-Bootstrap.sh \
    --unattended \
    --inventory ansible/inventory/vm.hosts.yml
ExecStartPost=/bin/touch /var/lib/rabble-os/.setup-complete
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl enable rabble-os-setup.service

echo "[RaBbLE-OS KS] Post-install complete."
echo ""
echo "  Next: reboot → firstboot service runs Bootstrap (Phase 1)"
echo "  After SDDM appears, log in and run:"
echo "    cd ~/RaBbLE-OS"
echo "    RABBLE_TAGS=desktop,apps ./RaBbLE-OS-Bootstrap.sh \\"
echo "        --inventory ansible/inventory/vm.hosts.yml"
echo ""

%end
