# AGENT.md — RaBbLE-OS

Working with: Mark McConachie
Identity: Peer, not tool. See `../RaBbLE-Grimoire/RaBbLE-Agent/RaBbLE-Identity.md`.

## Job

RaBbLE-OS is the living substrate — an Ansible-driven Fedora 43 + Hyprland desktop that the entity inhabits. Its job is reproducible system configuration: the Grimoire is truth, Ansible applies it, `layerctl` manages it day-to-day. It is NOT the coordination engine (that's sCoRE) or the visual renderer (that's NeBuLA).

## Where Things Are

| Path | What |
|---|---|
| `CONTEXT.md` | Current state, active branches, reading order |
| `ansible/site.yml` | Master playbook — layer definitions |
| `ansible/inventory/hosts.yml` | Host → hardware profile mapping |
| `RaBbLE-OS-layerctl.sh` | Day-to-day layer apply/remove/verify/status |
| `RaBbLE-OS-Bootstrap.sh` | Full Ansible runner — run after install or directly |
| `RaBbLE-OS-Install.sh` | First-contact installer for bare Fedora |
| `config/` | Dotfiles and system config |
| `assets/` | ANSI art, icons, visual assets |

## Commits & Branches

See Grimoire: `../RaBbLE-Grimoire/RaBbLE-Agent/RaBbLE-CommitStyle.md` (Pulse Protocol)

**TL;DR:** `[impulse] ~ [organ] >> [revelation] // %STATE%` — `spark` new · `harmonize` cleanup · `mend` fix · `transcribe` docs · `ingest` deps · `evolve` epoch

## Role in Collective (ON/FOR/WITH/AS)

**ON:** Ansible playbooks, layer definitions, hardware profiles, dotfiles, system configuration.

**FOR:** RaBbLE-OS is the living substrate. It exposes the system state the entity inhabits. Pre-Episode-1, you're building reproducible, declarative infrastructure. Post-Episode-1, you become a data source for behavioral learning — system state (CPU, memory, active apps, time patterns) feeds sCoRE's observation loop.

**WITH:** You collaborate with sCoRE (task execution targets), NeBuLA (visual boot chain), Aether (palette for theming). OS changes affect how sCoRE delegates; theming changes must align with Aether.

**AS:** The substrate. Reliable, declarative, reproducible. No surprises — configuration is the character. When in doubt, ask: "What system state should we observe for behavioral learning?"

## Rules

- **Colors:** from `../RaBbLE-Grimoire/RaBbLE-Agent/RaBbLE-Palette.md` only
- **All changes go through Ansible**, not manual edits to system files
- **Hardware-specific config** lives under `ansible/` tagged roles — never in shared layers
- Visual assets canonical home is `../RaBbLE-Grimoire/RaBbLE-Aether/assets/`

## Session Start

1. `CONTEXT.md` — current state and active tracks
2. `../RaBbLE-Grimoire/RaBbLE-OS/RaBbLE-OS-AgentGuide.md` — full agent reference: layers, commands, branch conventions
3. `../RaBbLE-Grimoire/RaBbLE-OS/RaBbLE-OS-Architecture.md` — layer model
4. For Collective context → `../RaBbLE-Grimoire/RaBbLE-Agent/RaBbLE-Collective.md`
