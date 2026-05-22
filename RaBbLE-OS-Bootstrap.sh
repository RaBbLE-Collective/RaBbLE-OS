#!/usr/bin/env bash
# ==============================================================================
# RaBbLE-OS-Bootstrap.sh
# Ansible-driven system transmogrification: Fedora 43 Sway → RaBbLE-OS Base
# Version: 0.0.1
# Called by: RaBbLE-OS-Install.sh  |  or manually post-clone
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m';     GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m';    BOLD='\033[1m';     RESET='\033[0m'
MAGENTA='\033[0;35m'

info()    { echo -e "${CYAN}[BOOTSTRAP]${RESET} $*"; }
success() { echo -e "${GREEN}[BOOTSTRAP]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[BOOTSTRAP]${RESET} $*"; }
error()   { echo -e "${RED}[BOOTSTRAP]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}──────────────────────────────────────────${RESET}"; \
            echo -e "${BOLD}  $*${RESET}"; \
            echo -e "${BOLD}${CYAN}──────────────────────────────────────────${RESET}\n"; }

# ── Paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="${SCRIPT_DIR}/ansible"
PLAYBOOK="${ANSIBLE_DIR}/site.yml"
INVENTORY="${ANSIBLE_DIR}/inventory/hosts.yml"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/bootstrap-$(date +%Y%m%d-%H%M%S).log"
RABBLE_OS_VERSION="0.0.1"
UNATTENDED=false

# ── Argument parsing ───────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --unattended)
                UNATTENDED=true
                shift
                ;;
            --inventory)
                [[ -n "${2:-}" ]] || error "--inventory requires a path argument."
                INVENTORY="$2"
                shift 2
                ;;
            *)
                warn "Unknown argument: $1 (ignored)"
                shift
                ;;
        esac
    done
}

# ── Pre-flight checks ──────────────────────────────────────────────────────────
preflight() {
    section "Pre-flight Checks"

    [[ "$EUID" -eq 0 ]] && error "Do not run as root. Run as your normal user."

    command -v ansible &>/dev/null || error "ansible not found. Run RaBbLE-OS-Install.sh first."
    command -v git     &>/dev/null || error "git not found. Run RaBbLE-OS-Install.sh first."

    [[ -f "$PLAYBOOK" ]]   || error "Playbook not found: ${PLAYBOOK}"
    [[ -f "$INVENTORY" ]]  || error "Inventory not found: ${INVENTORY}"

    mkdir -p "$LOG_DIR"

    if [[ "$UNATTENDED" == "true" ]]; then
        sudo -n true 2>/dev/null || error "Unattended mode requires passwordless sudo. Check /etc/sudoers.d/."
        info "Mode     : unattended (non-interactive)"
    else
        sudo -v || error "sudo access required. Add your user to the sudoers file."
        ( while true; do sudo -v; sleep 50; done ) &
        SUDO_KEEPALIVE_PID=$!
        trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT
    fi

    success "All pre-flight checks passed."
    info "Ansible : $(ansible --version | head -1)"
    info "Log file: ${LOG_FILE}"
}

# ── Ansible galaxy dependencies ────────────────────────────────────────────────
install_galaxy_deps() {
    local requirements="${ANSIBLE_DIR}/requirements.yml"
    if [[ -f "$requirements" ]]; then
        section "Installing Ansible Galaxy Dependencies"
        ansible-galaxy install -r "$requirements" --force || \
            warn "Galaxy install had warnings — continuing."
    fi
}

# ── Run the playbook ───────────────────────────────────────────────────────────
run_playbook() {
    section "Running RaBbLE-OS Ansible Playbook"

    info "Playbook : ${PLAYBOOK}"
    info "Inventory: ${INVENTORY}"
    info "Logging  : ${LOG_FILE}"
    echo ""

    # Tags allow selective runs; default = all
    local tags="${RABBLE_TAGS:-all}"
    local extra_vars="rabble_os_version=${RABBLE_OS_VERSION} rabble_user=${USER} rabble_home=${HOME}"

    # Run ansible, tee to log and terminal
    local become_flag="--ask-become-pass"
    [[ "$UNATTENDED" == "true" ]] && become_flag=""

    # shellcheck disable=SC2086
    ansible-playbook \
        -i "$INVENTORY" \
        "$PLAYBOOK" \
        $become_flag \
        --tags "$tags" \
        -e "$extra_vars" \
        -v \
        2>&1 | tee "$LOG_FILE"

    local exit_code="${PIPESTATUS[0]}"

    if [[ "$exit_code" -ne 0 ]]; then
        error "Ansible playbook failed (exit ${exit_code}).\nReview log: ${LOG_FILE}"
    fi

    success "Ansible playbook completed successfully."
}

# ── Post-install summary ───────────────────────────────────────────────────────
post_install_summary() {
    section "RaBbLE-OS v${RABBLE_OS_VERSION} Installation Complete"

cat << EOF
${BOLD}${MAGENTA}
  ██████╗         ██████╗ ██╗     ██╗     ███████╗    ██████╗ ███████╗
  ██╔══██╗        ██╔══██╗██║     ██║     ██╔════╝   ██╔═══██╗██╔════╝
  ██████╔╝ █████╗ ██████╔╝██████  ██║     █████╗     ██║   ██║███████╗
  ██╔══██╗ █   █║ ██╔══██╗██╔══██╗██║     ██╔══╝     ██║   ██║╚════██║
  ██║  ██║ ╚█████ ██████╔╝██████╔╝███████╗███████╗   ╚██████╔╝███████║
  ╚═╝  ╚═╝    ╚═█ ╚═════╝ ╚═════╝ ╚══════╝╚══════╝    ╚═════╝ ╚══════╝
${RESET}
${BOLD}  Version   : ${RABBLE_OS_VERSION}${RESET}
${BOLD}  Built on  : Fedora $(grep -oP '(?<=^VERSION_ID=)\d+' /etc/os-release)${RESET}
${BOLD}  Log saved : ${LOG_FILE}${RESET}

${CYAN}  What was installed:${RESET}
    ✓ Hyprland (Wayland compositor)
    ✓ Hyprlock  (screen locker)
    ✓ Hypridle  (idle daemon)
    ✓ Waybar    (status bar)
    ✓ Kitty     (terminal)
    ✓ Wofi      (app launcher)
    ✓ Mako      (notifications)
    ✓ Hyprpaper (wallpaper daemon)
    ✓ RaBbLE-OS base configs deployed to ~/.config/

${CYAN}  Next steps:${RESET}
    1. Reboot your system: ${BOLD}systemctl reboot${RESET}
    2. At the login screen, select ${BOLD}Hyprland${RESET} as your session
    3. Log in — RaBbLE-OS awaits

${YELLOW}  Keybindings (RaBbLE-OS defaults):${RESET}
    Super + Enter     → Terminal (kitty)
    Super + D         → App launcher (wofi)
    Super + Q         → Close window
    Super + Shift + E → Exit Hyprland
    Super + L         → Lock screen (hyprlock)

EOF
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    clear
    echo -e "${BOLD}${CYAN}"
    echo "  RaBbLE-OS Bootstrap — Transmogrification Engine"
    echo "  Fedora ──→ RaBbLE-OS v${RABBLE_OS_VERSION}"
    echo -e "${RESET}"

    preflight
    install_galaxy_deps
    run_playbook
    post_install_summary
}

main "$@"
