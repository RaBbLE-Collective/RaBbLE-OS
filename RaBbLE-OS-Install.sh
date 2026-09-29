#!/usr/bin/env bash
# ==============================================================================
# RaBbLE-OS-Install.sh
# Bootstrap installer — transforms Fedora 44+ Sway spin into RaBbLE-OS
# Version: 0.0.1
#
# Curl install (HTTPS clone — no SSH key required):
#   curl -fsSL https://raw.githubusercontent.com/RaBbLE-Collective/RaBbLE-OS/main/RaBbLE-OS-Install.sh | bash
#
# Local run (SSH clone — SSH key must already be registered):
#   bash RaBbLE-OS-Install.sh
#
# Override repo or destination:
#   RABBLE_OS_REPO=git@github.com:yourfork/RaBbLE-OS.git bash RaBbLE-OS-Install.sh
#   RABBLE_OS_DIR=~/my-rabble bash RaBbLE-OS-Install.sh
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── Colour palette ─────────────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m';     RESET='\033[0m'

# ── Config ─────────────────────────────────────────────────────────────────────
RABBLE_OS_VERSION="0.0.0.0"   # Five-Es; keep in step with all.yml rabble_os_version
# HTTPS is the default — works immediately from curl without SSH key pre-registered.
# After install, the SSH key setup converts your working copy remote to SSH if desired.
# Override with: RABBLE_OS_REPO=git@github.com:RaBbLE-Collective/RaBbLE-OS.git bash install.sh
RABBLE_OS_REPO="${RABBLE_OS_REPO:-https://github.com/RaBbLE-Collective/RaBbLE-OS.git}"
RABBLE_OS_DIR="${RABBLE_OS_DIR:-$HOME/RaBbLE-OS}"
MIN_FEDORA_VERSION=44
SSH_CONFIG="$HOME/.ssh/config"
GIT_SSH_KEY="$HOME/.ssh/id_ed25519"

# ── Helpers ────────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; \
            echo -e "${BOLD}${CYAN}  $*${RESET}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}\n"; }

banner() {
cat << 'EOF'

  ██████╗         ██████╗ ██╗     ██╗     ███████╗    ██████╗ ███████╗
  ██╔══██╗        ██╔══██╗██║     ██║     ██╔════╝   ██╔═══██╗██╔════╝
  ██████╔╝ █████╗ ██████╔╝██████  ██║     █████╗     ██║   ██║███████╗
  ██╔══██╗ █   █║ ██╔══██╗██╔══██╗██║     ██╔══╝     ██║   ██║╚════██║
  ██║  ██║ ╚█████ ██████╔╝██████╔╝███████╗███████╗   ╚██████╔╝███████║
  ╚═╝  ╚═╝    ╚═█ ╚═════╝ ╚═════╝ ╚══════╝╚══════╝    ╚═════╝ ╚══════╝

  The Reasonable and Barely Bearable Linux Experience -- LMAO
  Bootstrap Installer v0.0.1
  ── Sway ──→ RaBbLE-OS ──
EOF
}

# ── Privilege check ────────────────────────────────────────────────────────────
check_not_root() {
    [[ "$EUID" -eq 0 ]] && error "Do NOT run as root. Run as your normal user — sudo will be invoked where needed."
    # Validate sudo access up-front
    info "Validating sudo access..."
    sudo -v || error "sudo access required. Add your user to the sudoers file."
    # Keep sudo timestamp alive in background
    ( while true; do sudo -v; sleep 50; done ) &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT
}

# ── Fedora version enforcement ─────────────────────────────────────────────────
check_fedora_version() {
    section "Verifying OS Prerequisites"

    # Verify this is Fedora
    if ! grep -qi "^ID=fedora" /etc/os-release 2>/dev/null; then
        error "This installer requires Fedora Linux. Detected OS is not Fedora."
    fi

    local version
    version=$(grep -oP '(?<=^VERSION_ID=)\d+' /etc/os-release)

    if [[ -z "$version" ]]; then
        error "Could not determine Fedora version from /etc/os-release."
    fi

    if (( version < MIN_FEDORA_VERSION )); then
        error "Fedora ${MIN_FEDORA_VERSION}+ required. Detected: Fedora ${version}. Please upgrade your system."
    fi

    success "Fedora ${version} detected — meets minimum requirement (${MIN_FEDORA_VERSION}+)."
}

