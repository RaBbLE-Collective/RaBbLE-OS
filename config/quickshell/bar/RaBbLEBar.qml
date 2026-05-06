// config/quickshell/bar/RaBbLEBar.qml
// =============================================================================
// RaBbLE top bar — workspaces · window title · tray · clock · system
// =============================================================================

import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.SystemTray
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts

PanelWindow {
    id: bar
    required property var screen

    anchors {
        top:   true
        left:  true
        right: true
    }

    height:        36
    color:         "transparent"
    exclusiveZone: height

    // ── Background ────────────────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color:  Qt.rgba(0.05, 0.06, 0.10, 0.88)
        radius: 0

        // Bottom accent line
        Rectangle {
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
            height:  1
            color:   "#7c6fe0"
            opacity: 0.5
        }
    }

    // ── Layout ────────────────────────────────────────────────────────────────
    RowLayout {
        anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
        spacing: 0

        WorkspaceBar  { Layout.alignment: Qt.AlignVCenter }
        BarSeparator  {}
        WindowTitle   { Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter; Layout.leftMargin: 8 }

        SystemTrayWidget { Layout.alignment: Qt.AlignVCenter; Layout.rightMargin: 4 }
        BarSeparator  {}

        NetworkWidget { Layout.alignment: Qt.AlignVCenter }
        BatteryWidget { Layout.alignment: Qt.AlignVCenter }
        BarSeparator  {}

        ClockWidget   { Layout.alignment: Qt.AlignVCenter; Layout.rightMargin: 4 }
    }
}
