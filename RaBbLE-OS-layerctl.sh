#!/usr/bin/env bash
# RaBbLE-OS-layerctl.sh — RaBbLE-OS Layer Control
#
# harmonize ~ layer-ctl >> apply/remove/status/verify per layer // %LAYERCTL_READY%
#
# Usage (run from any directory; `layerctl` is symlinked into ~/.local/bin):
#   layerctl vscode                     — bare name = apply (layer, alias or ansible tag)
#   layerctl apply base                 — packages + config
#   layerctl apply apps vscode niri     — several targets in one go
#   layerctl apply hardware --packages  — layer minus its config tasks (see `help`)
#   layerctl apply all                  — full system
#   layerctl upgrade                    — dnf + firmware + apply all
#   layerctl remove niri                — teardown a layer
#   layerctl status                     — show all layer states
#   layerctl verify hardware            — run layer health checks
#   layerctl list                       — every layer, alias and ansible tag
#   layerctl info                       — detected system, version, hardware
#   layerctl dotfiles                   — re-link dotfiles only
#   layerctl app freecad                — install one registered creator app
#
# Layers live in ansible/layers.conf (add a section, no script edit needed).

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ANSIBLE_DIR="${SCRIPT_DIR}/ansible"
INVENTORY="${ANSIBLE_DIR}/inventory/hosts.yml"
SITE_YML="${ANSIBLE_DIR}/site.yml"
CREATOR_APPS_VARS="${ANSIBLE_DIR}/roles/layer/creator-apps/vars/main.yml"
LAYERS_CONF="${ANSIBLE_DIR}/layers.conf"

# Always use the repo's ansible.cfg, whatever directory we were launched from.
export ANSIBLE_CONFIG="${ANSIBLE_DIR}/ansible.cfg"

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

# ── Layer registry ────────────────────────────────────────────────────────────
#
# Loaded from ansible/layers.conf (INI-ish: [layer] then key = value lines).
# Layer tags map directly to Ansible tags in site.yml. "all" runs site.yml
# without tag filtering. Opt-in layers carry an `extra` var so `apply all` /
# `upgrade` never pick them up silently.

declare -A LAYER_NAMES=() LAYER_EXTRA_VARS=() LAYER_VERIFY=() LAYER_ALIAS=() LAYER_GROUP=()
LAYER_ORDER=()

load_registry() {
  [[ -f "$LAYERS_CONF" ]] || fail "Layer registry missing: ${LAYERS_CONF}"
  local line key val cur=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    if [[ "$line" =~ ^\[([A-Za-z0-9._-]+)\]$ ]]; then
      cur="${BASH_REMATCH[1]}"
      LAYER_ORDER+=("$cur"); LAYER_NAMES[$cur]=""; LAYER_GROUP[$cur]="main"
      continue
    fi
    [[ -z "$cur" || "$line" != *=* ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    key="${key//[[:space:]]/}"
    val="${val#"${val%%[![:space:]]*}"}"
    case "$key" in
      desc)   LAYER_NAMES[$cur]="$val" ;;
      verify) LAYER_VERIFY[$cur]="$val" ;;
      extra)  LAYER_EXTRA_VARS[$cur]="$val" ;;
      group)  LAYER_GROUP[$cur]="$val" ;;
      alias)  local a; for a in $val; do LAYER_ALIAS[$a]="$cur"; done ;;
    esac
  done < "$LAYERS_CONF"
}
load_registry

# ── Target resolution ─────────────────────────────────────────────────────────
#
# A target can be: a registered layer, an alias, or any Ansible tag found in
# site.yml / roles (vscode, waybar, hyprland, plymouth, ...). Tags too generic
# to run on their own are excluded.

GENERIC_TAGS=" always never packages config remove layer plans "
_TAGS_CACHE=""

discover_tags() {
  if [[ -z "$_TAGS_CACHE" ]]; then
    _TAGS_CACHE="$(grep -rhoE 'tags:[[:space:]]*\[[^]]*\]' "$SITE_YML" "${ANSIBLE_DIR}/roles" 2>/dev/null \
      | sed -E 's/tags:[[:space:]]*\[//; s/\]//' | tr ',' '\n' | tr -d " \"'" \
      | grep -E '^[a-z0-9][a-z0-9_-]*$' | sort -u \
      | while read -r t; do [[ "$GENERIC_TAGS" == *" $t "* ]] || echo "$t"; done)"
  fi
  printf '%s\n' "$_TAGS_CACHE"
}

