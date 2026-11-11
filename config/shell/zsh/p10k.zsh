# p10k.zsh — RaBbLE-OS Powerlevel10k stub
# p10k is installed to ~/.local/share/powerlevel10k but not active.
# Native precmd prompt is used instead (see .zshrc).
#
# To activate p10k:
#   1. In .zshrc, replace the "── Prompt" block with:
#        source ~/.local/share/powerlevel10k/powerlevel10k.zsh-theme
#        [[ -f "${ZDOTDIR}/p10k.zsh" ]] && source "${ZDOTDIR}/p10k.zsh"
#   2. Run: p10k configure   (generates a full config interactively)
#      Or hand-roll this file using the Powerlevel10k reference:
#      https://github.com/romkatv/powerlevel10k#configuration

'builtin' 'local' '-a' 'p10k_config_opts'
[[ ! -o 'aliases'         ]] || p10k_config_opts+=('aliases')
[[ ! -o 'sh_glob'         ]] || p10k_config_opts+=('sh_glob')
[[ ! -o 'no_brace_expand' ]] || p10k_config_opts+=('no_brace_expand')
'builtin' 'setopt' 'no_aliases' 'no_sh_glob' 'brace_expand'

() {
    emulate -L zsh -o extended_glob
    unset -m '(POWERLEVEL9K_*|DEFAULT_USER)~POWERLEVEL9K_GITSTATUS_DIR'
    autoload -Uz is-at-least && is-at-least 5.1 || return

    # Configure segments and appearance here when activating.
    # Run `p10k configure` to generate a full starting config.

    (( ! $+functions[p10k] )) || p10k reload
}

(( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}
'builtin' 'unset' 'p10k_config_opts'
