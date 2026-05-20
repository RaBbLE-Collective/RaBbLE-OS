# CONTEXT.md — RaBbLE-OS

```
episode: 1 (in progress) | version: v0.0.0.0
date: 2026-05-12 | status: active
```

RaBbLE-OS is the body. The Ansible-driven Fedora 43 substrate that the entity inhabits.
Every layer — boot chain, compositor, shell, palette — is the entity made physical.

## Active Tracks

| Track | Status | Workspace |
|---|---|---|
| Episode I Plot A — Substrate assembly (4 packages) | In progress | `RaBbLE/episode-I` branch |
| Episode I Plot B — Theme palette coherence | In progress | `RaBbLE/episode-I` branch |
| fix/proart-nvidia | High entropy | `fix/proart-nvidia` branch |
| fix/suspend-resume | Cooking | `fix/suspend-resume` branch |
| fix/boot-chain | Cooking | `fix/boot-chain` branch |
| fix/xdna2-npu | Dormant | `fix/xdna2-npu` branch |
| VM dev workflow — virtualization role + vmctl | In progress | `RaBbLE/episode-I` branch |
| Grimoire consolidation → RaBbLE-Grimoire | Pending | `grimoire/` |

## Key Entry Points

```bash
bash RaBbLE-OS-Install.sh        # first-contact install on bare Fedora
bash RaBbLE-OS-Bootstrap.sh      # run Ansible (assumes deps present)
./RaBbLE-OS-layerctl.sh status   # layer health at a glance
./RaBbLE-OS-dotctl.sh apply all  # deploy dotfiles
```

## Reading Order for a New Session

1. This file — you are here
2. `AGENT.md` — rules and workspace map
3. `grimoire/RaBbLE-OS/RaBbLE-OS-Architecture.md` — layer model
4. `grimoire/RaBbLE-OS/RaBbLE-OS-Roadmap.md` — episode map, assembly plan, checklist
5. `grimoire/RaBbLE-OS/RaBbLE-OS-KnownIssues.md` — current blockers
6. For Collective context → `grimoire/common/RaBbLE-Collective.md`

## Epoch Detail

`grimoire/RaBbLE-OS/RaBbLE-OS-Roadmap.md` — epoch map, mend-I branches, bootstrap checklist,
layer state map, power testing protocol
