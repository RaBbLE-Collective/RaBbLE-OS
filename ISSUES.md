# ISSUES.md — RaBbLE-OS Live Tracker

Quick-capture for bugs, gripes, and wishlist items encountered during daily use.
Items graduate to the Roadmap once scoped.

## How to add an entry

```bash
# From terminal — append with today's date
echo "- [ ] $(date +%Y-%m-%d) | BUG | description here" >> ~/RaBbLE-Collective/RaBbLE-OS/ISSUES.md
echo "- [ ] $(date +%Y-%m-%d) | GRIPE | description here" >> ~/RaBbLE-Collective/RaBbLE-OS/ISSUES.md
echo "- [ ] $(date +%Y-%m-%d) | WISH | description here" >> ~/RaBbLE-Collective/RaBbLE-OS/ISSUES.md
```

**Types:**
- `BUG` — reproducible problem, something is broken
- `GRIPE` — works but shouldn't be this way, friction point
- `WISH` — nice-to-have, idea, future improvement

---

## Bugs

- [ ] 2026-04-?? | BUG | Screen signs out while watching video — hypridle not suppressing idle on media playback. Hyprlock behavior also unclear. Needs `inhibit_idle fullscreen` or media player idle inhibitor.

---

## Gripes

- [ ] 2026-11-11 | GRIPE | Hyprland feels unfinished and too rolling-release: config and behaviour change between versions. The flowing gradient window border stopped working (`config/hypr/conf_d/look.lua` has a static two-colour gradient; `animations.lua` has no border animation). Compositor decision deferred (Mark, S323); candidates Sway, niri, GNOME. See Grimoire `log/DECISIONS.md` S323.

---

## Wishlist

*(nothing logged yet)*

---

## Resolved

- [x] 2026-05-23 | BUG | vmctl --raw-disk could pass RaBbLE-VM partition to VM installer, destroying BTRFS label. fstab lacked `nofail`, causing emergency mode on boot. Fixed: raw-disk guard + nofail enforced + Ansible safety net.

---

## Promoted to Roadmap

Items that have been scoped and moved to the active episode roadmap.

| Date promoted | Item | Landed in |
|---|---|---|
| — | — | — |
