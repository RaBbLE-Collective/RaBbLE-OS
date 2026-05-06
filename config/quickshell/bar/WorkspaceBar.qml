// config/quickshell/bar/WorkspaceBar.qml
// =============================================================================
// Hyprland workspace dots — active, occupied, empty states
// =============================================================================

import Quickshell
import Quickshell.Hyprland
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

RowLayout {
    id: root
    spacing: 4

    // ── Palette ───────────────────────────────────────────────────────────────
    readonly property color clrActive:   "#7c6fe0"
    readonly property color clrOccupied: "#4ecdc4"
    readonly property color clrEmpty:    "#2a2840"
    readonly property color clrUrgent:   "#e05c6f"

    Repeater {
        model: HyprlandIpc.workspaces

        delegate: Item {
            required property var modelData
            width:  16
            height: 16

            Rectangle {
                id: dot
                anchors.centerIn: parent

                readonly property bool isActive:   modelData.id === HyprlandIpc.focusedWorkspace?.id
                readonly property bool isUrgent:   modelData.hasuurgent ?? false
                readonly property bool isOccupied: (modelData.windows ?? 0) > 0

                width:  isActive ? 14 : (isOccupied ? 8 : 6)
                height: width
                radius: width / 2

                color: isUrgent   ? root.clrUrgent   :
                       isActive   ? root.clrActive    :
                       isOccupied ? root.clrOccupied  :
                                    root.clrEmpty

                Behavior on width  { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                Behavior on height { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                Behavior on color  { ColorAnimation  { duration: 150 } }
            }

            ToolTip {
                visible: hoverHandler.hovered
                text:    modelData.name ?? String(modelData.id)
                delay:   400
            }

            HoverHandler { id: hoverHandler }
            TapHandler   { onTapped: HyprlandIpc.dispatch("workspace " + modelData.id) }
        }
    }
}
