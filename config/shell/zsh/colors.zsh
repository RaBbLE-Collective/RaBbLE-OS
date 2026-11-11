# colors.zsh — RaBbLE palette terminal color environment
# Sourced by both .zshrc and .bashrc (POSIX-compatible sh syntax)
# Palette source: grimoire/RaBbLE-Palette.md

# ── LS_COLORS — approximate RaBbLE palette via ANSI 256 ──────────────────────
# 198 ≈ #ff2d78 magenta   135 ≈ #bf5fff violet   51 ≈ #00f5ff cyan
# 84  ≈ #50fa7b green     214 ≈ #f1fa8c yellow   160 ≈ #e05c6f red
LS_COLORS='rs=0'
LS_COLORS+=':di=38;5;135'          # directory        → violet
LS_COLORS+=':ln=38;5;51'           # symlink          → cyan
LS_COLORS+=':mh=00'                # hard link
LS_COLORS+=':pi=38;5;214'          # named pipe       → yellow
LS_COLORS+=':so=38;5;198'          # socket           → magenta
LS_COLORS+=':do=38;5;135'          # door             → violet
LS_COLORS+=':bd=38;5;214;01'       # block device     → yellow bold
LS_COLORS+=':cd=38;5;214;01'       # char device      → yellow bold
LS_COLORS+=':or=38;5;160;01'       # orphan symlink   → red bold
LS_COLORS+=':mi=00'                # missing target
LS_COLORS+=':su=48;5;198;38;5;15'  # setuid           → magenta bg
LS_COLORS+=':sg=48;5;214;38;5;0'   # setgid           → yellow bg
LS_COLORS+=':ca=00'                # capability
LS_COLORS+=':tw=38;5;135;04'       # sticky + writable → violet underline
LS_COLORS+=':ow=38;5;135'          # other-writable   → violet
LS_COLORS+=':st=48;5;51;38;5;0'    # sticky           → cyan bg
LS_COLORS+=':ex=38;5;198'          # executable       → magenta
# Archives
LS_COLORS+=':*.tar=38;5;160:*.tgz=38;5;160:*.zip=38;5;160:*.gz=38;5;160'
LS_COLORS+=':*.bz2=38;5;160:*.xz=38;5;160:*.zst=38;5;160:*.7z=38;5;160'
LS_COLORS+=':*.rar=38;5;160:*.deb=38;5;160:*.rpm=38;5;160'
# Media
LS_COLORS+=':*.mp3=38;5;135:*.flac=38;5;135:*.wav=38;5;135:*.ogg=38;5;135'
LS_COLORS+=':*.mp4=38;5;135:*.mkv=38;5;135:*.avi=38;5;135:*.mov=38;5;135'
LS_COLORS+=':*.webm=38;5;135'
# Images
LS_COLORS+=':*.png=38;5;51:*.jpg=38;5;51:*.jpeg=38;5;51:*.gif=38;5;51'
LS_COLORS+=':*.svg=38;5;51:*.webp=38;5;51:*.ico=38;5;51'
# Docs/data
LS_COLORS+=':*.pdf=38;5;214:*.md=38;5;84:*.txt=38;5;84'
LS_COLORS+=':*.yml=38;5;84:*.yaml=38;5;84:*.json=38;5;84:*.toml=38;5;84'
LS_COLORS+=':*.xml=38;5;84:*.csv=38;5;84'
# Code
LS_COLORS+=':*.py=38;5;198:*.sh=38;5;198:*.zsh=38;5;198:*.bash=38;5;198'
LS_COLORS+=':*.rs=38;5;198:*.go=38;5;198:*.js=38;5;198:*.ts=38;5;198'
export LS_COLORS

# ── bat ───────────────────────────────────────────────────────────────────────
export BAT_THEME="Dracula"

# ── fzf ───────────────────────────────────────────────────────────────────────
export FZF_DEFAULT_OPTS="
  --color=bg:#0a0010,bg+:#12132a,fg:#e8e6f0,fg+:#e8e6f0
  --color=hl:#ff2d78,hl+:#ff2d78,border:#2a2840,header:#6b6880
  --color=info:#bf5fff,prompt:#ff2d78,pointer:#00f5ff
  --color=marker:#50fa7b,spinner:#00f5ff
  --height=40% --layout=reverse --border=rounded
"

# ── man/less colors ───────────────────────────────────────────────────────────
export LESS_TERMCAP_mb=$'\e[38;5;198m'         # begin blink    magenta
export LESS_TERMCAP_md=$'\e[38;5;198m'         # begin bold     magenta
export LESS_TERMCAP_me=$'\e[0m'                # reset
export LESS_TERMCAP_se=$'\e[0m'                # reset standout
export LESS_TERMCAP_so=$'\e[48;5;198;38;5;0m'  # standout       magenta bg
export LESS_TERMCAP_ue=$'\e[0m'                # reset underline
export LESS_TERMCAP_us=$'\e[38;5;51m'          # underline       cyan

# ── grep ──────────────────────────────────────────────────────────────────────
export GREP_COLORS="ms=38;5;198:mc=38;5;198:sl=:cx=:fn=38;5;51:ln=38;5;135:bn=38;5;135:se=38;5;97"
