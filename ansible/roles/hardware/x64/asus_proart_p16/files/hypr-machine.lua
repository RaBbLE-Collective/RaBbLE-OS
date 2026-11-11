-- ~/.config/hypr/conf_d/machine.lua — ASUS ProArt P16 only
-- Written by ansible/roles/hardware/x64/asus_proart_p16 (tasks/hypr-machine.yml).
-- NOT in config/hypr, so dotctl never deploys it to other machines; env.lua
-- loads it with pcall(require, "conf_d.machine") and is a no-op without it.

-- ── NVIDIA hybrid (AMD primary, NVIDIA drives HDMI) ──────────────────────────
-- AQ_DRM_DEVICES: AMD first (primary renderer), NVIDIA second (HDMI scanout).
-- Colon-delimited, so pinned via the stable vendor-ID udev aliases (deployed by
-- tasks/nvidia.yml Step 1c), NOT raw card numbers — those renumber if Phase 2
-- (simpledrm suppression) lands.
hl.env("AQ_DRM_DEVICES", "/dev/dri/rabble-amdgpu-card:/dev/dri/rabble-nvidia-card")
hl.env("LIBVA_DRIVER_NAME", "nvidia")
hl.env("NVD_BACKEND", "direct")
-- Hardware cursors on NVIDIA Wayland cause artifacts — disable
hl.env("HYPRLAND_NO_HARDWARE_CURSORS", 1)
