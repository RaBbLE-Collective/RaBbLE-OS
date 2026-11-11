# functions.zsh — RaBbLE-OS ZSH utility functions

# ── Directory ─────────────────────────────────────────────────────────────────

mkcd() { mkdir -p "$1" && cd "$1" }

cdl() { cd "$1" && ls }

fcd() {
    local dir
    dir=$(fd --type d --hidden --exclude .git 2>/dev/null | \
          fzf --preview 'eza --icons --color=always {}') \
        && cd "$dir"
}

# ── File operations ───────────────────────────────────────────────────────────

fe() {
    local file
    file=$(fd --type f --hidden --exclude .git 2>/dev/null | \
           fzf --preview 'bat --style=numbers --color=always --line-range :50 {}') \
        && ${EDITOR:-nvim} "$file"
}

extract() {
    if [[ -z "$1" ]]; then echo "Usage: extract <archive>"; return 1; fi
    if [[ ! -f "$1" ]]; then echo "extract: '$1' is not a valid file"; return 1; fi
    case "$1" in
        *.tar.bz2)  tar xjf "$1"         ;;
        *.tar.gz)   tar xzf "$1"         ;;
        *.tar.xz)   tar xJf "$1"         ;;
        *.tar.zst)  tar --zstd -xf "$1"  ;;
        *.tar)      tar xf  "$1"         ;;
        *.bz2)      bunzip2 "$1"         ;;
        *.gz)       gunzip  "$1"         ;;
        *.xz)       unxz    "$1"         ;;
        *.zip)      unzip   "$1"         ;;
        *.7z)       7z x    "$1"         ;;
        *.rar)      unrar x "$1"         ;;
        *.zst)      zstd -d "$1"         ;;
        *)          echo "extract: unknown format '$1'" ;;
    esac
}

# ── Process / system ──────────────────────────────────────────────────────────

fkill() {
    local pid
    pid=$(ps -ef | sed 1d | fzf -m | awk '{print $2}')
    if [[ -n "$pid" ]]; then
        echo "Killing PID(s): $pid"
        echo "$pid" | xargs kill -"${1:-9}"
    fi
}

serve() {
    local port="${1:-8000}"
    echo "Serving $(pwd) on http://localhost:${port}"
    python3 -m http.server "$port"
}

# ── Git helpers ───────────────────────────────────────────────────────────────

fgco() {
    local branch
    branch=$(git branch --all | grep -v HEAD | sed 's/remotes\/origin\///' | \
             sort -u | fzf --preview 'git log --oneline --graph --color=always {}') \
        && git checkout "${branch//\* /}"
}

fgl() {
    git log --oneline --color=always | \
        fzf --ansi --preview 'git show --color=always {1}' \
            --bind 'enter:execute(git show --color=always {1} | less -R)'
}

fgst() {
    local stash
    stash=$(git stash list | fzf --preview 'git stash show -p {1}') \
        && git stash pop "$(echo "$stash" | cut -d: -f1)"
}

# ── Wayland / Hyprland helpers ────────────────────────────────────────────────

wininfo() {
    hyprctl activewindow -j | jq '{class, title, workspace: .workspace.name, size, at}'
}

wmove() {
    hyprctl dispatch movetoworkspace "$1"
}

hreload() {
    hyprctl reload && echo "Hyprland config reloaded"
}

# ── Network helpers ───────────────────────────────────────────────────────────

portscan() {
    nmap -sV --open -p- "${1:-localhost}"
}

netwatch() {
    watch -n1 'ss -tulnp'
}

# ── Development helpers ───────────────────────────────────────────────────────

venv() {
    local name="${1:-.venv}"
    if [[ ! -d "$name" ]]; then
        python3 -m venv "$name"
        echo "Created venv: $name"
    fi
    source "${name}/bin/activate"
    echo "Activated: $name"
}

notify-done() {
    "$@"
    local rc=$?
    if (( rc == 0 )); then
        notify-send "Done" "'$*' completed successfully" -t 5000
    else
        notify-send -u critical "Failed" "'$*' exited with $rc" -t 8000
    fi
    return $rc
}

# ── Misc helpers ──────────────────────────────────────────────────────────────

bak() {
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    cp -v "$1" "${1}.${ts}.bak"
}

note() {
    local file="${HOME}/notes/$(date +%Y-%m-%d).md"
    mkdir -p "${HOME}/notes"
    echo "## $(date +%H:%M) — $*" >> "$file"
    echo "Appended to $file"
}

notes() {
    local file="${HOME}/notes/$(date +%Y-%m-%d).md"
    [[ -f "$file" ]] && ${PAGER:-less} "$file" || echo "No notes for today."
}

colors256() {
    for i in {0..255}; do
        printf "\e[38;5;%dm%3d \e[0m" "$i" "$i"
        (( (i+1) % 16 == 0 )) && echo
    done
}

# ── RaBbLE helpers ────────────────────────────────────────────────────────────

rabble-sync() {
    local repo="${RABBLE_ROOT:-${HOME}/RaBbLE-OS}"
    "${repo}/RaBbLE-OS-dotctl.sh" apply all
}

qs-reload() {
    quickshell ipc call shell reload 2>/dev/null || {
        pkill -x quickshell
        sleep 0.3
        nohup quickshell >/dev/null 2>&1 &
        echo "Quickshell restarted"
    }
}
