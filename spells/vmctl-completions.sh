#!/usr/bin/env bash
# Shell completions for RaBbLE-OS-vmctl.sh
# Source this file in .bashrc or .zshrc:
#   source /path/to/spells/vmctl-completions.sh

_vmctl_completions() {
    local commands="partition-setup setup cast cast-ks recast status start stop connect ssh logs snapshot restore snapshots destroy help"
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"

    case "$prev" in
        stop)
            COMPREPLY=($(compgen -W "--force --timeout" -- "$cur"))
            return ;;
        cast|cast-ks|recast)
            COMPREPLY=($(compgen -W "--raw-disk" -- "$cur"))
            compopt -o filenames 2>/dev/null
            COMPREPLY+=($(compgen -f -X '!*.iso' -- "$cur"))
            return ;;
        restore)
            local vm="${RABBLE_VM_NAME:-rabble-os-dev}"
            local snaps
            snaps=$(virsh snapshot-list "$vm" --name 2>/dev/null)
            COMPREPLY=($(compgen -W "$snaps" -- "$cur"))
            return ;;
        --raw-disk)
            compopt -o filenames 2>/dev/null
            COMPREPLY=($(compgen -f -d -- "${cur:-/dev/}" ))
            return ;;
    esac

    if [[ ${COMP_CWORD} -le 1 ]] || [[ "${COMP_WORDS[1]}" == --* ]]; then
        COMPREPLY=($(compgen -W "$commands --quiet" -- "$cur"))
    fi
}

complete -F _vmctl_completions vmctl
complete -F _vmctl_completions RaBbLE-OS-vmctl.sh
complete -F _vmctl_completions ./RaBbLE-OS-vmctl.sh

if [[ -n "$ZSH_VERSION" ]]; then
    autoload -U +X bashcompinit 2>/dev/null && bashcompinit
    complete -F _vmctl_completions vmctl
    complete -F _vmctl_completions RaBbLE-OS-vmctl.sh
    complete -F _vmctl_completions ./RaBbLE-OS-vmctl.sh
fi
