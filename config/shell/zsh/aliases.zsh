# aliases.zsh — shared aliases sourced by both zsh and bash
# Keep syntax POSIX-compatible (no zsh-isms here)

# ── Navigation ────────────────────────────────────────────────────────────────
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ~='cd ~'

# ── eza (ls replacement) ──────────────────────────────────────────────────────
if command -v eza &>/dev/null; then
    alias ls='eza --icons --group-directories-first --color=auto'
    alias ll='eza --icons --group-directories-first -lah --git'
    alias lt='eza --icons --tree --level=2'
    alias lta='eza --icons --tree --level=3 -a'
else
    alias ls='ls --color=auto'
    alias ll='ls -lahF'
fi

# ── bat (cat replacement) ─────────────────────────────────────────────────────
if command -v bat &>/dev/null; then
    alias cat='bat --style=plain'
    alias bcat='bat'
fi

# ── Grep ──────────────────────────────────────────────────────────────────────
alias grep='grep --color=auto'
alias rg='rg --color=auto'

# ── Git ───────────────────────────────────────────────────────────────────────
alias g='git'
alias gs='git status -sb'
alias ga='git add'
alias gaa='git add --all'
alias gc='git commit'
alias gcm='git commit -m'
alias gca='git commit --amend'
alias gp='git push'
alias gpl='git pull'
alias gl='git log --oneline --graph --decorate --all'
alias gd='git diff'
alias gds='git diff --staged'
alias gco='git checkout'
alias gcb='git checkout -b'
alias gbr='git branch'
alias gst='git stash'
alias gstp='git stash pop'

# ── System ────────────────────────────────────────────────────────────────────
alias df='df -h'
alias du='du -sh'
alias free='free -h'
alias ps='ps aux'
alias top='btop'
alias mk='make'
alias py='python3'
alias pip='pip3'
alias vim='nvim'
alias v='nvim'

# ── RaBbLE-OS ─────────────────────────────────────────────────────────────────
# `rabble` itself is the Crew launcher (~/.local/bin/rabble, RaBbLE-sCoRE crew/rabble.py), not an alias
alias rabble-apply='cd ~/RaBbLE-Collective/RaBbLE-OS && ./RaBbLE-OS-layerctl.sh apply all'
alias rabble-dots='cd ~/RaBbLE-Collective/RaBbLE-OS && ./RaBbLE-OS-dotctl.sh apply all'
alias hypr-reload='hyprctl reload'
alias hypr-kill='hyprctl kill'
alias qs-restart='pkill quickshell; sleep 0.5; quickshell &'

# ── Hyprland helpers ──────────────────────────────────────────────────────────
alias hws='hyprctl workspaces'
alias hcl='hyprctl clients'
alias hmon='hyprctl monitors'
alias hdis='hyprctl dispatch'

# ── Package management (dnf) ──────────────────────────────────────────────────
alias dnfi='sudo dnf install'
alias dnfr='sudo dnf remove'
alias dnfu='sudo dnf upgrade'
alias dnfs='dnf search'
alias dnfq='dnf info'

# ── Wayland utilities ─────────────────────────────────────────────────────────
alias wlpaste='wl-paste'
alias wlcopy='wl-copy'
alias ss='~/.config/hypr/scripts/screenshot.sh region'
alias ssf='~/.config/hypr/scripts/screenshot.sh full'
alias ssw='~/.config/hypr/scripts/screenshot.sh window'

# ── Network ───────────────────────────────────────────────────────────────────
alias ip='ip --color=auto'
alias ports='ss -tulnp'
alias myip='curl -s https://api.ipify.org && echo'

# ── Misc ──────────────────────────────────────────────────────────────────────
alias cls='clear'
alias reload='exec $SHELL'
alias path='echo $PATH | tr ":" "\n"'
alias now='date +"%Y-%m-%d %H:%M:%S"'
alias week='date +%V'
alias weather='curl -s wttr.in/?format=3'
alias todo='$EDITOR ~/todo.md'
