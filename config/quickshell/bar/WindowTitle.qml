// config/quickshell/bar/WindowTitle.qml
import Quickshell.Hyprland
import QtQuick

Text {
    readonly property string title: HyprlandIpc.focusedClient?.title ?? ""
    readonly property string cls:   HyprlandIpc.focusedClient?.class ?? ""

    text:  title.length > 60 ? title.slice(0, 57) + "…" : (title || cls || "")
    color: "#9d9ab8"
    font  { family: "JetBrainsMono Nerd Font"; pixelSize: 12 }
    elide: Text.ElideRight
}
