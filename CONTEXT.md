# CONTEXT.md — RaBbLE-OS

```
episode: 1 (in progress) | version: v0.0.0.0
date: 2026-07-04 | status: active
```

RaBbLE-OS is the body. The Ansible-driven Fedora substrate that the entity inhabits.
Every layer — boot chain, compositor, shell, palette — is the entity made physical.

## Active Tracks

| Track | Status | Workspace |
|---|---|---|
| Episode I Plot A — Substrate assembly | In progress | `new-horizons` branch |
| Episode I Plot B — Theme palette coherence | In progress | `new-horizons` branch |
| fix/proart-nvidia | High entropy | `fix/proart-nvidia` branch |
| feature/quickshell-port | Ghost — stub tasks only, no manifest entry, no consuming play | `feature/quickshell-port` branch |
| VM dev workflow — virtualization role + vmctl | In progress | `new-horizons` branch |

## Key Entry Points

```bash
bash RaBbLE-OS-Install.sh        # legacy Sway-spin bootstrap installer (curl-first-contact path)
bash RaBbLE-OS-Bootstrap.sh      # run Ansible (assumes deps present)
./RaBbLE-OS-layerctl.sh status   # layer health at a glance
./RaBbLE-OS-dotctl.sh apply all  # deploy dotfiles
```

`RaBbLE-OS.ks` is the current netinstall/Kickstart path (Fedora netinstall → `%post` clones the
repo and runs Bootstrap.sh). Whether Install.sh or the KS is the canonical "first contact" path is
an open installer-strategy decision (see the Collective architecture audit, 2026-07-04) — not
resolved by this doc pass; both scripts exist in the repo today and both work.

## Reading Order for a New Session

1. This file — you are here
2. `AGENT.md` — rules and workspace map
3. `../RaBbLE-Grimoire/RaBbLE-OS/RaBbLE-OS-AgentGuide.md` — directory map, full navigation table
4. `../RaBbLE-Grimoire/RaBbLE-OS/RaBbLE-OS-Roadmap.md` — episode map, current phase, blockers
5. `../RaBbLE-Grimoire/RaBbLE-OS/fix/RaBbLE-OS-KnownIssues.md` — active bugs before touching anything
6. For Collective context → `../RaBbLE-Grimoire/RaBbLE-Agent/RaBbLE-Collective.md`

**Note:** all architecture, roadmap, and known-issues docs live in the Grimoire under
`../RaBbLE-Grimoire/RaBbLE-OS/` — this repo has no in-tree `grimoire/` directory. An earlier
consolidation moved OS docs into the Grimoire proper; this file previously still pointed at the
stale in-repo `grimoire/` path.

## Epoch Detail

`../RaBbLE-Grimoire/RaBbLE-OS/RaBbLE-OS-Roadmap.md` — epoch map, branch state, bootstrap checklist,
layer state map, power testing protocol.