# Sets RESOLVED_KIND (layer|tag) and RESOLVED_NAME. Returns 1 if unknown.
resolve_target() {
  local t="${1,,}"
  RESOLVED_KIND="" RESOLVED_NAME=""
  if [[ -n "${LAYER_NAMES[$t]+_}" ]]; then
    RESOLVED_KIND=layer RESOLVED_NAME="$t"
  elif [[ -n "${LAYER_ALIAS[$t]:-}" ]]; then
    RESOLVED_KIND=layer RESOLVED_NAME="${LAYER_ALIAS[$t]}"
  elif discover_tags | grep -qx -- "$t"; then
    RESOLVED_KIND=tag RESOLVED_NAME="$t"
  else
    return 1
  fi
}

# Unknown target: say what is close, then what is valid, then exit.
unknown_target() {
  local t="$1" names close
  names="$( { printf '%s\n' "${!LAYER_NAMES[@]}" "${!LAYER_ALIAS[@]}"; discover_tags; } | sort -u)"
  close="$(printf '%s\n' "$names" | python3 -I -c '
import difflib,sys
t=sys.argv[1]; n=[l.strip() for l in sys.stdin if l.strip()]
sub=[x for x in n if t in x or x in t]
print(" ".join(dict.fromkeys(sub+difflib.get_close_matches(t,n,5,0.5))))' "$t" 2>/dev/null || true)"
  echo -e "${RED}${BOLD}  ✗${RESET} ${RED}Unknown layer or tag: '${t}'${RESET}" >&2
  [[ -n "$close" ]] && echo -e "${TEXT}    Did you mean: ${CYAN}${close}${RESET}" >&2
  echo -e "${MUTED}    Run 'layerctl list' to see everything valid.${RESET}" >&2
  exit 1
}

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

# ── System detection ──────────────────────────────────────────────────────────
#
# Same rule as site.yml's hardware-detection play: DMI product_name matching
# "ProArt P16" is asus_proart_p16, anything else is generic_x64. Override with
# RABBLE_HARDWARE or --hardware.

detect_system() {
  SYS_ARCH="$(uname -m)"
  SYS_KERNEL="$(uname -r)"
  SYS_PRODUCT="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
  if [[ -n "${RABBLE_HARDWARE:-}" ]]; then
    SYS_HW="$RABBLE_HARDWARE"; SYS_HW_SRC="override"
  elif [[ "$SYS_PRODUCT" == "ProArt P16"* ]]; then
    SYS_HW="asus_proart_p16"; SYS_HW_SRC="DMI"
  else
    SYS_HW="generic_x64"; SYS_HW_SRC="DMI"
  fi
  # shellcheck disable=SC1091
  eval "$(
    . /etc/os-release 2>/dev/null || true
    printf 'OS_ID=%q OS_PRETTY=%q OS_VERSION_ID=%q RABBLE_OS_VERSION=%q RABBLE_OS_BASE=%q' \
      "${ID:-unknown}" "${PRETTY_NAME:-unknown}" "${VERSION_ID:-?}" "${RABBLE_VERSION:-}" "${RABBLE_BASE:-}"
  )"
  REPO_BRANCH="$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"
  REPO_REV="$(git -C "$SCRIPT_DIR" describe --tags --always --dirty 2>/dev/null || echo '-')"
}

context_line() {
  detect_system
  muted "${OS_PRETTY} · fedora ${OS_VERSION_ID} · ${SYS_HW} (${SYS_HW_SRC}) · ${REPO_BRANCH}@${REPO_REV}"
}

# Fail early on conditions that would otherwise die deep inside ansible.
preflight() {
  command -v ansible-playbook &>/dev/null \
    || fail "ansible-playbook not found. Install: sudo dnf install ansible-core"
  [[ -f "$SITE_YML" ]] || fail "Playbook not found: ${SITE_YML}"
  detect_system
  [[ "$OS_ID" == "fedora" ]] || warn "OS id is '${OS_ID}', roles assume Fedora (dnf)."
  if [[ -n "$RABBLE_OS_BASE" && "$RABBLE_OS_BASE" != "f${OS_VERSION_ID}" ]]; then
    warn "os-release says RABBLE_BASE=${RABBLE_OS_BASE} but Fedora is ${OS_VERSION_ID}."
  fi
}

