#!/usr/bin/env bash
# RaBbLE-OS-dotctl.sh — Dotfile / Config Deployment Control
#
# spark ~ config >> dotfile apply/pull/status/diff // %DOTCTL_READY%
#
# Usage:
#   ./RaBbLE-OS-dotctl.sh apply  [bundle|all]   — copy repo configs → ~/.config/
#   ./RaBbLE-OS-dotctl.sh pull   BUNDLE         — copy ~/.config/ → repo (capture live edits)
#   ./RaBbLE-OS-dotctl.sh status [bundle|all]   — show in-sync / drifted / missing per file
#   ./RaBbLE-OS-dotctl.sh diff   [bundle|all]   — line diff: repo vs deployed
#   ./RaBbLE-OS-dotctl.sh list                  — list all known bundles

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ── Bundle definitions ────────────────────────────────────────────────────────
#
# Add new bundles here as config/ grows (waybar, mako, quickshell, etc.)
# SRC paths are relative to SCRIPT_DIR.

declare -A BUNDLE_SRC=(
  [hypr]="config/hypr"
  [wallpapers]="config/wallpapers"
  [waybar]="config/waybar"
  [quickshell]="config/quickshell"
  [kitty]="config/kitty"
  [fuzzel]="config/fuzzel"
  [zsh]="config/shell/zsh"
  [bash]="config/shell/bash"
  [mako]="config/mako"
  [swayosd]="config/swayosd"
  [claude]="config/claude/themes"
  [vscodium]="config/vscodium/User"
  [kvantum]="config/kvantum"
  [kdeglobals]="config/kdeglobals"
  [qt5ct]="config/qt5ct"
  [qt6ct]="config/qt6ct"
  [gtk3]="config/gtk-3.0"
  [gtk4]="config/gtk-4.0"
  [themes]="config/themes"
)

declare -A BUNDLE_DEST=(
  [hypr]="${HOME}/.config/hypr"
  [wallpapers]="${HOME}/.config/wallpapers"
  [waybar]="${HOME}/.config/waybar"
  [quickshell]="${HOME}/.config/quickshell"
  [kitty]="${HOME}/.config/kitty"
  [fuzzel]="${HOME}/.config/fuzzel"
  [zsh]="${HOME}/.config/zsh"
  [bash]="${HOME}"
  [mako]="${HOME}/.config/mako"
  [swayosd]="${HOME}/.config/swayosd"
  [claude]="${HOME}/.claude/themes"
  [vscodium]="${HOME}/.config/VSCodium/User"
  [kvantum]="${HOME}/.config/Kvantum"
  [kdeglobals]="${HOME}/.config"
  [qt5ct]="${HOME}/.config/qt5ct"
  [qt6ct]="${HOME}/.config/qt6ct"
  [gtk3]="${HOME}/.config/gtk-3.0"
  [gtk4]="${HOME}/.config/gtk-4.0"
  [themes]="${HOME}/.local/share/themes"
)

declare -A BUNDLE_DESC=(
  [hypr]="Hyprland compositor config"
  [wallpapers]="Wallpaper assets"
  [waybar]="Waybar status bar config + scripts"
  [quickshell]="Quickshell QML bar & launcher"
  [kitty]="Kitty terminal emulator config"
  [fuzzel]="Fuzzel launcher config"
  [zsh]="ZSH config (Powerlevel10k + plugins)"
  [bash]="Bash config, aliases, and .zshenv"
  [mako]="Mako notification daemon config (config/mako/config → ~/.config/mako/config)"
  [swayosd]="swayOSD volume/brightness overlay — RaBbLE-Aether gradient ring + flowing text"
  [claude]="Claude Code RaBbLE theme (themes only — settings.json is not managed)"
  [vscodium]="VSCodium user settings — activates RaBbLE Aether theme (theme artifacts deploy from Aether via Ansible)"
  [kvantum]="Kvantum Qt theme — RaBbLE-Aether synthwave dark (void bg, #f8f4ff text, magenta+cyan accents)"
  [kdeglobals]="KDE color scheme (~/.config/kdeglobals) — drives Dolphin/Kate view+window text color; Kvantum only styles widget frames, not palette text"
  [qt5ct]="Qt5 config (kvantum style, Papirus-Dark icons, Exo 2 / Share Tech Mono fonts)"
  [qt6ct]="Qt6 config (kvantum style, Papirus-Dark icons, Exo 2 / Share Tech Mono fonts)"
  [gtk3]="GTK3 user stylesheet — Aether palette overlay (sidebar, selection, scrollbars, menus)"
  [gtk4]="GTK4 CSS variables — Aether palette (limited effect due to libadwaita sandboxing)"
  [themes]="GTK installed themes (RaBbLE-Aether) → ~/.local/share/themes"
)

