# RaBbLE-OS Known Issues

Issues and workarounds specific to RaBbLE-OS on Fedora 43 + Hyprland.

---

## GParted GUI fails on Hyprland + Fedora 43

**Environment:**
- OS: Fedora 43
- WM: Hyprland (Wayland)
- GParted: 1.7.0
- libparted: 3.6

**Symptoms:**

When launching GParted with `gparted` or `sudo gparted` from a Hyprland terminal:

1. First attempt (`gparted`):
   ```
   localuser:root being added to access control list
   Error executing command as another user: No authentication agent found
   localuser:root being removed from access control list
   ```

2. Second attempt (`sudo gparted`):
   ```
   Authorization required, but no authorization protocol specified
   (gpartedbin:PID): Gtk-WARNING: cannot open display: :0
   ```

3. With environment preservation (`sudo -E gparted`):
   - Window opens briefly
   - Icon theme loading warnings (glycin-svg SVG renderer fails in bubblewrap sandbox)
   - Multiple `Gtk-WARNING`: "Error loading theme icon 'drive-harddisk'" / "image-missing"
   - Cascading `bwrap` sandbox errors (cannot load SVG loaders)
   - **Segmentation fault (core dumped)**

**Root cause:**
- Hyprland doesn't have integrated authorization agents (unlike GNOME/KDE sessions with systemd-user)
- GParted requires polkit elevation + GUI display
- Icon/theme loading in Fedora 43 uses sandboxed SVG loaders (glycin-svg via bubblewrap)
- Sandbox ACLs + Wayland display forwarding = incompatible stack

**What was tried:**
- `sudo gparted` — authorization agent missing
- `sudo -E gparted` — environment preserved but sandbox can't load SVG icons → segfault
- Both with explicit `DISPLAY=:0` and `WAYLAND_DISPLAY=wayland-1` — still fails

**Workaround — Option 1: Use command-line tools**

Safe and direct:
```bash
# Show current state
sudo parted /dev/nvme0n1p6 print
lsblk -f

# Format as BTRFS
sudo mkfs.btrfs -L label-name /dev/nvme0n1p6

# Mount
sudo mkdir -p /mnt/mount-point
sudo mount -L label-name /mnt/mount-point
```

Or use the automated, safeguarded workflow:
```bash
./RaBbLE-OS-vmctl.sh partition-setup /dev/nvme0n1p6
```

**Workaround — Option 2: Boot live ISO**

GParted works out-of-the-box on Fedora live media:
1. Download Fedora Workstation/Everything ISO
2. Flash to USB
3. Reboot into live environment
4. Launch GParted (works immediately)
5. Perform operations
6. Reboot back to RaBbLE-OS

---

## See Also

- `RaBbLE-OS-vmctl.sh partition-setup` — safe partition formatting with triple-check safeguards
- `RaBbLE-OS-PartitionLayout.md` (in Grimoire) — reference partition layout
- Fedora 43 + Hyprland system state: see CONTEXT.md
