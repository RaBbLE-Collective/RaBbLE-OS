-- ~/.config/hypr/conf_d/machine.lua — ASUS ProArt P16 only
-- Written by ansible/roles/hardware/x64/asus_proart_p16 (tasks/hypr-machine.yml).
-- NOT in config/hypr, so dotctl never deploys it to other machines; env.lua
-- loads it with pcall(require, "conf_d.machine") and is a no-op without it.

-- ── NVIDIA hybrid ───────────────────────────────────────────────────────────
-- The GPU pin (AQ_DRM_DEVICES) moved to rabble-shell/bin/rabble-gpu, called from env.lua, so it
-- is the same OS-level decision niri uses. Only the NVIDIA env stays here.
hl.env("LIBVA_DRIVER_NAME", "nvidia")
hl.env("NVD_BACKEND", "direct")
-- Hardware cursors on NVIDIA Wayland cause artifacts — disable
hl.env("HYPRLAND_NO_HARDWARE_CURSORS", 1)