# ── DNF helpers ────────────────────────────────────────────────────────────────
dnf_install() {
    local pkg="$1"
    if rpm -q "$pkg" &>/dev/null; then
        success "${pkg} already installed — skipping."
    else
        info "Installing ${pkg} via dnf..."
        sudo dnf install -y "$pkg" || error "Failed to install ${pkg}."
        success "${pkg} installed."
    fi
}

dnf_verify_or_install() {
    local pkg="$1"
    local cmd="${2:-$1}"  # optional: command name differs from package name
    if command -v "$cmd" &>/dev/null; then
        success "${cmd} found at $(command -v "$cmd") — no action needed."
    else
        warn "${cmd} not found. Installing ${pkg}..."
        dnf_install "$pkg"
    fi
}

# ── Git installation & identity setup ─────────────────────────────────────────
setup_git() {
    section "Git — Installation & Identity"

    dnf_install "git"

    echo ""
    info "Git identity configuration."
    info "This will set your global git user.name and user.email."
    echo ""

    local current_name current_email
    current_name=$(git config --global user.name  2>/dev/null || echo "")
    current_email=$(git config --global user.email 2>/dev/null || echo "")

    if [[ -n "$current_name" && -n "$current_email" ]]; then
        warn "Existing git identity found:"
        echo "    Name  : ${current_name}"
        echo "    Email : ${current_email}"
        read -rp "  Override? [y/N]: " override
        [[ "${override,,}" != "y" ]] && { success "Keeping existing git identity."; return 0; }
    fi

    local git_name git_email
    while true; do
        read -rp "  Enter your full name  : " git_name
        [[ -n "$git_name" ]] && break
        warn "Name cannot be empty."
    done

    while true; do
        read -rp "  Enter your git email  : " git_email
        # Basic email sanity check
        [[ "$git_email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] && break
        warn "Please enter a valid email address."
    done

    git config --global user.name  "$git_name"
    git config --global user.email "$git_email"
    git config --global init.defaultBranch main
    git config --global core.editor "vim"
    git config --global pull.rebase false

    success "Git identity set → ${git_name} <${git_email}>"

    # Store email globally for SSH key generation
    GIT_EMAIL="$git_email"
}

# ── SSH key generation ─────────────────────────────────────────────────────────
setup_ssh_key() {
    section "SSH Key Generation"

    local email
    email="${GIT_EMAIL:-$(git config --global user.email 2>/dev/null || echo "")}"

    if [[ -z "$email" ]]; then
        error "No git email configured. Run git identity setup first."
    fi

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    if [[ -f "${GIT_SSH_KEY}" ]]; then
        warn "SSH key already exists at: ${GIT_SSH_KEY}"
        read -rp "  Regenerate? (old key will be backed up) [y/N]: " regen
        if [[ "${regen,,}" == "y" ]]; then
            local backup="${GIT_SSH_KEY}.bak.$(date +%s)"
            mv "$GIT_SSH_KEY"     "$backup"
            mv "${GIT_SSH_KEY}.pub" "${backup}.pub" 2>/dev/null || true
            warn "Old key backed up to: ${backup}"
        else
            success "Using existing SSH key."
            print_public_key
            return 0
        fi
    fi

    info "Generating ed25519 SSH key for: ${email}"
    ssh-keygen -t ed25519 -C "${email}" -f "$GIT_SSH_KEY" -N "" || \
        error "SSH key generation failed."

    # Add key to ssh-agent
    eval "$(ssh-agent -s)" &>/dev/null || true
    ssh-add "$GIT_SSH_KEY" 2>/dev/null || warn "Could not add key to ssh-agent (non-fatal)."

    success "SSH key generated: ${GIT_SSH_KEY}"
    print_public_key
}

print_public_key() {
    local pub_key
    pub_key=$(cat "${GIT_SSH_KEY}.pub")

    echo ""
    echo -e "${BOLD}${YELLOW}══════════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${YELLOW}  ACTION REQUIRED: Register this SSH public key with your     ${RESET}"
    echo -e "${BOLD}${YELLOW}  Git remote service (GitHub / GitLab / Gitea / etc.)          ${RESET}"
    echo -e "${BOLD}${YELLOW}══════════════════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "${BOLD}  GitHub  : https://github.com/settings/ssh/new${RESET}"
    echo -e "${BOLD}  GitLab  : https://gitlab.com/-/profile/keys${RESET}"
    echo -e "${BOLD}  Gitea   : https://<your-instance>/user/settings/keys${RESET}"
    echo ""
    echo -e "${GREEN}── BEGIN PUBLIC KEY ───────────────────────────────────────────${RESET}"
    echo "${pub_key}"
    echo -e "${GREEN}── END PUBLIC KEY ─────────────────────────────────────────────${RESET}"
    echo ""
    read -rp "  Press [ENTER] once you have registered the key to continue..."
}

# ── SSH config: port 443 for git remote service ────────────────────────────────
configure_ssh_port() {
    section "SSH — Configure Port 443 for Git Remote"

    info "Configuring SSH to use port 443 for GitHub/GitLab (firewall bypass)."
    info "This updates ~/.ssh/config — safe for existing entries."

    local host_entry
    read -rp "  Configure SSH port 443 for which host? [github.com]: " ssh_host
    ssh_host="${ssh_host:-github.com}"

    # Determine the SSH hostname alias for port 443
    # GitHub uses ssh.github.com:443, GitLab uses altssh.gitlab.com:443
    local ssh_hostname
    case "$ssh_host" in
        github.com)    ssh_hostname="ssh.github.com" ;;
        gitlab.com)    ssh_hostname="altssh.gitlab.com" ;;
        *)             ssh_hostname="$ssh_host" ;;
    esac

    # Idempotent: check if block already exists
    if grep -q "Host ${ssh_host}" "$SSH_CONFIG" 2>/dev/null; then
        warn "SSH config block for ${ssh_host} already exists in ${SSH_CONFIG}."
        warn "Review manually if needed: ${SSH_CONFIG}"
    else
        touch "$SSH_CONFIG"
        chmod 600 "$SSH_CONFIG"

        cat >> "$SSH_CONFIG" << EOF

