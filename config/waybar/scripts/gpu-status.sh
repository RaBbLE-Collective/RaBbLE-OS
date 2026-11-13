#!/usr/bin/env bash
# gpu-status.sh: iGPU/dGPU load for Waybar (JSON). Shows why the system is hot, not just CPU.
# Never touches the dGPU driver (no nvidia-smi): reads runtime PM state only, so it cannot hold it awake.
# Works on any compositor. Vendor-based, so it also reads a lone iGPU or lone dGPU.
set -u
# iGPU glyph = display with a small chip centred on it (Pango: negative letter_spacing pulls the
# chip back over the display; tune spacing/rise/size if the font size changes). Font Awesome only.
# Icon colour = power state (palette): active green, runtime-suspended yellow, powered off (D3cold) grey.
C_ON="#50fa7b" C_SUSP="#f1fa8c" C_OFF="#6b6880"
igpu_icon() { echo "<span foreground='$1'><span letter_spacing='-9000'>\uf26c</span><span size='85%' rise='900'>\uf2db</span></span>"; }
dgpu_icon() { echo "<span foreground='$1' size='185%' rise='-3000'>󰢮</span>"; }
# state colour from runtime_status + power_state of a PCI device dir
state_color() {
    case "$(cat "$1/power/runtime_status" 2>/dev/null)" in
        active) echo "$C_ON" ;;
        suspended) [ "$(cat "$1/power_state" 2>/dev/null)" = D3cold ] && echo "$C_OFF" || echo "$C_SUSP" ;;
        *) echo "$C_OFF" ;;
    esac
}
amd_busy="" amd_col="" amd_clk="" nv_state="" nv_line="" nv_col="" nv_pw=""

for d in /sys/class/drm/card[0-9]/device; do
    [ -r "$d/gpu_busy_percent" ] || continue
    amd_busy=$(cat "$d/gpu_busy_percent"); amd_col=$(state_color "$d")
    amd_clk=$(awk -F'[: ]+' '/\*/ {print $2}' "$d/pp_dpm_sclk" 2>/dev/null)
    break
done

for d in /sys/bus/pci/devices/*; do
    [ "$(cat "$d/vendor" 2>/dev/null)" = 0x10de ] || continue
    case "$(cat "$d/class" 2>/dev/null)" in 0x03*) ;; *) continue ;; esac
    nv_state=$(cat "$d/power/runtime_status" 2>/dev/null); nv_col=$(state_color "$d")
    nv_pw=$(cat "$d/power_state" 2>/dev/null)
    break
done

text=""; tip=""; class=""
if [ -n "$amd_busy" ]; then
    text="$(igpu_icon "$amd_col") <span foreground='$amd_col'>${amd_busy}%</span>"; tip="iGPU: ${amd_busy}% @ ${amd_clk:-?}"
fi
if [ -n "$nv_state" ]; then
    if [ "$nv_state" = active ]; then
        # No nvidia-smi here: opening the driver every poll keeps the dGPU from ever suspending.
        text="${text:+$text  }$(dgpu_icon "$nv_col") <span foreground='$nv_col'>on</span>"; tip="${tip:+$tip\n}dGPU: awake (not queried, a query would keep it awake)"
        class="dgpu-on"
    else
        text="${text:+$text  }$(dgpu_icon "$nv_col") <span foreground='$nv_col'>off</span>"; tip="${tip:+$tip\n}dGPU: ${nv_state}, ${nv_pw:-?} (no draw)"
    fi
fi
[ -n "$text" ] || exit 0
printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' "$text" "$tip" "$class"
