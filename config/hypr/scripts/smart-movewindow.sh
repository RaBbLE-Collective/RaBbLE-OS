#!/usr/bin/env bash
# smart-movewindow.sh — directional window move with split-creation fallback
#
# For l/r: movewindow as normal.
# For u/d, decided from window geometry (native movewindow at an edge re-shapes
# the tree instead of doing nothing, so it is only called when a neighbour exists):
#   - vertical neighbour in that direction -> move (swaps/reinserts as usual)
#   - only side-by-side neighbours         -> togglesplit to stack them, then move
#   - already at the top/bottom edge       -> do nothing
#
# Usage: smart-movewindow.sh [l|r|u|d]

dir="${1:-d}"

# Lua-config dispatch (Hyprland 0.56): legacy `hyprctl dispatch movewindow l`
# is a Lua syntax error now, so use hl.dsp.* forms with full direction names.
case "$dir" in l) dname=left ;; r) dname=right ;; u) dname=up ;; *) dname=down ;; esac

move() { hyprctl dispatch "hl.dsp.window.move({ direction = \"$dname\" })" >/dev/null 2>&1; }

vert_action() {
    hyprctl -j clients 2>/dev/null | jq -r --arg dir "$dir" '
        (.[] | select(.focusHistoryID == 0)) as $f
        | [.[] | select(.workspace.id == $f.workspace.id and (.floating | not) and .mapped
                        and .address != $f.address)] as $o
        | ([$o[] | select(.at[1] < $f.at[1] + $f.size[1] and $f.at[1] < .at[1] + .size[1])] | length) as $side
        | ([$o[] | select(.at[0] < $f.at[0] + $f.size[0] and $f.at[0] < .at[0] + .size[0])]) as $col
        | ([$col[] | select(if $dir == "u" then .at[1] < $f.at[1] else .at[1] > $f.at[1] end)] | length) as $ahead
        | if $ahead > 0 then "move"
          elif ($side > 0 and ($col | length) == 0) then "flip"
          else "edge" end'
}

case "$dir" in
    u|d)
        action=$(vert_action)
        if [[ "$action" == flip ]]; then
            # togglesplit turns A|B into A/B (A on top). The focused window may
            # already be on the requested side, so re-check before moving.
            hyprctl dispatch 'hl.dsp.layout("togglesplit")' >/dev/null
            sleep 0.15
            action=$(vert_action)
        fi
        [[ "$action" == move ]] && move
        ;;
    l|r)
        before=$(hyprctl activewindow -j 2>/dev/null | jq -r '.at | join(",")')
        move
        after=$(hyprctl activewindow -j 2>/dev/null | jq -r '.at | join(",")')
        [[ "$before" != "$after" ]] && exit 0
        # Didn't move: try the opposite side
        if [[ "$dir" == l ]]; then dname=right; else dname=left; fi
        move
        ;;
esac
