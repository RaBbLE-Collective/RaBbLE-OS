# AGENT.md — RaBbLE-OS

RaBbLE-OS is the entity's body — Ansible-driven Fedora 43 + Hyprland desktop.
Grimoire is truth. Ansible applies it. `layerctl` manages it day-to-day.

## Key Tools

| Tool | What |
|------|------|
| `RaBbLE-OS-layerctl.sh` | Apply/verify/status layers |
| `RaBbLE-OS-dotctl.sh` | Deploy dotfile symlinks from `config/` |
| `RaBbLE-OS-vmctl.sh` | VM lifecycle for testing |
| `RaBbLE-OS-Bootstrap.sh` | Ansible runner |

## Rule

> Never edit `~/.config/` directly. Edit `config/` → deploy via `dotctl`.

## Docs

All docs: `../RaBbLE-Grimoire/RaBbLE-OS/`

Start: `RaBbLE-OS-AgentGuide.md` (directory map + navigation table)
Current work: `RaBbLE-OS-Roadmap.md`
