// config/quickshell/bar/AudioWidget.qml
import Quickshell.Services.Pipewire
import QtQuick

Item {
    width:  barText.implicitWidth + 20
    height: parent.height

    PwNodeLinkage { id: sink; mode: PwNodeLinkage.Sink }

    Text {
        id: barText
        anchors.centerIn: parent
        color: "#e8e6f0"
        font { family: "JetBrainsMono Nerd Font"; pixelSize: 12 }

        readonly property real vol:   sink.defaultSink?.audio?.volume ?? 0
        readonly property bool muted: sink.defaultSink?.audio?.muted  ?? false

        text: muted ? "󰝟  mute"
                    : (vol > 0.65 ? "󰕾 " : vol > 0.3 ? "󰖀 " : "󰕿 ")
                      + Math.round(vol * 100) + "%"

        TapHandler {
            onTapped: Quickshell.exec(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])
        }

        WheelHandler {
            onWheel: (event) => {
                const delta = event.angleDelta.y > 0 ? "5%+" : "5%-"
                Quickshell.exec(["wpctl", "set-volume", "-l", "1.5", "@DEFAULT_AUDIO_SINK@", delta])
            }
        }
    }
}
