# ==============================================================================
# RaBbLE-OS.ks — Tier 1 Kickstart
# Phase 4 installer deliverable (Plot C — Installer)
#
# USAGE:
#   Bare metal (recommended) — bake this KS into a RaBbLE-OS netinstall ISO:
#     spells/build-iso.sh ISO/Fedora-Everything-netinst-x86_64-44-1.7.iso
#     → ISO/RaBbLE-OS-<branch>.iso, flash to USB, boot it. No OEMDRV/boot-line edits.
#
#   VM (automated):
#     ./RaBbLE-OS-vmctl.sh cast-ks ISO/Fedora-Everything-netinst-x86_64-44-1.7.iso
#
# TEMPLATE MARKERS (this file is never used raw — both tools above render it):
#   __RABBLE_BRANCH__   → branch cloned for Collective/Grimoire/OS (both tools)
#   #@VM@ <line>        → uncommented by vmctl only: unattended user, disk, NIC,
#                         serial console. Bare metal leaves them commented, so
#                         Anaconda shows the Installation Destination, User
#                         Creation and Network (WiFi) spokes interactively.
#   <line> #@BARE@      → deleted by vmctl (bare-metal-only variant of a #@VM@ line)
#   __RABBLE_PASSWORD_HASH__ → VM password hash, injected by vmctl
#
# WHAT THIS DOES:
#   1. Installs Fedora 44 minimal base + git/ansible
#   2. %post (still inside the installer, before the reboot) clones
#      Collective/Grimoire/OS and runs Bootstrap (base + boot + desktop + gnome)
#      in the new system's chroot — first boot lands on the themed SDDM greeter
#      listing Hyprland and GNOME. Watch it live: Alt+F2 (or Ctrl+Alt+F2), then
#        tail -f /mnt/sysroot/var/log/rabble-os-install.log
#   3. If that in-installer run fails for any reason, rabble-os-setup.service
#      (enabled regardless) retries the same script on first boot, after
#      network-online.target. Install never aborts over an Ansible failure.
#
# USER:
#   Bare metal: create the user interactively (any username — %post detects the
#   first UID ≥ 1000 account; tick "make administrator"). VM: 'rabble' / $RABBLE_PASSWORD.
#   A partial `user` line locks the spoke (KnownIssues S231), hence #@VM@ only.
# ==============================================================================

# ── Locale & keyboard ──────────────────────────────────────────────────────────
lang en_US.UTF-8
keyboard --vckeymap=us --xlayouts='us'
timezone America/Los_Angeles --utc

# ── Network ───────────────────────────────────────────────────────────────────
# Bare metal: no --device/--activate so Anaconda's WiFi picker stays usable
# (KS `network` has no WPA support). The connection it makes persists into %post.
#@VM@ network --bootproto=dhcp --device=link --activate --onboot=yes
network --hostname=rabble-os

# ── Installation source ──────────────────────────────────────────────────────
# Netinstall ISO has no packages — fetch from Fedora mirrors
url --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-44&arch=x86_64

# ── Users ─────────────────────────────────────────────────────────────────────
# Lock root — all access via sudo
rootpw --lock
#@VM@ user --name=rabble --groups=wheel --gecos="RaBbLE" --password=__RABBLE_PASSWORD_HASH__ --iscrypted

# ── Bootloader ────────────────────────────────────────────────────────────────
# Serial console is VM-only: a trailing console=ttyS0 makes it /dev/console,
# which is wrong for a bare-metal Plymouth boot.
bootloader --location=mbr --append="quiet rhgb" #@BARE@
#@VM@ bootloader --location=mbr --append="quiet rhgb console=tty0 console=ttyS0,115200n8"

# ── Partitioning ──────────────────────────────────────────────────────────────
# Bare metal: interactive Installation Destination spoke. VM: wipe + auto btrfs.
#@VM@ clearpart --all --initlabel --disklabel=gpt
#@VM@ autopart --type=btrfs

# ── Reboot after install ─────────────────────────────────────────────────────
reboot

# ── Software selection ────────────────────────────────────────────────────────
# Generated from manifest.yml (ks: true, platform: all, source: fedora)
# Regenerate with: python3 spells/generate-kickstart.py
%packages
@core
@hardware-support
NetworkManager
NetworkManager-wifi
ansible
curl
git
polkit
python3
%end

# ── Post-install (outside chroot): hand the installer's DNS to the target ─────
# Fedora's /etc/resolv.conf is a symlink into systemd-resolved's /run, which
# the target chroot doesn't have running — so name resolution inside %post can
# fail even though the installer itself just downloaded every package. This is
# the most likely real cause of the S232 "clone race". Stash a resolved copy;
# the chrooted %post swaps it in only if github.com doesn't already resolve.
%post --nochroot
cp -L /etc/resolv.conf "${ANA_INSTALL_PATH:-/mnt/sysroot}/root/.rabble-resolv.conf" 2>/dev/null || true
%end

