// =============================================================================
// Main.qml — RaBbLE Aether SDDM greeter
//
// Void and neon. Pure QML — no wallpaper, no image assets. Qt6 / SDDM 0.21.
// Glows via QtQuick.Effects MultiEffect (ships with qt6-qtdeclarative).
// Palette: RaBbLE-Grimoire/RaBbLE-Agent/RaBbLE-Palette.md only.
// =============================================================================
import QtQuick
import QtQuick.Effects

Rectangle {
    id: root
    color: "#0a0010"

    readonly property color cVoid:    "#0a0010"
    readonly property color cSurface: "#12132a"
    readonly property color cRaised:  "#1a1b2e"
    readonly property color cBorder:  "#2a2840"
    readonly property color cMagenta: "#ff2d78"
    readonly property color cCyan:    "#00f5ff"
    readonly property color cViolet:  "#bf5fff"
    readonly property color cText:    "#e8e6f0"
    readonly property color cMuted:   "#6b6880"

    readonly property string monoFamily: "JetBrains Mono"
    property bool authBusy: false

    function doLogin() {
        if (authBusy || userInput.text === "")
            return;
        authBusy = true;
        sddm.login(userInput.text, passInput.text, sessionModel.lastIndex);
    }

    Connections {
        target: sddm
        function onLoginFailed() {
            root.authBusy = false;
            passInput.text = "";
            passInput.forceActiveFocus();
            errorAnim.restart();
        }
        function onLoginSucceeded() { }
    }

    // ── Background: radial breath from surface to void ──────────────────────
    Canvas {
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            var r = Math.max(width, height) * 0.6;
            var grad = ctx.createRadialGradient(width / 2, height / 2, 0,
                                                width / 2, height / 2, r);
            grad.addColorStop(0.0, root.cSurface);
            grad.addColorStop(1.0, root.cVoid);
            ctx.fillStyle = grad;
            ctx.fillRect(0, 0, width, height);
        }
    }

    // ── Scanlines: 2px dark bands, ~6% opacity ───────────────────────────────
    Canvas {
        anchors.fill: parent
        opacity: 0.06
        onPaint: {
            var ctx = getContext("2d");
            ctx.fillStyle = "#000000";
            for (var y = 0; y < height; y += 4)
                ctx.fillRect(0, y, width, 2);
        }
    }

    // ── Center column ────────────────────────────────────────────────────────
    Column {
        id: centerCol
        width: Math.min(420, root.width - 80)
        anchors.centerIn: parent
        spacing: 14

        // sigil with pulsing magenta glow
        Item {
            width: parent.width
            height: 64

            Text {
                id: sigil
                anchors.centerIn: parent
                text: "◈"
                color: root.cViolet
                font.pixelSize: 48
            }
            MultiEffect {
                id: sigilGlow
                source: sigil
                anchors.fill: sigil
                blurEnabled: true
                blur: 1.0
                blurMax: 24
                colorization: 1.0
                colorizationColor: root.cMagenta
                opacity: 0.4
                SequentialAnimation on opacity {
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.9; duration: 1000; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 0.4; duration: 1000; easing.type: Easing.InOutSine }
                }
            }
        }

        // wordmark — neon cycle magenta -> cyan -> violet
        Text {
            id: wordmark
            anchors.horizontalCenter: parent.horizontalCenter
            text: "RaBbLE"
            color: root.cMagenta
            font.family: root.monoFamily
            font.bold: true
            font.pixelSize: 48
            SequentialAnimation on color {
                loops: Animation.Infinite
                ColorAnimation { to: root.cCyan;    duration: 2000 }
                ColorAnimation { to: root.cViolet;  duration: 2000 }
                ColorAnimation { to: root.cMagenta; duration: 2000 }
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "behavioral learning engine"
            color: root.cViolet
            opacity: 0.78
            font.family: root.monoFamily
            font.pixelSize: 11
            font.letterSpacing: 3
        }

        Item { width: 1; height: 10 }   // breathing room

        // ── username ──
        Rectangle {
            id: userField
            width: parent.width
            height: 48
            radius: 10
            color: root.cRaised
            border.width: 1
            border.color: userInput.activeFocus ? "#66bf5fff" : root.cBorder

            TextInput {
                id: userInput
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                verticalAlignment: TextInput.AlignVCenter
                color: root.cText
                font.family: root.monoFamily
                font.pixelSize: 16
                clip: true
                text: userModel.lastUser
                KeyNavigation.tab: passInput
                Keys.onReturnPressed: passInput.forceActiveFocus()
                Keys.onEnterPressed: passInput.forceActiveFocus()
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: 16
                text: "user"
                color: root.cMuted
                font.family: root.monoFamily
                font.pixelSize: 16
                visible: userInput.text === "" && !userInput.activeFocus
            }
        }

        // ── passphrase ──
        Rectangle {
            id: passField
            width: parent.width
            height: 48
            radius: 10
            color: root.cRaised
            border.width: 1
            border.color: passInput.text.length > 0 ? "#3300f5ff"
                        : passInput.activeFocus     ? "#66bf5fff"
                                                    : root.cBorder

            MultiEffect {
                source: passField
                anchors.fill: passField
                blurEnabled: true
                blur: 0.6
                blurMax: 16
                colorization: 1.0
                colorizationColor: root.cCyan
                opacity: passInput.text.length > 0 ? 0.35 : 0
                z: -1
                Behavior on opacity { NumberAnimation { duration: 200 } }
            }
            TextInput {
                id: passInput
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                verticalAlignment: TextInput.AlignVCenter
                color: root.cText
                font.family: root.monoFamily
                font.pixelSize: 16
                clip: true
                echoMode: TextInput.Password
                passwordCharacter: "•"
                KeyNavigation.tab: userInput
                Keys.onReturnPressed: root.doLogin()
                Keys.onEnterPressed: root.doLogin()
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: 16
                text: "••••••••••••"
                color: root.cMuted
                font.family: root.monoFamily
                font.pixelSize: 16
                visible: passInput.text === "" && !passInput.activeFocus
            }
        }

        // ── authenticate ──
        Item {
            width: parent.width
            height: 48

            Rectangle {
                id: loginBtn
                anchors.fill: parent
                radius: 10
                opacity: root.authBusy ? 0.55 : 1.0
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: root.cMagenta }
                    GradientStop { position: 1.0; color: root.cViolet }
                }
                Text {
                    anchors.centerIn: parent
                    text: root.authBusy ? "AUTHENTICATING…" : "AUTHENTICATE"
                    color: root.cText
                    font.family: root.monoFamily
                    font.bold: true
                    font.pixelSize: 14
                    font.letterSpacing: 1.1
                }
                MouseArea {
                    id: loginMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.doLogin()
                }
            }
            MultiEffect {
                source: loginBtn
                anchors.fill: loginBtn
                blurEnabled: true
                blur: 1.0
                blurMax: loginMouse.containsMouse ? 32 : 20
                colorization: 1.0
                colorizationColor: root.cMagenta
                opacity: loginMouse.containsMouse ? 0.65 : 0.35
                z: -1
                Behavior on opacity { NumberAnimation { duration: 150 } }
            }
        }

        // ── reaction line ──
        Text {
            id: errorLine
            anchors.horizontalCenter: parent.horizontalCenter
            height: 18
            text: "◈ authentication failed"
            color: root.cMagenta
            font.family: root.monoFamily
            font.pixelSize: 12
            opacity: 0

            SequentialAnimation {
                id: errorAnim
                NumberAnimation { target: errorLine; property: "opacity"; to: 1; duration: 200 }
                PauseAnimation { duration: 3000 }
                NumberAnimation { target: errorLine; property: "opacity"; to: 0; duration: 600 }
            }
        }
    }

    // ── Footer: power / reboot ───────────────────────────────────────────────
    Row {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 20
        spacing: 56

        Text {
            text: "⏻"
            visible: sddm.canPowerOff
            font.pixelSize: 24
            color: powerMouse.containsMouse ? root.cCyan : root.cMuted
            MouseArea {
                id: powerMouse
                anchors.fill: parent
                anchors.margins: -8
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: sddm.powerOff()
            }
        }
        Text {
            text: "↺"
            visible: sddm.canReboot
            font.pixelSize: 24
            color: rebootMouse.containsMouse ? root.cCyan : root.cMuted
            MouseArea {
                id: rebootMouse
                anchors.fill: parent
                anchors.margins: -8
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: sddm.reboot()
            }
        }
    }

    Component.onCompleted: {
        if (userInput.text === "")
            userInput.forceActiveFocus();
        else
            passInput.forceActiveFocus();
    }
}