# ── Ansible runner ────────────────────────────────────────────────────────────

run_playbook() {
  local tags="$1"
  shift
  local extra_args=("$@")

  local cmd=(ansible-playbook -i "$INVENTORY" "$SITE_YML")
  [[ $EUID -ne 0 ]] && cmd+=(-K)
  [[ -n "${RABBLE_HARDWARE:-}" ]] && cmd+=(--extra-vars "rabble_hardware=${RABBLE_HARDWARE}")
  [[ "$tags" != "all" ]] && cmd+=(--tags "$tags")
  cmd+=("${extra_args[@]}")

  info "Running: ${cmd[*]}"
  divider
  # cd so relative paths in ansible.cfg / roles resolve regardless of caller cwd
  (cd "$ANSIBLE_DIR" && "${cmd[@]}")
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
  # Tab-separated: id<TAB>flatpak-id<TAB>cli(may be empty)<TAB>desc
  python3 -c "
import yaml
with open('${CREATOR_APPS_VARS}') as f:
    data = yaml.safe_load(f) or {}
for a in data.get('rabble_optional_apps', []):
    print(f\"{a['id']}\t{a['flatpak']}\t{a.get('cli', '')}\t{a['desc']}\")
"
}

verify_creator_apps() {
  local all_ok=true
  while IFS=$'\t' read -r id flatpak_id _cli _desc; do
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

# Prints extra-vars args for a layer (empty for tags / non-opt-in layers).
layer_extra_args() {
  [[ -n "${LAYER_EXTRA_VARS[$1]:-}" ]] && printf '%s\n' --extra-vars "${LAYER_EXTRA_VARS[$1]}"
  return 0
}

cmd_apply() {
  local targets=() packages_only=false config_only=false dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --packages)  packages_only=true  ; shift ;;
      --config)    config_only=true    ; shift ;;
      --check|--dry-run) dry_run=true  ; shift ;;
      --hardware)  [[ -n "${2:-}" ]] || fail "--hardware needs a profile (asus_proart_p16|generic_x64)"
                   RABBLE_HARDWARE="$2"; shift 2 ;;
      -*)          warn "Unknown flag: $1"; shift ;;
      *)           targets+=("$1"); shift ;;
    esac
  done

  if [[ ${#targets[@]} -eq 0 ]]; then
    warn "No target given. Usage: layerctl apply TARGET... [--packages|--config] [--check]"
    cmd_list
    exit 1
  fi

  # Resolve everything first so a typo in target 3 fails before target 1 runs.
  local t kinds=() names=()
  for t in "${targets[@]}"; do
    resolve_target "$t" || unknown_target "$t"
    kinds+=("$RESOLVED_KIND"); names+=("$RESOLVED_NAME")
  done

  preflight
  local i name kind tag desc extra_vars skip_args
  for i in "${!names[@]}"; do
    name="${names[$i]}"; kind="${kinds[$i]}"
    # Ansible ORs --tags, so "layer,packages" would run every packages task in
    # the playbook. Select the layer, then skip the opposite kind instead.
    tag="$name"; skip_args=()
    $packages_only && skip_args=(--skip-tags config)
    $config_only   && skip_args=(--skip-tags packages)

    if [[ "$kind" == layer ]]; then
      desc="${LAYER_NAMES[$name]}"
    else
      desc="ansible tag '${name}'"
    fi
    [[ "${targets[$i],,}" != "$name" ]] && info "'${targets[$i]}' → ${name}"
    $packages_only && pulse "Applying packages: ${desc}"
    $config_only   && pulse "Applying config: ${desc}"
    $packages_only || $config_only || pulse "Applying ${kind}: ${desc}"
    context_line

    extra_vars=()
    [[ "$kind" == layer ]] && mapfile -t extra_vars < <(layer_extra_args "$name")

    if $dry_run; then
      warn "Dry-run mode — no changes will be made."
      run_playbook_check "$tag" "${skip_args[@]}" "${extra_vars[@]}"
      continue
    fi

    run_playbook "$tag" "${skip_args[@]}" "${extra_vars[@]}"
    set_state "$([[ $kind == tag ]] && echo "tag-${name}" || echo "$name")" "applied"
    ok "'${name}' applied. // %LAYER_STABLE%"
  done
}

cmd_remove() {
  local layer="${1:-}"
  [[ -z "$layer" ]] && fail "Usage: layerctl remove LAYER"
  resolve_target "$layer" || unknown_target "$layer"
  [[ "$RESOLVED_KIND" == layer ]] || fail "'${layer}' is an ansible tag, not a layer. remove works on layers."
  layer="$RESOLVED_NAME"
  [[ "$layer" == "base" ]] && fail "Cannot remove the base layer."
  [[ "$layer" == "all" ]] && fail "Use 'remove' per-layer. 'all' is not valid for remove."

  preflight
  pulse "Removing layer: ${LAYER_NAMES[$layer]}"
  warn "This will run the 'remove' tagged tasks for this layer."
  read -rp "$(echo -e "${RED}  Confirm removal of '${layer}'? [y/N]: ${RESET}")" confirm
  [[ "${confirm:-N}" =~ ^[Yy]$ ]] || { info "Aborted."; return; }

  # Same extra vars as `apply`: opt-in roles are gated by `when: rabble_enable_*`
  # in site.yml, so without them the role (and its `remove` tasks) never runs.
  local extra_vars=()
  mapfile -t extra_vars < <(layer_extra_args "$layer")

  run_playbook "${layer},remove" "${extra_vars[@]}"
  set_state "$layer" "removed"
  ok "Layer '${layer}' removed."
}

cmd_verify() {
  local layer="${1:-}"
  [[ -z "$layer" ]] && fail "Usage: layerctl verify LAYER"
  resolve_target "$layer" || unknown_target "$layer"
  [[ "$RESOLVED_KIND" == layer ]] || fail "'${layer}' is an ansible tag, not a layer; no verify command."
  layer="$RESOLVED_NAME"

  local verify_cmd="${LAYER_VERIFY[$layer]:-}"
  if [[ -z "$verify_cmd" ]]; then
    warn "No verify command defined for layer '${layer}' (add 'verify =' in layers.conf)."
    return
  fi

  pulse "Verifying layer: ${LAYER_NAMES[$layer]}"
  divider
  if eval "$verify_cmd"; then
    ok "Layer '${layer}' verification passed."
    set_state "$layer" "verified"
  else
    warn "Layer '${layer}' verification failed. Run 'layerctl apply ${layer}' to repair."
    set_state "$layer" "degraded"
  fi
}

cmd_app() {
  local target="${1:-}"

  if [[ -z "$target" || "$target" == "list" ]]; then
    pulse "Registered creator apps"
    divider
    creator_apps_list | while IFS=$'\t' read -r id flatpak_id cli desc; do
      printf "  ${CYAN}%-14s${RESET} %-26s %s\n" "$id" "$flatpak_id" "$desc"
      [[ -n "$cli" ]] && muted "                 shell alias: ${cli}"
    done
    echo
    muted "Install one:  layerctl app <id>"
    muted "Install all:  layerctl apply creator-apps"
    return
  fi

  local flatpak_id
  flatpak_id=$(creator_apps_list | awk -F'\t' -v id="$target" '$1==id{print $2}')
  [[ -z "$flatpak_id" ]] && fail "Unknown creator app: '${target}'. Run 'layerctl app list' to see registered apps."

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
    [[ "$layer" == all ]] && continue
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
  detect_system
  muted "System: ${OS_PRETTY} (fedora ${OS_VERSION_ID}, ${SYS_ARCH}) · kernel ${SYS_KERNEL}"
  muted "Hardware profile: ${SYS_HW} (${SYS_HW_SRC}; product '${SYS_PRODUCT}')"
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
  [[ $# -gt 0 ]] || fail "Usage: layerctl diff TARGET"
  cmd_apply "$@" --check
}

cmd_menu() {
  local menu_script="${SCRIPT_DIR}/bootstrap/menus/main.menu.sh"
  if [[ -f "$menu_script" ]]; then
    exec bash "$menu_script"
  else
    fail "Bootstrap menu not found at ${menu_script}"
  fi
}

cmd_list() {
  local layer group
  pulse "Layers  (layerctl apply NAME)"
  divider
  for group in main sub; do
    [[ $group == sub ]] && { echo; echo -e "  ${BOLD}Sub-layers${RESET}"; }
    for layer in "${LAYER_ORDER[@]}"; do
      [[ "${LAYER_GROUP[$layer]}" == "$group" ]] || continue
      local al="" k
      for k in "${!LAYER_ALIAS[@]}"; do [[ "${LAYER_ALIAS[$k]}" == "$layer" ]] && al+="$k "; done
      printf "  ${CYAN}%-16s${RESET} %s" "$layer" "${LAYER_NAMES[$layer]}"
      [[ -n "$al" ]] && printf " ${MUTED}[aka %s]${RESET}" "${al% }"
      echo
    done
  done
  echo
  echo -e "  ${BOLD}Ansible tags${RESET} ${MUTED}(finer-grained; 'layerctl apply <tag>' runs just that)${RESET}"
  local tags
  tags="$(discover_tags | while read -r t; do [[ -n "${LAYER_NAMES[$t]+_}" ]] || echo "$t"; done | tr '\n' ' ')"
  echo -e "  ${MUTED}$(echo "$tags" | fold -s -w 76 | sed '2,$s/^/  /')${RESET}"
  echo
  muted "Add a layer: edit ansible/layers.conf. Add a tag: tag tasks in the role."
  echo
}

cmd_info() {
  detect_system
  pulse "RaBbLE-OS system"
  divider
  printf "  ${CYAN}%-12s${RESET} %s\n" \
    "OS"        "${OS_PRETTY} (id=${OS_ID}, fedora ${OS_VERSION_ID}${RABBLE_OS_BASE:+, base ${RABBLE_OS_BASE}})" \
    "Version"   "${RABBLE_OS_VERSION:-unset} (os-release) · repo ${REPO_BRANCH}@${REPO_REV}" \
    "Hardware"  "${SYS_HW} (${SYS_HW_SRC}) · product '${SYS_PRODUCT}'" \
    "Arch"      "${SYS_ARCH} · kernel ${SYS_KERNEL}" \
    "Session"   "${XDG_CURRENT_DESKTOP:-none} (${XDG_SESSION_TYPE:-?})" \
    "Ansible"   "$(ansible-playbook --version 2>/dev/null | head -1 || echo 'not installed')" \
    "Repo"      "${SCRIPT_DIR}" \
    "State"     "${STATE_DIR}"
  [[ ":$PATH:" == *":${HOME}/.local/bin:"* ]] || warn "~/.local/bin is not on PATH; 'layerctl' will not resolve."
  [[ -x "${HOME}/.local/bin/layerctl" ]] || warn "No ~/.local/bin/layerctl link. Run: layerctl link"
  echo
}

# (Re)create ~/.local/bin/{layerctl,dotctl,vmctl} -> repo scripts.
cmd_link() {
  mkdir -p "${HOME}/.local/bin"
  local n
  for n in layerctl dotctl vmctl; do
    ln -sfn "${SCRIPT_DIR}/RaBbLE-OS-${n}.sh" "${HOME}/.local/bin/${n}"
    ok "~/.local/bin/${n} → RaBbLE-OS-${n}.sh"
  done
}

cmd_completion() {
  case "${1:-}" in
    zsh)
      cat <<'EOS'
_layerctl() {
  local -a cmds; cmds=(apply upgrade remove verify status diff list info link app dotfiles help)
  if (( CURRENT == 2 )); then compadd -- $cmds $(layerctl names); else compadd -- $(layerctl names); fi
}
compdef _layerctl layerctl
EOS
      ;;
    bash)
      cat <<'EOS'
_layerctl() {
  local cmds="apply upgrade remove verify status diff list info link app dotfiles help"
  COMPREPLY=( $(compgen -W "$cmds $(layerctl names)" -- "${COMP_WORDS[COMP_CWORD]}") )
}
complete -F _layerctl layerctl
EOS
      ;;
    *) fail "Usage: layerctl completion zsh|bash   (e.g. source <(layerctl completion zsh))" ;;
  esac
}

cmd_help() {
  echo
  echo -e "${MAGENTA}${BOLD}layerctl${RESET} — RaBbLE-OS Layer Control  ${MUTED}(works from any directory)${RESET}"
  echo
  echo -e "${BOLD}QUICK${RESET}"
  echo -e "  ${CYAN}layerctl vscode${RESET}            apply a layer, alias or ansible tag by bare name"
  echo -e "  ${CYAN}layerctl list${RESET}              everything you can name"
  echo -e "  ${CYAN}layerctl info${RESET}              detected OS, version, hardware, repo"
  echo -e "  ${CYAN}layerctl status${RESET}            state of every layer"
  echo
  echo -e "${BOLD}COMMANDS${RESET}"
  echo -e "  ${CYAN}apply${RESET}   TARGET... [--packages] [--config] [--check] [--hardware P]"
  echo -e "          TARGET = layer, alias, or ansible tag (see 'list'). Default: packages + config."
  echo -e "          ${MUTED}--packages skips 'config' tasks, --config skips 'packages' tasks, within${RESET}"
  echo -e "          ${MUTED}the layer. Other kinds (services, dotfiles) still run; use a tag to narrow.${RESET}"
  echo -e "          --check     dry-run, no changes"
  echo -e "  ${CYAN}diff${RESET}    TARGET     dry-run with diff (same as apply --check)"
  echo -e "  ${CYAN}remove${RESET}  LAYER      remove a layer (with confirmation)"
  echo -e "  ${CYAN}verify${RESET}  LAYER      run layer health checks"
  echo -e "  ${CYAN}status${RESET}             all layers and their state"
  echo -e "  ${CYAN}list${RESET}               layers, aliases, ansible tags"
  echo -e "  ${CYAN}info${RESET}               detected system / version / hardware"
  echo -e "  ${CYAN}upgrade${RESET} [--no-packages] [--no-firmware] [--no-apply]"
  echo -e "          dnf upgrade → firmware (fwupdmgr) → apply all"
  echo -e "  ${CYAN}dotfiles${RESET}           re-link dotfiles into ~/.config/ and run dotctl"
  echo -e "  ${CYAN}app${RESET}     [ID|list]  install one registered creator app"
  echo -e "          registry: ansible/roles/layer/creator-apps/vars/main.yml"
  echo -e "  ${CYAN}link${RESET}               (re)create ~/.local/bin/{layerctl,dotctl,vmctl}"
  echo -e "  ${CYAN}completion${RESET} zsh|bash   tab completion:  source <(layerctl completion zsh)"
  echo
  echo -e "${BOLD}ALIASES${RESET}  install/add/enable/update → apply · rm/uninstall → remove · check/test → verify · ls/layers → list"
  echo
  echo -e "${BOLD}HARDWARE${RESET}  auto-detected from DMI; override with ${CYAN}--hardware P${RESET} or ${CYAN}RABBLE_HARDWARE${RESET}"
  echo -e "  ${MUTED}asus_proart_p16 · generic_x64${RESET}"
  echo
  echo -e "${BOLD}EXAMPLES${RESET}"
  echo -e "  ${MUTED}layerctl vscode                       — redeploy VSCodium theme/settings${RESET}"
  echo -e "  ${MUTED}layerctl apply niri apps              — two targets, one command${RESET}"
  echo -e "  ${MUTED}layerctl apply boot --check           — dry run${RESET}"
  echo -e "  ${MUTED}layerctl verify hardware${RESET}"
  echo -e "  ${MUTED}layerctl app freecad${RESET}"
  echo -e "  ${MUTED}RABBLE_HARDWARE=generic_x64 layerctl apply hardware${RESET}"
  echo
  echo -e "${MUTED}  Layers are defined in ansible/layers.conf.${RESET}"
  echo
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

# Export so Ansible inherits it
export RABBLE_HARDWARE="${RABBLE_HARDWARE:-}"

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
  apply|install|add|enable|update|deploy) cmd_apply "$@" ;;
  upgrade)             cmd_upgrade "$@" ;;
  remove|rm|uninstall|disable) cmd_remove "$@" ;;
  verify|check|test|health)    cmd_verify "$@" ;;
  app)                 cmd_app "$@" ;;
  status|st)           cmd_status ;;
  diff)                cmd_diff "$@" ;;
  list|ls|layers|tags) cmd_list ;;
  info|version|system|doctor) cmd_info ;;
  link)                cmd_link ;;
  completion)          cmd_completion "$@" ;;
  names)               { printf '%s\n' "${!LAYER_NAMES[@]}" "${!LAYER_ALIAS[@]}"; discover_tags; } | sort -u ;;
  dotfiles)            cmd_dotfiles ;;
  menu)                cmd_menu ;;
  help|-h|--help)      cmd_help ;;
  *)
    # Bare name: `layerctl vscode` == `layerctl apply vscode`
    if resolve_target "$COMMAND"; then
      cmd_apply "$COMMAND" "$@"
    else
      unknown_target "$COMMAND"
    fi
    ;;
esac
