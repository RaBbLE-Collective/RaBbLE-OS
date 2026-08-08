#!/usr/bin/env bash
# RaBbLE-OS-layerctl.sh — RaBbLE-OS Layer Control
#
# harmonize ~ layer-ctl >> apply/remove/status/verify per layer // %LAYERCTL_READY%
#
# Usage:
#   ./layer-ctl.sh apply base                    — packages + config
#   ./layer-ctl.sh apply hardware --packages     — packages only
#   ./layer-ctl.sh apply boot --config           — config only
#   ./layer-ctl.sh apply all                     — full system
#   ./layer-ctl.sh upgrade                       — dnf + firmware + apply all
#   ./layer-ctl.sh remove desktop                — teardown a layer
#   ./layer-ctl.sh status                        — show all layer states
#   ./layer-ctl.sh verify hardware               — run layer health checks
#   ./layer-ctl.sh dotfiles                      — re-link dotfiles only
#   ./layer-ctl.sh menu                          — launch interactive menu
#   ./layer-ctl.sh app freecad                   — install one registered creator app
#   ./layer-ctl.sh app list                      — list registered creator apps

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="${SCRIPT_DIR}/ansible"
INVENTORY="${ANSIBLE_DIR}/inventory/hosts.yml"
SITE_YML="${ANSIBLE_DIR}/site.yml"
CREATOR_APPS_VARS="${ANSIBLE_DIR}/roles/layer/creator-apps/vars/main.yml"

# ── Colors ────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  MAGENTA='\033[38;2;255;45;120m'
  CYAN='\033[38;2;0;245;255m'
  VIOLET='\033[38;2;191;95;255m'
  MUTED='\033[38;2;107;104;128m'
  TEXT='\033[38;2;232;230;240m'
  RED='\033[38;2;224;92;111m'
  GREEN='\033[38;2;80;250;123m'
  YELLOW='\033[38;2;241;250;140m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  MAGENTA='' CYAN='' VIOLET='' MUTED='' TEXT='' RED='' GREEN='' YELLOW='' BOLD='' RESET=''
fi

pulse()   { echo -e "${MAGENTA}${BOLD}::${RESET} ${TEXT}$*${RESET}"; }
info()    { echo -e "${CYAN}  →${RESET} ${TEXT}$*${RESET}"; }
ok()      { echo -e "${GREEN}  ✓${RESET} ${TEXT}$*${RESET}"; }
warn()    { echo -e "${VIOLET}  !${RESET} ${TEXT}$*${RESET}"; }
fail()    { echo -e "${RED}${BOLD}  ✗${RESET} ${RED}$*${RESET}"; exit 1; }
muted()   { echo -e "${MUTED}    $*${RESET}"; }
divider() { echo -e "${MUTED}────────────────────────────────────────────────${RESET}"; }

# ── Layer definitions ─────────────────────────────────────────────────────────
#
# Format: LAYER_TAG : "Human name" : verify_command
#
# Tags map directly to Ansible tags in site.yml.
# "all" is a special alias that runs site.yml without tag filtering.

