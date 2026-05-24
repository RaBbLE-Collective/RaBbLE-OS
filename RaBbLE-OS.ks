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
#   3. Clones the RaBbLE-OS repo
#   4. Enables a firstboot systemd service that runs Bootstrap
#   After first boot: Ansible installs base + boot + desktop (Hyprland)
#   Result: SDDM greeter with a working Hyprland session on first login
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

# ── Clone Collective + Grimoire + RaBbLE-OS ──────────────────────────────────
# Canonical structure: ~/RaBbLE/ (Collective root)
#   ~/RaBbLE/RaBbLE-Grimoire/   (knowledge layer)
#   ~/RaBbLE/RaBbLE-OS/         (this member)
# Skips other members — install only what the OS needs.

RABBLE_ROOT="/home/rabble/RaBbLE"
GH_BASE="https://github.com/markm1206"
COLLECTIVE_BRANCH="dev"
GRIMOIRE_BRANCH="dev"
OS_BRANCH="RaBbLE-OS-New-Horizons"

clone_as_rabble() {
    local url="$1" dest="$2" branch="${3:-}"
    local branch_flag=""
    [[ -n "$branch" ]] && branch_flag="-b $branch"
    echo "[RaBbLE-OS KS] Cloning ${url} → ${dest}"
    # shellcheck disable=SC2086
    sudo -u rabble git clone $branch_flag "$url" "$dest"
}

# Step 1: Collective (the root working directory)
clone_as_rabble "${GH_BASE}/RaBbLE-Collective.git" "$RABBLE_ROOT" "$COLLECTIVE_BRANCH" || {
    echo "[RaBbLE-OS KS] WARNING: Collective clone failed"
    exit 0
}

# Step 2: Grimoire (knowledge layer — agent docs, palette, registry)
clone_as_rabble "${GH_BASE}/RaBbLE-Grimoire.git" "${RABBLE_ROOT}/RaBbLE-Grimoire" "$GRIMOIRE_BRANCH" || {
    echo "[RaBbLE-OS KS] WARNING: Grimoire clone failed"
    exit 0
}

# Step 3: RaBbLE-OS (the member we need for Bootstrap)
clone_as_rabble "${GH_BASE}/RaBbLE-OS.git" "${RABBLE_ROOT}/RaBbLE-OS" "$OS_BRANCH" || {
    echo "[RaBbLE-OS KS] WARNING: RaBbLE-OS clone failed"
    echo "[RaBbLE-OS KS] After first boot, manually run:"
    echo "  cd ~/RaBbLE/RaBbLE-OS && RABBLE_TAGS=base,boot,desktop ./RaBbLE-OS-Bootstrap.sh --unattended --inventory ansible/inventory/vm.hosts.yml"
    exit 0
}

# ── Firstboot setup service ───────────────────────────────────────────────────
# Runs Bootstrap (base + boot + desktop) on first boot after network is up.
# Monitor with: journalctl -u rabble-os-setup -f
# After completion: SDDM greeter appears with Hyprland session ready.
cat > /etc/systemd/system/rabble-os-setup.service << 'SVCEOF'
[Unit]
Description=RaBbLE-OS First-Boot Setup (base + boot + desktop)
After=network-online.target
Wants=network-online.target
ConditionPathExists=/home/rabble/RaBbLE/RaBbLE-OS/RaBbLE-OS-Bootstrap.sh
ConditionPathExists=!/var/lib/rabble-os/.setup-complete

[Service]
Type=oneshot
User=rabble
WorkingDirectory=/home/rabble/RaBbLE/RaBbLE-OS
Environment=RABBLE_TAGS=base,boot,desktop
ExecStartPre=+/bin/mkdir -p /var/lib/rabble-os
ExecStart=/bin/bash /home/rabble/RaBbLE/RaBbLE-OS/RaBbLE-OS-Bootstrap.sh \
    --unattended \
    --inventory ansible/inventory/vm.hosts.yml
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
echo "  Structure:"
echo "    ~/RaBbLE/                  (Collective root)"
echo "    ~/RaBbLE/RaBbLE-Grimoire/  (knowledge layer)"
echo "    ~/RaBbLE/RaBbLE-OS/        (OS member)"
echo ""
echo "  Next: reboot → firstboot service runs Bootstrap (base + boot + desktop)"
echo "  After completion: SDDM greeter with Hyprland session ready."
echo "  To install apps post-login:"
echo "    cd ~/RaBbLE/RaBbLE-OS"
echo "    RABBLE_TAGS=apps ./RaBbLE-OS-Bootstrap.sh \\"
echo "        --inventory ansible/inventory/vm.hosts.yml"
echo ""

%end
