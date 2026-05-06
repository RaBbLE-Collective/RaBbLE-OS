// config/quickshell/bar/ClockWidget.qml
import Quickshell
import QtQuick
import QtQuick.Layouts

RowLayout {
    spacing: 6

    SystemClock { id: sysClock; precision: SystemClock.Seconds }

    Text {
        text:  Qt.formatTime(sysClock.now, "HH:mm")
        color: "#e8e6f0"
        font { family: "JetBrainsMono Nerd Font"; pixelSize: 13; weight: Font.Medium }
    }

    Text {
        text:  Qt.formatDate(sysClock.now, "ddd dd MMM")
        color: "#6b6880"
        font { family: "JetBrainsMono Nerd Font"; pixelSize: 11 }
    }
}