declare -A LAYER_NAMES=(
  [base]="Base system (repos, packages, locale, fonts)"
  [hardware]="Hardware abstraction (GPU, asusctl, NPU, power)"
  [runtime]="GPU/NPU runtimes (llama.cpp, XRT, FastFlowLM, Lemonade)"
  [monitoring]="System observability (btop, htop, nvtop, sensors)"
  [virtualization]="QEMU/KVM host stack"
  [boot]="Boot chain (GRUB2, Plymouth, SDDM)"
  [snapper]="Snapper (Btrfs snapshots)"
  [desktop]="Desktop (Hyprland, Quickshell, terminal, shell)"
  [apps]="Applications (VSCode, dev tools)"
  [dotfiles]="Dotfiles (symlink ~/.config entries + dotctl deploy)"
  [ai-harnesses]="AI coding harnesses — all agents"
  [claude-code]="Claude Code CLI"
  [free-claude-code]="free-claude-code proxy (Anthropic API → NIM/Groq/etc)"
  [codex]="OpenAI Codex CLI"
  [opencode]="OpenCode agent"
  [aider]="Aider pair-programmer"
  [gemini-cli]="Gemini CLI"
  [ollama]="Ollama local inference server"
  [vllm]="vLLM inference server (heavy — GPU required)"
  [builder-skills]="BuilderIO slash-command skills for Claude Code"
  [bottles]="Bottles — Wine app compat (opt-in: creates+installs UP Studio/Cetus3D bottle, planned Affinity)"
  [containers]="Docker CE + Podman container runtimes (opt-in)"
  [esp-idf]="ESP-IDF embedded toolchain(s) via EIM CLI + picocom/usbutils/fzf — Espressif SDK for RaBbLE-Pocket firmware (opt-in)"
  [gnome]="GNOME Shell — Aether-themed secondary DE, SDDM fallback + theming testbed (opt-in)"
  [creator-apps]="Creator apps — data-driven single-Flatpak apps (see 'app list') (opt-in)"
  [all]="Full system — all layers in order"
)

# Optional/opt-in layers: extra --extra-vars flipped automatically when
# applying by name, so `apply all` / `upgrade` never picks them up silently.
# Each var's off-by-default lives in the layer role's defaults/main.yml.
declare -A LAYER_EXTRA_VARS=(
  [bottles]="rabble_enable_wine_bottles=true"
  [containers]="rabble_enable_containers=true"
  [esp-idf]="rabble_enable_esp_idf=true"
  [gnome]="rabble_enable_gnome_desktop=true"
  [creator-apps]="rabble_enable_creator_apps=true"
)

declare -A LAYER_VERIFY=(
  [base]="rpm -q git ansible-core"
  [hardware]="asusctl profile -l && supergfxctl --status"
  [runtime]="LD_LIBRARY_PATH=/usr/local/lib64 llama-server --version"
  [monitoring]="command -v btop && command -v sensors"
  [virtualization]="systemctl is-active libvirtd"
  [boot]="systemctl is-active sddm && plymouth-set-default-theme"
  [snapper]="snapper -c root list"
  [desktop]="hyprctl version && systemctl --user is-active waybar || true"
  [apps]="command -v code"
  [dotfiles]="test -L ~/.config/hypr/hyprland.conf"
  [ai-harnesses]="command -v claude && systemctl --user is-active free-claude-code || true"
  [claude-code]="command -v claude"
  [free-claude-code]="systemctl --user is-active free-claude-code && curl -sf http://127.0.0.1:8082/health || curl -sf http://127.0.0.1:8082/"
  [codex]="command -v codex"
  [opencode]="command -v opencode"
  [aider]="command -v aider"
  [gemini-cli]="command -v gemini"
  [ollama]="systemctl is-active ollama"
  [vllm]="command -v vllm"
  [builder-skills]="test -d ${HOME}/.claude/skills"
  [bottles]="flatpak info com.usebottles.bottles"
  [containers]="docker --version && podman --version"
  [esp-idf]="command -v eim && eim list && test -L ${HOME}/esp/esp-idf-default"
  [gnome]="rpm -q gnome-shell gnome-session-wayland-session >/dev/null && ! rpm -q gdm >/dev/null 2>&1 && test -f /usr/share/wayland-sessions/gnome.desktop"
  [creator-apps]="verify_creator_apps"
  [all]=""
)

# Ordered list for status display and sequential all-deploy
# Mirrors site.yml play order: base → hardware → runtime → monitoring → virtualization → boot → ...
LAYER_ORDER=(base hardware runtime monitoring virtualization boot snapper desktop apps ai-harnesses dotfiles bottles containers esp-idf gnome creator-apps)

# ── State tracking ────────────────────────────────────────────────────────────

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/rabble"
mkdir -p "$STATE_DIR"

state_file() { echo "${STATE_DIR}/layer_${1}.state"; }

set_state() {
  local layer="$1" state="$2"
  echo "$state:$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$(state_file "$layer")"
}