BUNDLE_ORDER=(hypr wallpapers waybar quickshell kitty fuzzel zsh bash mako swayosd claude vscodium kvantum kdeglobals qt5ct qt6ct gtk3 gtk4 themes)

# Post-apply hooks — run after a bundle's files are deployed.
# Only set for bundles that need more than a file copy (e.g. patching a config key).
# Each value is a shell function name defined below.
declare -A BUNDLE_POST_APPLY=(
  [claude]="_post_apply_claude"
  [waybar]="_post_apply_waybar"
)

declare -A BUNDLE_RELOAD=(
  [hypr]="hyprctl reload"
  [wallpapers]="pkill -x hyprpaper || true; setsid --fork hyprpaper &>/dev/null"
  [waybar]="pkill -x waybar || true; setsid --fork waybar &>/dev/null"
  [quickshell]="pkill -x quickshell || true; setsid --fork quickshell &>/dev/null"
  [kitty]="echo 'kitty config live-reloads automatically (ctrl+shift+f5 to force)'"
  [fuzzel]="echo 'fuzzel reads config on each launch — no reload needed'"
  [zsh]="source ${HOME}/.config/zsh/.zshrc 2>/dev/null || true"
  [bash]="source ${HOME}/.bashrc 2>/dev/null || true"
  [mako]="makoctl reload"
)

# ── Post-apply hooks ──────────────────────────────────────────────────────────

# Merge the theme key into ~/.claude/settings.json without touching anything else.
# Never copies or clobbers the whole file — only sets .theme via jq.
_post_apply_claude() {
  local settings="${HOME}/.claude/settings.json"
  if [[ -f "$settings" ]]; then
    if ! command -v jq &>/dev/null; then
      warn "jq not found — skipping settings.json theme key update"
      warn "Run manually: jq '.theme = \"custom:rabble-theme\"' ${settings}"
      return
    fi
    local tmp
    tmp=$(mktemp)
    if jq '.theme = "custom:rabble-theme"' "$settings" > "$tmp"; then
      mv "$tmp" "$settings"
      info "theme key set in ~/.claude/settings.json"
    else
      rm -f "$tmp"
      warn "jq failed — settings.json theme key not updated"
    fi
  else
    mkdir -p "${HOME}/.claude"
    printf '{\n  "theme": "custom:rabble-theme"\n}\n' > "$settings"
    info "created ~/.claude/settings.json with theme key"
  fi
}

