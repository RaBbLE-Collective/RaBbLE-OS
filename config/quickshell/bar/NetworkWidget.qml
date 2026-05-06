// config/quickshell/bar/NetworkWidget.qml
import Quickshell.Io
import QtQuick

Item {
    width:  netText.implicitWidth + 20
    height: parent.height

    Process {
        id: nmcli
        command: ["nmcli", "-t", "-f", "DEVICE,STATE,CONNECTION", "device"]
        running: true
        onExited: netText.update(stdout)
    }

    Timer { interval: 10000; running: true; repeat: true; onTriggered: nmcli.start() }

    Text {
        id: netText
        anchors.centerIn: parent
        color: "#e8e6f0"
        font { family: "JetBrainsMono Nerd Font"; pixelSize: 12 }
        text: "󰤭 --"

        function update(raw) {
            const lines = raw.trim().split("\n")
            for (const line of lines) {
                const [dev, state, conn] = line.split(":")
                if (dev && dev.startsWith("wl") && state === "connected") {
                    netText.text = "󰤨 " + (conn || dev); return
                }
                if (dev && dev.startsWith("en") && state === "connected") {
                    netText.text = "󰈀 " + (conn || dev); return
                }
            }
            netText.text = "󰤭 offline"
        }
    }
}