get_state() {
  local f
  f="$(state_file "$1")"
  if [[ -f "$f" ]]; then
    cut -d: -f1 "$f"
  else
    echo "unknown"
  fi
}

get_state_time() {
  local f
  f="$(state_file "$1")"
  if [[ -f "$f" ]]; then
    cut -d: -f2- "$f"
  else
    echo "never"
  fi
}

# ── Ansible runner ────────────────────────────────────────────────────────────

# Resolved at runtime so RABBLE_HARDWARE can be set after sourcing
ansible_hardware_var() {
  echo "${RABBLE_HARDWARE:-generic_x64}"
}

run_playbook() {
  local tags="$1"
  shift
  local extra_args=("$@")

  local cmd=(
    ansible-playbook
    -i "$INVENTORY"
    "$SITE_YML"
    -K
    --extra-vars "rabble_target=$(ansible_hardware_var)"
  )

  if [[ "$tags" != "all" ]]; then
    cmd+=(--tags "$tags")
  fi

  cmd+=("${extra_args[@]}")

  info "Running: ${cmd[*]}"
  divider
  "${cmd[@]}"
}

run_playbook_check() {
  local tags="$1"
  shift
  run_playbook "$tags" --check --diff "$@"
}

# ── Creator apps registry ──────────────────────────────────────────────────────
#
# Reads ansible/roles/layer/creator-apps/vars/main.yml (rabble_optional_apps)
# at runtime via python3+PyYAML (already a hard dependency of this whole
# system). Adding a new app there makes it available to `app <id>`
# immediately — no edits below this comment are ever required for a new app.

creator_apps_list() {
  # Tab-separated: id<TAB>flatpak-id<TAB>desc
  python3 -c "
import yaml
with open('${CREATOR_APPS_VARS}') as f:
    data = yaml.safe_load(f) or {}
for a in data.get('rabble_optional_apps', []):
    print(f\"{a['id']}\t{a['flatpak']}\t{a['desc']}\")
"
}

verify_creator_apps() {
  local all_ok=true
  while IFS=$'\t' read -r id flatpak_id _desc; do
    if flatpak info "$flatpak_id" &>/dev/null; then
      ok "  ${id}"
    else
      warn "  ${id} (${flatpak_id}) not installed"
      all_ok=false
    fi
  done < <(creator_apps_list)
  $all_ok
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_apply() {
  local layer="${1:-}"
  shift || true
  local packages_only=false config_only=false dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --packages)  packages_only=true  ; shift ;;
      --config)    config_only=true    ; shift ;;
      --check|--dry-run) dry_run=true  ; shift ;;
      --hardware)  RABBLE_HARDWARE="${2:-}"; shift 2 ;;
      *) warn "Unknown flag: $1"; shift ;;
    esac
  done

  [[ -z "$layer" ]] && fail "Usage: layer-ctl apply LAYER [--packages|--config] [--check]"
  [[ -z "${LAYER_NAMES[$layer]+_}" ]] && fail "Unknown layer: '$layer'. Valid: ${!LAYER_NAMES[*]}"

  # Build tag string
  local tag="$layer"
  if $packages_only; then
    tag="${layer},packages"
    pulse "Applying packages: ${LAYER_NAMES[$layer]}"
  elif $config_only; then
    tag="${layer},config"
    pulse "Applying config: ${LAYER_NAMES[$layer]}"
  else
    pulse "Applying layer: ${LAYER_NAMES[$layer]}"
  fi

  local extra_vars=()
  if [[ -n "${LAYER_EXTRA_VARS[$layer]:-}" ]]; then
    extra_vars+=(--extra-vars "${LAYER_EXTRA_VARS[$layer]}")
  fi

  if $dry_run; then
    warn "Dry-run mode — no changes will be made."
    run_playbook_check "$tag" "${extra_vars[@]}"
    return
  fi

  run_playbook "$tag" "${extra_vars[@]}"
  set_state "$layer" "applied"
  ok "Layer '${layer}' applied. // %LAYER_STABLE%"
}

