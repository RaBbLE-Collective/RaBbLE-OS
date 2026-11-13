#!/usr/bin/env bash
# gpu-status.sh: iGPU/dGPU load for Waybar (JSON). Shows why the system is hot, not just CPU.
# Never wakes a suspended dGPU: nvidia-smi is only called when runtime PM says it is active.
# Works on any compositor. Vendor-based, so it also reads a lone iGPU or lone dGPU.
set -u
amd_busy="" amd_clk="" nv_state="" nv_line=""

for d in /sys/class/drm/card[0-9]/device; do
    [ -r "$d/gpu_busy_percent" ] || continue
    amd_busy=$(cat "$d/gpu_busy_percent")
    amd_clk=$(awk -F'[: ]+' '/\*/ {print $2}' "$d/pp_dpm_sclk" 2>/dev/null)
    break
done

for d in /sys/bus/pci/devices/*; do
    [ "$(cat "$d/vendor" 2>/dev/null)" = 0x10de ] || continue
    case "$(cat "$d/class" 2>/dev/null)" in 0x03*) ;; *) continue ;; esac
    nv_state=$(cat "$d/power/runtime_status" 2>/dev/null)
    break
done

text=""; tip=""; class=""
if [ -n "$amd_busy" ]; then
    text="󰾲 ${amd_busy}%"; tip="iGPU: ${amd_busy}% @ ${amd_clk:-?}"
fi
if [ -n "$nv_state" ]; then
    if [ "$nv_state" = active ] && command -v nvidia-smi >/dev/null; then
        IFS=, read -r nv_util nv_w nv_t nv_p <<<"$(nvidia-smi --query-gpu=utilization.gpu,power.draw,temperature.gpu,pstate --format=csv,noheader,nounits 2>/dev/null)"
        text="${text:+$text  }󰢮 ${nv_util// /}% ${nv_w%%.*}W"
        tip="${tip:+$tip\n}dGPU: ${nv_util// /}%, ${nv_w// /} W, ${nv_t// /}C, ${nv_p// /} (awake)"
        class="dgpu-on"
    else
        text="${text:+$text  }󰢮 off"; tip="${tip:+$tip\n}dGPU: ${nv_state} (no draw)"
    fi
fi
[ -n "$text" ] || exit 0
printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' "$text" "$tip" "$class"