# Wire score-claude-hook.sh into ~/.claude/settings.json so the sCoRE Usage
# Tracker's live busy/ready/needs-input state (the whole point — Claude's own
# lifecycle events are ground truth, not a guess from transcript timestamps)
# works without a manual setup step. Merges — never clobbers — each event's
# hook array: our entry is appended only if it isn't already present, so any
# other hooks you add by hand survive re-applies untouched.
#
#   SessionStart / SessionEnd                   -> instance registered/removed
#   UserPromptSubmit / PreToolUse / PostToolUse -> busy
#   SubagentStop                                -> busy (parent still working)
#   Notification (permission)                   -> needs input (flashing magenta)
#   Notification (waiting for input)            -> ready (open prompt, not blocked)
#   Stop                                        -> ready
#
# Per-session state files + aggregation live in score-sessions.py — one file
# per running Claude instance, so multiple agents never clobber each other.
_post_apply_waybar() {
  local settings="${HOME}/.claude/settings.json"
  # Always the expanded absolute path — Claude Code normalizes "~/..." to it
  # on first run, so matching against "~/..." here would never dedupe.
  local cmd
  cmd="$(realpath -m "${HOME}/.config/waybar/scripts/score-claude-hook.sh")"

  if ! command -v jq &>/dev/null; then
    warn "jq not found — skipping score-claude-hook.sh wiring in settings.json"
    warn "Hook script lives at: ${cmd}"
    return
  fi

  [[ -f "$settings" ]] || { mkdir -p "${HOME}/.claude"; echo '{}' > "$settings"; }

  local tmp
  tmp=$(mktemp)
  if jq --arg cmd "$cmd" '
      def ensure_hook(event):
        .hooks[event] = ((.hooks[event] // [])
          | if any(.[]?.hooks[]?.command == $cmd; .) then .
            else . + [{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}]
            end);
      ensure_hook("Notification") | ensure_hook("PreToolUse") | ensure_hook("PostToolUse")
        | ensure_hook("UserPromptSubmit") | ensure_hook("Stop") | ensure_hook("SubagentStop")
        | ensure_hook("SessionStart") | ensure_hook("SessionEnd")
    ' "$settings" > "$tmp"; then
    mv "$tmp" "$settings"
    info "score-claude-hook.sh wired into ~/.claude/settings.json (full lifecycle: session/prompt/tool/permission/stop)"
  else
    rm -f "$tmp"
    warn "jq failed — score-claude-hook.sh not wired into settings.json"
  fi

  # Wire score-codex-notify.sh as Codex's `notify` program — its only hook
  # surface (agent-turn-complete) — for an instant "ready" flip + desktop
  # notification when a Codex turn finishes. `notify` is a top-level TOML
  # key, so it must land before the first [table]; inserting at line 1 is
  # the only always-safe spot. Skipped if any notify key already exists —
  # never clobbers a hand-rolled notify program.
  local codex_cfg="${HOME}/.codex/config.toml"
  local notify_cmd
  notify_cmd="$(realpath -m "${HOME}/.config/waybar/scripts/score-codex-notify.sh")"
  if [[ -f "$codex_cfg" ]]; then
    if grep -q '^notify' "$codex_cfg"; then
      info "codex config.toml already has a notify program — left untouched"
    else
      sed -i "1i notify = [\"${notify_cmd}\"]" "$codex_cfg"
      info "score-codex-notify.sh wired into ~/.codex/config.toml (turn-complete)"
    fi
  fi
}

# ── Helpers ───────────────────────────────────────────────────────────────────

bundle_exists() {
  [[ -n "${BUNDLE_SRC[$1]+_}" ]]
}

resolve_bundles() {
  local arg="${1:-all}"
  if [[ "$arg" == "all" ]]; then
    echo "${BUNDLE_ORDER[@]}"
  else
    bundle_exists "$arg" || fail "Unknown bundle: '$arg'. Known: ${BUNDLE_ORDER[*]}"
    echo "$arg"
  fi
}

# Walk all source files in a bundle, invoke: callback src_file dest_file rel_path
walk_bundle() {
  local bundle="$1"
  local callback="$2"
  local src_root="${SCRIPT_DIR}/${BUNDLE_SRC[$bundle]}"
  local dest_root="${BUNDLE_DEST[$bundle]}"

  if [[ ! -d "$src_root" ]]; then
    warn "Bundle '${bundle}' source not found, skipping: ${src_root}"
    return 0
  fi

  while IFS= read -r -d '' src_file; do
    local rel="${src_file#${src_root}/}"
    local dest_file="${dest_root}/${rel}"
    "$callback" "$src_file" "$dest_file" "$rel"
  done < <(find "$src_root" -type f -print0 | sort -z)
}

# ── apply ─────────────────────────────────────────────────────────────────────

_apply_file() {
  local src="$1" dest="$2" rel="$3"
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  [[ "$src" == */scripts/* ]] && chmod 755 "$dest"
  info "$rel"
}

cmd_apply() {
  local -a bundles
  read -ra bundles <<< "$(resolve_bundles "${1:-all}")"

  for bundle in "${bundles[@]}"; do
    pulse "Applying: ${BUNDLE_DESC[$bundle]}"
    walk_bundle "$bundle" _apply_file
    local post_fn="${BUNDLE_POST_APPLY[$bundle]:-}"
    [[ -n "$post_fn" ]] && "$post_fn"
    ok "Bundle '${bundle}' deployed. // %CONFIG_APPLIED%"
    echo
  done
}

# ── pull ──────────────────────────────────────────────────────────────────────

_pull_file() {
  local src="$1" dest="$2" rel="$3"
  if [[ -f "$dest" ]]; then
    mkdir -p "$(dirname "$src")"
    cp "$dest" "$src"
    info "$rel"
  else
    muted "not deployed, skipping: $rel"
  fi
}

cmd_pull() {
  local bundle="${1:-}"
  [[ -z "$bundle" ]] && fail "pull requires a specific bundle. Usage: dotctl pull BUNDLE"
  bundle_exists "$bundle" || fail "Unknown bundle: '$bundle'. Known: ${BUNDLE_ORDER[*]}"

  pulse "Pulling deployed config → repo: ${BUNDLE_DESC[$bundle]}"
  warn "This overwrites repo files with whatever is live in ${BUNDLE_DEST[$bundle]}."
  read -rp "$(echo -e "${RED}  Confirm pull for '${bundle}'? [y/N]: ${RESET}")" confirm
  [[ "${confirm:-N}" =~ ^[Yy]$ ]] || { info "Aborted."; return; }

  echo
  walk_bundle "$bundle" _pull_file
  ok "Bundle '${bundle}' pulled. Review with 'diff ${bundle}' then commit what you want to keep."
}

# ── status ────────────────────────────────────────────────────────────────────

_status_file() {
  local src="$1" dest="$2" rel="$3"
  local state color

  if [[ ! -f "$dest" ]]; then
    state="missing"
    color="$RED"
  else
    local src_sum dest_sum
    src_sum=$(sha256sum  "$src"  | cut -d' ' -f1)
    dest_sum=$(sha256sum "$dest" | cut -d' ' -f1)
    if [[ "$src_sum" == "$dest_sum" ]]; then
      state="in-sync"
      color="$GREEN"
    else
      state="drifted"
      color="$YELLOW"
    fi
  fi

  printf "  ${MUTED}%-44s${RESET} ${color}%s${RESET}\n" "$rel" "$state"
}

cmd_status() {
  local -a bundles
  read -ra bundles <<< "$(resolve_bundles "${1:-all}")"

  echo
  pulse "RaBbLE-OS Dotfile Status"

  for bundle in "${bundles[@]}"; do
    divider
    printf "  ${BOLD}${CYAN}%s${RESET}  —  %s\n" "$bundle" "${BUNDLE_DESC[$bundle]}"
    printf "  ${MUTED}%-44s %s${RESET}\n" "FILE" "STATE"
    divider
    walk_bundle "$bundle" _status_file
  done

  divider
  echo
  muted "Repo config root: ${SCRIPT_DIR}/config/"
  echo
}

# ── diff ──────────────────────────────────────────────────────────────────────

_diff_file() {
  local src="$1" dest="$2" rel="$3"
  if [[ ! -f "$dest" ]]; then
    warn "not deployed: ${rel}"
    return
  fi
  if ! diff -q "$src" "$dest" &>/dev/null; then
    echo -e "${CYAN}── ${rel} ──────────────────────────────────────${RESET}"
    # diff -u repo deployed → '+' means live has something repo doesn't
    diff -u "$src" "$dest" || true
    echo
  fi
}

cmd_diff() {
  local -a bundles
  read -ra bundles <<< "$(resolve_bundles "${1:-all}")"

  for bundle in "${bundles[@]}"; do
    pulse "Diff: ${BUNDLE_DESC[$bundle]}  (− repo  + deployed)"
    walk_bundle "$bundle" _diff_file
    echo
  done
}

# ── reload ───────────────────────────────────────────────────────────────────

cmd_reload() {
  local -a bundles
  read -ra bundles <<< "$(resolve_bundles "${1:-all}")"

  for bundle in "${bundles[@]}"; do
    local reload_cmd="${BUNDLE_RELOAD[$bundle]:-}"
    if [[ -z "$reload_cmd" ]]; then
      muted "no reload defined for '${bundle}' — skipping"
      continue
    fi
    pulse "Reloading: ${BUNDLE_DESC[$bundle]}"
    eval "$reload_cmd"
    ok "Bundle '${bundle}' reloaded. // %RELOADED%"
  done
}

# ── list ──────────────────────────────────────────────────────────────────────

cmd_list() {
  echo
  pulse "Known bundles"
  divider
  for bundle in "${BUNDLE_ORDER[@]}"; do
    local src_root="${SCRIPT_DIR}/${BUNDLE_SRC[$bundle]}"
    local count
    count=$(find "$src_root" -type f 2>/dev/null | wc -l)
    printf "  ${CYAN}%-16s${RESET} %-32s ${MUTED}%s files${RESET}\n" \
      "$bundle" "${BUNDLE_DESC[$bundle]}" "$count"
  done
  echo
}

# ── help ──────────────────────────────────────────────────────────────────────

cmd_help() {
  echo
  echo -e "${MAGENTA}${BOLD}dotctl${RESET} — RaBbLE-OS Dotfile Deployment"
  echo
  echo -e "${BOLD}COMMANDS${RESET}"
  echo -e "  ${CYAN}apply${RESET}  [bundle|all]"
  echo -e "          Copy repo configs → ~/.config/. Creates dirs, sets +x on scripts."
  echo
  echo -e "  ${CYAN}pull${RESET}   BUNDLE"
  echo -e "          Copy deployed configs → repo. Use after live edits you want to keep."
  echo -e "          Requires explicit bundle — no accidental full pulls."
  echo
  echo -e "  ${CYAN}status${RESET} [bundle|all]"
  echo -e "          Show per-file state: in-sync / drifted / missing."
  echo
  echo -e "  ${CYAN}diff${RESET}   [bundle|all]"
  echo -e "          Line diff between repo and deployed. (+) = live has it, (−) = repo has it."
  echo
  echo -e "  ${CYAN}reload${RESET} [bundle|all]"
  echo -e "          Reload a running bundle. Detached — no shell ownership."
  echo
  echo -e "  ${CYAN}list${RESET}"
  echo -e "          List all known bundles and file counts."
  echo
  echo -e "${BOLD}BUNDLES${RESET}"
  for bundle in "${BUNDLE_ORDER[@]}"; do
    printf "  ${CYAN}%-16s${RESET} %s\n" "$bundle" "${BUNDLE_DESC[$bundle]}"
  done
  echo
  echo -e "${BOLD}EXAMPLES${RESET}"
  echo -e "  ${MUTED}./RaBbLE-OS-dotctl.sh apply hypr${RESET}"
  echo -e "  ${MUTED}./RaBbLE-OS-dotctl.sh status${RESET}"
  echo -e "  ${MUTED}./RaBbLE-OS-dotctl.sh diff hypr${RESET}"
  echo -e "  ${MUTED}./RaBbLE-OS-dotctl.sh pull hypr${RESET}"
  echo -e "  ${MUTED}./RaBbLE-OS-dotctl.sh reload waybar${RESET}"
  echo
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
  apply)   cmd_apply  "${1:-}" ;;
  pull)    cmd_pull   "${1:-}" ;;
  status)  cmd_status "${1:-}" ;;
  diff)    cmd_diff   "${1:-}" ;;
  reload)  cmd_reload "${1:-}" ;;
  list)    cmd_list ;;
  help|-h|--help) cmd_help ;;
  *)
    warn "Unknown command: '${COMMAND}'"
    cmd_help
    exit 1
    ;;
esac