# ── RaBbLE-OS: ${ssh_host} over port 443 ──────────────────────
Host ${ssh_host}
    HostName       ${ssh_hostname}
    User           git
    Port           443
    IdentityFile   ${GIT_SSH_KEY}
    ServerAliveInterval 60
    ServerAliveCountMax 3
EOF
        success "SSH config updated → ${ssh_host} via port 443 (${ssh_hostname})."
    fi

    # Test the connection
    info "Testing SSH connection to ${ssh_host}..."
    if ssh -T "git@${ssh_host}" 2>&1 | grep -qiE "(success|authenticated|welcome|hi )"; then
        success "SSH connection to ${ssh_host} verified!"
    else
        warn "SSH test inconclusive. This is normal if you haven't registered the key yet."
        warn "You can test manually with: ssh -T git@${ssh_host}"
    fi
}

# ── pip3 ───────────────────────────────────────────────────────────────────────
setup_pip3() {
    section "Verifying pip3"
    dnf_verify_or_install "python3-pip" "pip3"
    # Upgrade pip itself silently
    pip3 install --upgrade pip --quiet 2>/dev/null || warn "pip upgrade non-critical — continuing."
    success "pip3 version: $(pip3 --version)"
}

# ── Ansible ────────────────────────────────────────────────────────────────────
setup_ansible() {
    section "Verifying Ansible"
    dnf_verify_or_install "ansible" "ansible"
    dnf_verify_or_install "ansible-collection-ansible-posix" "ansible" # posix collections
    success "Ansible version: $(ansible --version | head -1)"
}