cmd_remove() {
  local layer="${1:-}"
  [[ -z "$layer" ]] && fail "Usage: layer-ctl remove LAYER"
  [[ -z "${LAYER_NAMES[$layer]+_}" ]] && fail "Unknown layer: '$layer'"
  [[ "$layer" == "base" ]] && fail "Cannot remove the base layer."
  [[ "$layer" == "all" ]] && fail "Use 'remove' per-layer. 'all' is not valid for remove."

  pulse "Removing layer: ${LAYER_NAMES[$layer]}"
  warn "This will run the 'remove' tagged tasks for this layer."
  read -rp "$(echo -e "${RED}  Confirm removal of '${layer}'? [y/N]: ${RESET}")" confirm
  [[ "${confirm:-N}" =~ ^[Yy]$ ]] || { info "Aborted."; return; }

  # Pass the same LAYER_EXTRA_VARS as `apply` — most opt-in roles are gated by
  # a `when: rabble_enable_*` on the role itself (see site.yml), so without
  # this the role — including its `remove` tagged tasks — never runs at all.
  local extra_vars=()
  if [[ -n "${LAYER_EXTRA_VARS[$layer]:-}" ]]; then
    extra_vars+=(--extra-vars "${LAYER_EXTRA_VARS[$layer]}")
  fi

  run_playbook "${layer},remove" "${extra_vars[@]}"
  set_state "$layer" "removed"
  ok "Layer '${layer}' removed."
}

cmd_verify() {
  local layer="${1:-}"
  [[ -z "$layer" ]] && fail "Usage: layer-ctl verify LAYER"
  [[ -z "${LAYER_NAMES[$layer]+_}" ]] && fail "Unknown layer: '$layer'"

  local verify_cmd="${LAYER_VERIFY[$layer]:-}"
  if [[ -z "$verify_cmd" ]]; then
    warn "No verify command defined for layer '${layer}'."
    return
  fi

  pulse "Verifying layer: ${LAYER_NAMES[$layer]}"
  divider
  if eval "$verify_cmd"; then
    ok "Layer '${layer}' verification passed."
    set_state "$layer" "verified"
  else
    warn "Layer '${layer}' verification failed. Run 'apply ${layer}' to repair."
    set_state "$layer" "degraded"
  fi
}

cmd_app() {
  local target="${1:-}"

  if [[ -z "$target" || "$target" == "list" ]]; then
    pulse "Registered creator apps"
    divider
    creator_apps_list | while IFS=$'\t' read -r id flatpak_id desc; do
      printf "  ${CYAN}%-14s${RESET} %-26s %s\n" "$id" "$flatpak_id" "$desc"
    done
    echo
    muted "Install one:  layer-ctl app <id>"
    muted "Install all:  layer-ctl apply creator-apps"
    return
  fi

  local flatpak_id
  flatpak_id=$(creator_apps_list | awk -F'\t' -v id="$target" '$1==id{print $2}')
  [[ -z "$flatpak_id" ]] && fail "Unknown creator app: '${target}'. Run 'layer-ctl app list' to see registered apps."

  pulse "Applying creator app: ${target} (${flatpak_id})"
  divider
  run_playbook "creator-apps" --extra-vars "rabble_enable_creator_apps=true rabble_creator_app_target=${target}"
  set_state "app-${target}" "applied"
  ok "App '${target}' applied. // %CREATOR_APP_STABLE%"
}

cmd_status() {
  echo
  pulse "RaBbLE-OS Layer Status"
  divider
  printf "  ${BOLD}%-12s %-10s %-22s %s${RESET}\n" "LAYER" "STATE" "LAST UPDATED" "DESCRIPTION"
  divider

  for layer in "${LAYER_ORDER[@]}"; do
    local state time color
    state=$(get_state "$layer")
    time=$(get_state_time "$layer")

    case "$state" in
      applied|verified) color="$GREEN"  ;;
      degraded)         color="$YELLOW" ;;
      removed)          color="$MUTED"  ;;
      *)                color="$MUTED"  ;;
    esac

    printf "  ${CYAN}%-12s${RESET} ${color}%-10s${RESET} ${MUTED}%-22s${RESET} %s\n" \
      "$layer" "$state" "${time:0:19}" "${LAYER_NAMES[$layer]}"
  done

  divider
  echo
  muted "Hardware profile: ${RABBLE_HARDWARE:-not set (auto-detect on apply)}"
  muted "State dir: ${STATE_DIR}"
  echo
}

