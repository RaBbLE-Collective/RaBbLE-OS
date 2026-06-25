// EntityDisplay.qml — RaBbLE animated entity with glow
// Exposed properties:
//   size      : int   — frame px (default 520; glow scales with it)
//   glowColor : color — glow tint (default cCyan "#00f5ff")
// Position, opacity, and fade-in Behavior stay on the instance in Main.qml.
import QtQuick
import QtQuick.Effects

Item {
    id: entityDisplay

    property int   size:      520
    property color glowColor: "#00f5ff"

    width:  size
    height: size

    Image {
        id: entityAnim
        anchors.fill: parent
        fillMode: Image.PreserveAspectFit
        smooth: true
        source: "assets/entity-idle-%1.png".arg(
            ("000" + frameIdx).slice(-3))

        property int frameIdx: 0
        property int frameDir: 1

        Timer {
            interval: 60
            running: true
            repeat: true
            onTriggered: {
                var next = entityAnim.frameIdx + entityAnim.frameDir;
                if (next >= 48) {
                    entityAnim.frameDir = -1;
                    next = 47;
                } else if (next <= 0) {
                    entityAnim.frameDir = 1;
                    next = 0;
                }
                entityAnim.frameIdx = next;
            }
        }
    }

    MultiEffect {
        source: entityAnim
        anchors.fill: entityAnim
        blurEnabled: true
        blur: 0.7
        blurMax: 40
        colorization: 0.2
        colorizationColor: entityDisplay.glowColor
        opacity: 0.65
    }
}
