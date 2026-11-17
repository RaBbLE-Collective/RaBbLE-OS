# RaBbLE-OS

A Fedora 44 setup that turns a fresh install into the RaBbLE desktop: a Hyprland tiling desktop (niri and GNOME are also configured), the RaBbLE theme, boot screen and login screen, and the tools for the rest of the Collective. It is built with Ansible, so every package and config file comes from this repo.

**Genesis release `0.1.0`** · **Developer Preview.** It targets generic x86_64 PCs and is the author's daily driver, but it is not hardened. Read [Known Rough Edges](https://github.com/RaBbLE-Collective/RaBbLE-Grimoire/blob/main/RaBbLE-OS/RaBbLE-OS-KnownRoughEdges.md) before you install, including how to recover from a broken boot.

![RaBbLE](assets/RaBbLE.svg)

## Quickstart

Use a spare machine or a VM. Either route needs a network connection.

**From a stock Fedora 44 Sway spin** (already installed):

```sh
curl -fsSL https://raw.githubusercontent.com/RaBbLE-Collective/RaBbLE-OS/main/RaBbLE-OS-Install.sh | bash
```

It clones this repo to `~/RaBbLE-OS` and runs the Ansible bootstrap.

**From a Fedora netinstall ISO** (bare metal or VM): `RaBbLE-OS.ks` is a Kickstart template. Bake it into the ISO with `spells/build-iso.sh <Fedora-Everything-netinst ISO>` and boot the result. For a VM, `./RaBbLE-OS-vmctl.sh cast-ks <ISO>` does it unattended. The header of `RaBbLE-OS.ks` explains the options.

## Day to day

| Command | What it does |
|---|---|
| `./RaBbLE-OS-layerctl.sh status` | Show which layers (base, desktop, apps, hardware, ...) are applied |
| `./RaBbLE-OS-layerctl.sh apply <layer>` | Install and configure a layer |
| `./RaBbLE-OS-layerctl.sh upgrade` | Update packages and firmware, then re-apply everything |
| `./RaBbLE-OS-dotctl.sh apply all` | Copy the configs in `config/` to `~/.config/` |
| `./RaBbLE-OS-dotctl.sh status` | Show which deployed configs have drifted from the repo |
| `./RaBbLE-OS-vmctl.sh` | Create and manage test VMs |

Change a setting by editing the file under `config/` and running `dotctl apply`, not by editing `~/.config/` directly. Add a package in `ansible/packages/manifest.yml`.

## Layout

| Path | What |
|---|---|
| `ansible/` | Roles, package manifest and the playbook (`site.yml`) |
| `config/` | Dotfiles and themes: Hyprland, niri, kitty, fuzzel, Qt and GTK, and others |
| `display-manager/` | `rdisplay`, a monitor layout tool |
| `RaBbLE-OS.ks` | The Kickstart template for ISO and VM installs |
| `spells/` | Helper scripts |

## Documentation

Docs live in the Grimoire, not here: [Agent Guide](https://github.com/RaBbLE-Collective/RaBbLE-Grimoire/blob/main/RaBbLE-OS/RaBbLE-OS-AgentGuide.md) (directory map) · [Roadmap](https://github.com/RaBbLE-Collective/RaBbLE-Grimoire/blob/main/RaBbLE-OS/RaBbLE-OS-Roadmap.md) · [Known Rough Edges](https://github.com/RaBbLE-Collective/RaBbLE-Grimoire/blob/main/RaBbLE-OS/RaBbLE-OS-KnownRoughEdges.md)

## Licence

Source-available under the RaBbLE Sovereign Accord: free for personal use, commercial use by agreement. See [LICENSE](LICENSE).