cmd_dotfiles() {
  pulse "Re-linking dotfiles (Ansible symlinks)..."
  run_playbook "dotfiles"
  pulse "Deploying configs via dotctl (non-symlinked bundles)..."
  "${SCRIPT_DIR}/RaBbLE-OS-dotctl.sh" apply all
  ok "Dotfiles linked and configs deployed."
}

cmd_upgrade() {
  local skip_packages=false skip_firmware=false skip_apply=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-packages) skip_packages=true ; shift ;;
      --no-firmware) skip_firmware=true ; shift ;;
      --no-apply)    skip_apply=true    ; shift ;;
      *) warn "Unknown flag: $1"; shift ;;
    esac
  done

  pulse "RaBbLE-OS System Upgrade"
  divider

  # 1. System packages
  if ! $skip_packages; then
    info "Upgrading system packages (dnf upgrade)..."
    sudo dnf upgrade -y
    ok "System packages upgraded."
    divider
  fi

  # 2. Firmware (high value on ProArt: ASUS EC, NPU, USB-C, BIOS via LVFS)
  if ! $skip_firmware; then
    if command -v fwupdmgr &>/dev/null; then
      info "Refreshing firmware metadata..."
      fwupdmgr refresh --force 2>/dev/null || true
      info "Applying firmware updates (reboot may be required)..."
      fwupdmgr update || true
      ok "Firmware update complete."
      divider
    else
      muted "fwupdmgr not found — skipping firmware. Install: sudo dnf install fwupd"
    fi
  fi

  # 3. Re-converge Ansible-managed state (llama.cpp latest, etc.)
  if ! $skip_apply; then
    info "Re-converging Ansible-managed state (apply all)..."
    cmd_apply all
  fi

  ok "Upgrade complete. // %SYSTEM_UPGRADED%"
  muted "If firmware was updated, reboot to apply."
}

cmd_diff() {
  local layer="${1:-}"
  [[ -z "$layer" ]] && fail "Usage: layer-ctl diff LAYER"
  pulse "Diff (dry-run): ${LAYER_NAMES[$layer]:-$layer}"
  local extra_vars=()
  if [[ -n "${LAYER_EXTRA_VARS[$layer]:-}" ]]; then
    extra_vars+=(--extra-vars "${LAYER_EXTRA_VARS[$layer]}")
  fi
  run_playbook_check "$layer" "${extra_vars[@]}"
}

cmd_menu() {
  local menu_script="${SCRIPT_DIR}/bootstrap/menus/main.menu.sh"
  if [[ -f "$menu_script" ]]; then
    exec bash "$menu_script"
  else
    fail "Bootstrap menu not found at ${menu_script}"
  fi
}