# ── Post-install (chroot): firstboot script + service, then run it NOW ────────
%post --erroronfail --log=/var/log/rabble-os-ks-post.log
#!/bin/bash
set -euo pipefail

echo "[RaBbLE-OS KS] Starting post-install setup..."

# ── Target user: whoever Anaconda created (VM: rabble; bare metal: typed) ─────
RABBLE_USER="$(awk -F: '$3 >= 1000 && $3 < 60000 { print $1; exit }' /etc/passwd)"
if [[ -z "$RABBLE_USER" ]]; then
    echo "[RaBbLE-OS KS] ERROR: no regular user account was created — create one on the User Creation screen."
    exit 1
fi
RABBLE_HOME="$(getent passwd "$RABBLE_USER" | cut -d: -f6)"
echo "[RaBbLE-OS KS] Target user: ${RABBLE_USER} (${RABBLE_HOME})"

# ── Passwordless sudo for setup phase ─────────────────────────────────────────
# Bootstrap runs unattended (no TTY to prompt on). Not yet removed after setup
# (future: Phase 5 idempotency gate). SYSTEMD_OFFLINE survives sudo's env_reset
# so become-tasks inside the installer chroot never talk to the live systemd.
cat > /etc/sudoers.d/10-rabble-setup << SUDOEOF
${RABBLE_USER} ALL=(ALL) NOPASSWD: ALL
Defaults env_keep += "SYSTEMD_OFFLINE"
SUDOEOF
chmod 440 /etc/sudoers.d/10-rabble-setup

# ── Firstboot script: clone Collective/Grimoire/OS, then run Bootstrap ───────
# Runs twice at most: once right below (inside the installer), and again from
# rabble-os-setup.service on first boot only if that first run didn't finish.
# Canonical structure once it runs: ~/RaBbLE/ (Collective root)
#   ~/RaBbLE/RaBbLE-Grimoire/   (knowledge layer)
#   ~/RaBbLE/RaBbLE-OS/         (this member)
#   ~/RaBbLE/RaBbLE-Aether/     (theme source Ansible deploys from)
mkdir -p /usr/local/sbin
cat > /usr/local/sbin/rabble-os-firstboot.sh << 'FIRSTBOOTEOF'
#!/usr/bin/env bash
# rabble-os-firstboot.sh — clone Collective/Grimoire/OS/Aether, then hand off to
# Bootstrap. Runs as the install user, from KS %post (installer chroot) and,
# as a fallback, from rabble-os-setup.service (network-online.target).
set -uo pipefail

RABBLE_ROOT="${HOME}/RaBbLE"
GH_BASE="https://github.com/RaBbLE-Collective"
# Branch placeholders replaced at render time (vmctl --branch / build-iso.sh).
# All members track the same branch in lockstep.
COLLECTIVE_BRANCH="__RABBLE_BRANCH__"
GRIMOIRE_BRANCH="__RABBLE_BRANCH__"
OS_BRANCH="__RABBLE_BRANCH__"
AETHER_BRANCH="__RABBLE_BRANCH__"
[[ "$COLLECTIVE_BRANCH" == __RABBLE_BRANCH__ ]] && COLLECTIVE_BRANCH="new-horizons"
[[ "$GRIMOIRE_BRANCH"   == __RABBLE_BRANCH__ ]] && GRIMOIRE_BRANCH="new-horizons"
[[ "$OS_BRANCH"         == __RABBLE_BRANCH__ ]] && OS_BRANCH="new-horizons"
[[ "$AETHER_BRANCH"     == __RABBLE_BRANCH__ ]] && AETHER_BRANCH="new-horizons"

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
# Aether is the theme source Ansible reads (aether_repo_root): GNOME/GTK
# index.theme, Qt/GTK + VSCodium themes, Firefox CSS (config/firefox symlinks).
clone_with_retry "${GH_BASE}/RaBbLE-Aether.git" "${RABBLE_ROOT}/RaBbLE-Aether" "$AETHER_BRANCH" || exit 1

log "Clone complete — handing off to Bootstrap."
cd "${RABBLE_ROOT}/RaBbLE-OS" || exit 1
./RaBbLE-OS-Bootstrap.sh --unattended --inventory ansible/inventory/vm.hosts.yml
rc=$?

# Ansible's dotfile tasks are stubs; user configs (hypr, waybar, kitty, zsh, …)
# deploy only through dotctl. Run it even if Bootstrap failed, so a retry-bound
# install still logs in to a configured shell. Plain file copies: chroot-safe.
log "Deploying dotfiles (dotctl apply all)."
./RaBbLE-OS-dotctl.sh apply all
dot_rc=$?
(( rc != 0 )) && exit "$rc"
exit "$dot_rc"
FIRSTBOOTEOF
chmod 755 /usr/local/sbin/rabble-os-firstboot.sh

