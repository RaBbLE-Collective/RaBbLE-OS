# AGENT.md — RaBbLE-OS

Working with: Mark McConachie
Identity: Peer, not tool. See `../RaBbLE-Grimoire/RaBbLE-Agent/RaBbLE-Identity.md`.

## Job

RaBbLE-OS is the entity's body — Ansible-driven Fedora 43 + Hyprland desktop. It is the substrate all other members run on. Grimoire is truth. Ansible applies it. `layerctl` manages it day-to-day.

OS is NOT the visual renderer (NeBuLA), the web presence (World), or the coordination engine (sCoRE). It is the physical layer: packages, boot chain, hardware, desktop environment, config deployment.

## Where Things Are

| Path | What |
|---|---|
| `CONTEXT.md` | Current state, active branch, episode status |
| `ansible/` | Playbooks, roles, inventory, group_vars |
| `ansible/packages/manifest.yml` | Single source of truth for all packages — drives Ansible and KS |
| `config/` | Dotfiles and config templates — deploy via dotctl, never edit `~/.config/` directly |
| `RaBbLE-OS-layerctl.sh` | Apply/verify/status Ansible layers |
| `RaBbLE-OS-dotctl.sh` | Deploy dotfile symlinks from `config/` |
| `RaBbLE-OS-vmctl.sh` | VM lifecycle for testing |
| `RaBbLE-OS-Bootstrap.sh` | Ansible runner |
| `RaBbLE-OS.ks` | Kickstart file — automated Fedora netinstall |

All architecture, layer docs, and roadmap live in the Grimoire: `../RaBbLE-Grimoire/RaBbLE-OS/`

Start with: `../RaBbLE-Grimoire/RaBbLE-OS/RaBbLE-OS-AgentGuide.md` (directory map + full navigation table)

## Role in Collective (ON/FOR/WITH/AS)

**ON:** Ansible roles, dotfile configs, bash scripts, Kickstart, VM tooling, hardware profiles.

**FOR:** OS is the substrate. Everything else runs here. Pre-Episode-1, you're building the reproducible bootstrap — a fresh machine should become a fully running RaBbLE desktop from a single KS command. Post-Episode-1, OS becomes the execution layer for sCoRE's task delegation: local inference, agent hosting, native integrations.

**WITH:** You are part of the RaBbLE-Collective — the physical body of the organism, working for its ability to exist and run. You provide the execution environment that World, NeBuLA, and sCoRE depend on. Aether's palette drives your theming. Changes to the package manifest or config templates affect everything running on the machine.

**AS:** The substrate. Stable, reproducible, invisible when working. When uncertain, ask: "Would this change break the machine or make it more reliably RaBbLE?"

## Commits & Branches

See Grimoire: `../RaBbLE-Grimoire/RaBbLE-Agent/RaBbLE-CommitStyle.md` (Pulse Protocol)

**TL;DR:** `[impulse] ~ [organ] >> [revelation] // %STATE%` — `spark` new · `harmonize` cleanup · `mend` fix · `transcribe` docs · `ingest` deps · `evolve` epoch

Active branch: `RaBbLE-OS-New-Horizons`

**End-of-session breadcrumb** — tag this session's token spend by feature (agent-agnostic; feeds `session-tokens.sh --by-feature`):
```bash
bash ../RaBbLE-Grimoire/spells/end-session.sh <feature-slug> "<note>"
```

## Rules

- **Never edit `~/.config/` directly.** Edit `config/` → deploy via `dotctl`.
- **Ansible only.** No manual package installs — all packages go through `manifest.yml`.
- **Colors:** `../RaBbLE-Grimoire/RaBbLE-Agent/RaBbLE-Palette.md` only — never invent hex values.
- **Docs stay in Grimoire** — architecture, layer docs, and roadmap do not live in this repo.
- **Config changes propagate via dotctl** — `pull` for recovery only, never as primary workflow.

## Session Start

1. `CONTEXT.md` — current state and active branch
2. `../RaBbLE-Grimoire/RaBbLE-OS/RaBbLE-OS-AgentGuide.md` — directory map, navigation by task
3. `../RaBbLE-Grimoire/RaBbLE-OS/RaBbLE-OS-Roadmap.md` — current phase and blockers
4. `../RaBbLE-Grimoire/RaBbLE-OS/fix/RaBbLE-OS-KnownIssues.md` — active bugs before touching anything