# ── Clone RaBbLE-OS repo ───────────────────────────────────────────────────────
clone_repo() {
    section "Cloning RaBbLE-OS Repository"

    if [[ -d "$RABBLE_OS_DIR/.git" ]]; then
        warn "RaBbLE-OS repo already exists at: ${RABBLE_OS_DIR}"
        info "Pulling latest changes..."
        git -C "$RABBLE_OS_DIR" pull origin main || \
            warn "Pull failed — continuing with existing local copy."
        success "Repository up-to-date."
        return 0
    fi

    info "Cloning from: ${RABBLE_OS_REPO}"
    info "Destination : ${RABBLE_OS_DIR}"

    git clone "$RABBLE_OS_REPO" "$RABBLE_OS_DIR" || \
        error "Clone failed.\n  Repo : ${RABBLE_OS_REPO}\n  Check your internet connection and that the URL is correct.\n  For SSH clones, ensure your key is registered: ssh -T git@github.com"

    success "Repository cloned to: ${RABBLE_OS_DIR}"

    # If we cloned via HTTPS and now have an SSH key, offer to switch remote to SSH.
    # This is cosmetic for ongoing git use — not required for the install to proceed.
    if [[ "$RABBLE_OS_REPO" == https://* && -f "${GIT_SSH_KEY}.pub" ]]; then
        local ssh_remote
        # Derive SSH remote from HTTPS URL: https://github.com/user/repo.git → git@github.com:user/repo.git
        ssh_remote=$(echo "$RABBLE_OS_REPO" | sed 's|https://github.com/|git@github.com:|')
        echo ""
        read -rp "  SSH key is ready — switch repo remote to SSH for future pushes? [Y/n]: " switch_remote
        if [[ "${switch_remote,,}" != "n" ]]; then
            git -C "$RABBLE_OS_DIR" remote set-url origin "$ssh_remote"
            success "Remote updated to SSH: ${ssh_remote}"
        fi
    fi
}

# ── Hand off to Bootstrap ──────────────────────────────────────────────────────
begin_bootstrap() {
    section "Launching RaBbLE-OS Bootstrap"

    local bootstrap_script="${RABBLE_OS_DIR}/RaBbLE-OS-Bootstrap.sh"

    if [[ ! -f "$bootstrap_script" ]]; then
        error "Bootstrap script not found at: ${bootstrap_script}\nVerify the repository cloned correctly."
    fi

    chmod +x "$bootstrap_script"

    info "Handing off control to RaBbLE-OS-Bootstrap.sh..."
    info "The system will be transmogrified into RaBbLE-OS v${RABBLE_OS_VERSION}."
    echo ""
    read -rp "  Ready to begin transmogrification? [y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && { warn "Bootstrap cancelled by user. Run RaBbLE-OS-Bootstrap.sh manually when ready."; exit 0; }

    cd "$RABBLE_OS_DIR"
    exec bash "$bootstrap_script"
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    clear
    banner
    echo ""

    check_not_root
    check_fedora_version

    # Core tools — must precede clone
    setup_git
    setup_pip3
    setup_ansible

    # Clone the repo (HTTPS — works immediately, no SSH key required)
    clone_repo

    # SSH setup — optional but recommended for ongoing development.
    # Runs after clone so the repo exists regardless of SSH outcome.
    echo ""
    info "SSH key setup — recommended for pushing changes back to the repo."
    read -rp "  Set up SSH key now? [Y/n]: " do_ssh
    if [[ "${do_ssh,,}" != "n" ]]; then
        setup_ssh_key
        configure_ssh_port
        # Offer to flip the cloned remote to SSH now that the key is ready
        if [[ "$RABBLE_OS_REPO" == https://* && -f "${GIT_SSH_KEY}.pub" ]]; then
            local ssh_remote
            ssh_remote=$(echo "$RABBLE_OS_REPO" | sed 's|https://github.com/|git@github.com:|')
            read -rp "  Switch cloned remote to SSH? [Y/n]: " switch_remote
            if [[ "${switch_remote,,}" != "n" ]]; then
                git -C "$RABBLE_OS_DIR" remote set-url origin "$ssh_remote"
                success "Remote updated → ${ssh_remote}"
            fi
        fi
    else
        warn "Skipping SSH setup. You can run it later with: bash ${RABBLE_OS_DIR}/RaBbLE-OS-Install.sh"
    fi

    begin_bootstrap
}

main "$@"