# ── Firstboot fallback service ────────────────────────────────────────────────
# Skipped entirely (ConditionPathExists) when the in-installer run below
# succeeds. gnome's play is gated by rabble_enable_gnome_desktop (default
# false, so `apply all`/upgrade on an installed system never adds it silently)
# — RABBLE_EXTRA_VARS flips it on for the install only, same mechanism
# layerctl's `apply gnome` uses (see RaBbLE-OS-layerctl.sh LAYER_EXTRA_VARS).
# Monitor with: journalctl -u rabble-os-setup -f
RABBLE_TAGS="base,boot,desktop,gnome"
RABBLE_EXTRA_VARS="rabble_enable_gnome_desktop=true"
cat > /etc/systemd/system/rabble-os-setup.service << SVCEOF
[Unit]
Description=RaBbLE-OS First-Boot Setup (fallback: clone + base + boot + desktop + gnome)
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/rabble-os/.setup-complete

[Service]
Type=oneshot
User=${RABBLE_USER}
WorkingDirectory=${RABBLE_HOME}
Environment=HOME=${RABBLE_HOME}
Environment=RABBLE_TAGS=${RABBLE_TAGS}
Environment=RABBLE_EXTRA_VARS=${RABBLE_EXTRA_VARS}
Environment=TERM=xterm-256color
ExecStartPre=+/bin/mkdir -p /var/lib/rabble-os
ExecStart=/usr/local/sbin/rabble-os-firstboot.sh
ExecStartPost=+/bin/touch /var/lib/rabble-os/.setup-complete
RemainAfterExit=yes
TimeoutStartSec=infinity
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl enable rabble-os-setup.service

# ── Serial console for TUI/CLI access (vmctl console; harmless on bare metal) ─
systemctl enable serial-getty@ttyS0.service

# ── Run Bootstrap NOW, inside the installer ───────────────────────────────────
# Everything above must succeed (--erroronfail); this block must never fail the
# install — a miss just leaves the firstboot service to retry after reboot.
RESOLV_SWAPPED=false
if ! getent hosts github.com &>/dev/null && [[ -s /root/.rabble-resolv.conf ]]; then
    echo "[RaBbLE-OS KS] DNS not resolving in chroot — borrowing the installer's resolv.conf."
    mv /etc/resolv.conf /etc/resolv.conf.rabble-orig 2>/dev/null || true
    cp /root/.rabble-resolv.conf /etc/resolv.conf
    RESOLV_SWAPPED=true
fi

INSTALL_LOG=/var/log/rabble-os-install.log
echo "[RaBbLE-OS KS] Running Bootstrap (${RABBLE_TAGS}) — log: ${INSTALL_LOG}"
set +e
runuser -u "$RABBLE_USER" -- env -i \
    HOME="$RABBLE_HOME" USER="$RABBLE_USER" LOGNAME="$RABBLE_USER" \
    PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin \
    LANG=en_US.UTF-8 TERM=xterm-256color SYSTEMD_OFFLINE=1 \
    RABBLE_TAGS="$RABBLE_TAGS" RABBLE_EXTRA_VARS="$RABBLE_EXTRA_VARS" \
    bash -c 'cd "$HOME" && /usr/local/sbin/rabble-os-firstboot.sh' \
    > "$INSTALL_LOG" 2>&1
BOOTSTRAP_RC=$?
set -e

if [[ "$RESOLV_SWAPPED" == "true" ]]; then
    rm -f /etc/resolv.conf
    mv /etc/resolv.conf.rabble-orig /etc/resolv.conf 2>/dev/null || true
fi
rm -f /root/.rabble-resolv.conf

mkdir -p /var/lib/rabble-os
if (( BOOTSTRAP_RC == 0 )); then
    touch /var/lib/rabble-os/.setup-complete
    echo "[RaBbLE-OS KS] Bootstrap complete — first boot goes straight to SDDM."
else
    echo "[RaBbLE-OS KS] WARNING: Bootstrap exited ${BOOTSTRAP_RC} — see ${INSTALL_LOG}."
    echo "[RaBbLE-OS KS] rabble-os-setup.service will retry on first boot."
fi

# ── SELinux labels ────────────────────────────────────────────────────────────
# Files Ansible wrote from inside the chroot may carry installer contexts
# (SDDM theme, /etc drop-ins, ~/.config). Relabel offline against the target's
# own policy; if that can't run, fall back to a full relabel on first boot.
if ! setfiles -F -e /proc -e /sys -e /dev -e /run -e /boot/efi \
        /etc/selinux/targeted/contexts/files/file_contexts / >/dev/null 2>&1; then
    echo "[RaBbLE-OS KS] setfiles failed — scheduling a first-boot autorelabel."
    touch /.autorelabel
fi

echo "[RaBbLE-OS KS] Post-install complete."
echo "  Collective root: ${RABBLE_HOME}/RaBbLE"
echo "  Install log:     ${INSTALL_LOG}"
echo "  To install apps post-login:"
echo "    cd ~/RaBbLE/RaBbLE-OS && ./RaBbLE-OS-layerctl.sh apply apps"

%end