cmd_help() {
  echo
  echo -e "${MAGENTA}${BOLD}layer-ctl${RESET} — RaBbLE-OS Layer Control"
  echo
  echo -e "${BOLD}COMMANDS${RESET}"
  echo -e "  ${CYAN}apply${RESET}   LAYER [--packages] [--config] [--check]"
  echo -e "          Apply a layer. Default: packages + config."
  echo -e "          --packages  packages only"
  echo -e "          --config    config/dotfiles only"
  echo -e "          --check     dry-run, no changes"
  echo
  echo -e "  ${CYAN}upgrade${RESET} [--no-packages] [--no-firmware] [--no-apply]"
  echo -e "          Upgrade the system: dnf upgrade → firmware (fwupdmgr) → apply all."
  echo -e "          Skip steps with --no-packages / --no-firmware / --no-apply."
  echo
  echo -e "  ${CYAN}remove${RESET}  LAYER"
  echo -e "          Remove a layer (with confirmation)."
  echo
  echo -e "  ${CYAN}verify${RESET}  LAYER"
  echo -e "          Run layer health checks."
  echo
  echo -e "  ${CYAN}status${RESET}"
  echo -e "          Show all layers and their current state."
  echo
  echo -e "  ${CYAN}diff${RESET}    LAYER"
  echo -e "          Show what 'apply' would change (dry-run + diff)."
  echo
  echo -e "  ${CYAN}dotfiles${RESET}"
  echo -e "          Re-link all dotfiles into ~/.config/."
  echo
  echo -e "  ${CYAN}menu${RESET}"
  echo -e "          Launch the interactive bootstrap menu."
  echo
  echo -e "  ${CYAN}app${RESET}     [ID | list]"
  echo -e "          Install one registered creator app by id, or list them all."
  echo -e "          Registry: ansible/roles/layer/creator-apps/vars/main.yml — add"
  echo -e "          an app there and 'app <id>' picks it up with no other edits."
  echo
  echo -e "${BOLD}LAYERS${RESET}"
  for layer in "${LAYER_ORDER[@]}" all; do
    printf "  ${CYAN}%-16s${RESET} %s\n" "$layer" "${LAYER_NAMES[$layer]}"
  done
  echo
  echo -e "${BOLD}AI HARNESS SUB-LAYERS${RESET} (targeted apply/verify)"
  for layer in claude-code free-claude-code codex opencode aider gemini-cli ollama vllm builder-skills; do
    printf "  ${CYAN}%-16s${RESET} %s\n" "$layer" "${LAYER_NAMES[$layer]}"
  done
  echo
  echo -e "${BOLD}HARDWARE PROFILES${RESET}"
  echo -e "  Set via ${CYAN}--hardware PROFILE${RESET} or ${CYAN}RABBLE_HARDWARE${RESET} env var."
  echo -e "  ${MUTED}asus_proart_p16  (default if detected)${RESET}"
  echo -e "  ${MUTED}generic_x64${RESET}"
  echo
  echo -e "${BOLD}EXAMPLES${RESET}"
  echo -e "  ${MUTED}./layer-ctl.sh upgrade${RESET}                          — full system upgrade"
  echo -e "  ${MUTED}./layer-ctl.sh upgrade --no-apply${RESET}               — dnf + firmware only"
  echo -e "  ${MUTED}./layer-ctl.sh apply all${RESET}"
  echo -e "  ${MUTED}./layer-ctl.sh apply hardware --packages${RESET}"
  echo -e "  ${MUTED}./layer-ctl.sh apply boot --config${RESET}"
  echo -e "  ${MUTED}./layer-ctl.sh verify hardware${RESET}"
  echo -e "  ${MUTED}./layer-ctl.sh status${RESET}"
  echo -e "  ${MUTED}./layer-ctl.sh app freecad${RESET}                      — install just FreeCAD"
  echo -e "  ${MUTED}./layer-ctl.sh app list${RESET}                         — list registered creator apps"
  echo -e "  ${MUTED}RABBLE_HARDWARE=generic_x64 ./layer-ctl.sh apply hardware${RESET}"
  echo
}

# ── Hardware arg (global, before subcommand parsing) ──────────────────────────

for arg in "$@"; do
  if [[ "$arg" == "--hardware" ]]; then
    idx=$((${#} - 1))
    # handled inside cmd_apply; also catch at global level
    :
  fi
done

# Export so Ansible inherits it
export RABBLE_HARDWARE="${RABBLE_HARDWARE:-}"

# ── Dispatch ──────────────────────────────────────────────────────────────────

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
  apply)    cmd_apply "$@" ;;
  upgrade)  cmd_upgrade "$@" ;;
  remove)   cmd_remove "$@" ;;
  verify)   cmd_verify "$@" ;;
  app)      cmd_app "$@" ;;
  status)   cmd_status ;;
  diff)     cmd_diff "$@" ;;
  dotfiles) cmd_dotfiles ;;
  menu)     cmd_menu ;;
  help|-h|--help) cmd_help ;;
  *)
    warn "Unknown command: '${COMMAND}'"
    cmd_help
    exit 1
    ;;
esac
