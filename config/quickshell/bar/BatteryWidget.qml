// config/quickshell/bar/BatteryWidget.qml
import Quickshell.Services.UPower
import QtQuick

Item {
    width:  visible ? batText.implicitWidth + 20 : 0
    height: parent.height
    visible: UPower.displayDevice?.isPresent ?? false

    Text {
        id: batText
        anchors.centerIn: parent
        font { family: "JetBrainsMono Nerd Font"; pixelSize: 12 }

        readonly property real  pct:      UPower.displayDevice?.percentage ?? 100
        readonly property bool  charging: UPower.displayDevice?.state === UPowerDeviceState.Charging

        color: pct <= 15 ? "#e05c6f" : pct <= 30 ? "#f7a8d4" : "#e8e6f0"

        text: {
            const icon = charging ? "󰂄" :
                         pct > 90 ? "󰁹" : pct > 70 ? "󰂀" : pct > 50 ? "󰁿" :
                         pct > 30 ? "󰁾" : pct > 15 ? "󰁼" : "󰁺"
            return icon + " " + Math.round(pct) + "%"
        }
    }
}
