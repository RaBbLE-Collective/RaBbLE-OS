// LoginForm.qml — username display, passphrase input, error reaction
//
// Bind from Main.qml: currentUser, displayFamily, monoFamily, cText/cMuted/
//   cMagenta/cCyan/cViolet/cRaised. Set width + anchors on the instance.
//
// Interface:
//   readonly property string password  — current passInput text (for doLogin)
//   signal loginRequested()            — fired on Return/Enter
//   function focusInput()              — direct keyboard focus to pass field
//   function clearInput()              — wipe the pass field (on auth failure)
//   function shakeError()              — flash "authentication failed" line
import QtQuick
import QtQuick.Effects

Column {
    id: loginForm
    spacing: 10

    // ── Palette (bound from root) ─────────────────────────────────────────
    property color  cText:    "#e8e6f0"
    property color  cMuted:   "#6b6880"
    property color  cMagenta: "#ff2d78"
    property color  cCyan:    "#00f5ff"
    property color  cViolet:  "#bf5fff"
    property color  cRaised:  "#1a1b2e"
    property string displayFamily: "JetBrains Mono"
    property string monoFamily:    "JetBrains Mono"

    // ── State (bound from root) ───────────────────────────────────────────
    property string currentUser: ""

    // ── Public interface ──────────────────────────────────────────────────
    readonly property string password: passInput.text
    signal loginRequested()

    function focusInput() { passInput.forceActiveFocus() }
    function clearInput()  { passInput.text = "" }
    function shakeError()  { errorAnim.restart() }

    // ── Username ──────────────────────────────────────────────────────────
    Text {
        id: usernameText
        anchors.horizontalCenter: parent.horizontalCenter
        text: {
            var u = loginForm.currentUser;
            if (u === "") return "guest";
            if (u.toLowerCase() === "rabble") return "RaBbLE";
            return u.charAt(0).toUpperCase() + u.slice(1).toLowerCase();
        }
        font.family: loginForm.displayFamily
        font.pixelSize: 54
        font.weight: Font.Black
        font.letterSpacing: 3
        color: loginForm.cCyan
        SequentialAnimation on color {
            loops: Animation.Infinite
            ColorAnimation { to: loginForm.cMagenta; duration: 900; easing.type: Easing.InOutSine }
            ColorAnimation { to: loginForm.cViolet;  duration: 900; easing.type: Easing.InOutSine }
            ColorAnimation { to: loginForm.cCyan;    duration: 900; easing.type: Easing.InOutSine }
        }
    }

    Item { width: 1; height: 6 }

    // ── Passphrase field ──────────────────────────────────────────────────
    Rectangle {
        id: passField
        width: parent.width
        height: 48
        radius: 24
        color: loginForm.cRaised

        // Aether flowing gradient border — magenta → cyan → violet cycle
        Rectangle {
            anchors.centerIn: parent
            width: parent.width + 3
            height: parent.height + 3
            radius: parent.radius + 2
            z: -1
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop {
                    position: 0.0
                    color: "#ff2d78"
                    SequentialAnimation on color {
                        loops: Animation.Infinite
                        ColorAnimation { to: "#00f5ff"; duration: 1800; easing.type: Easing.InOutSine }
                        ColorAnimation { to: "#bf5fff"; duration: 1800; easing.type: Easing.InOutSine }
                        ColorAnimation { to: "#ff2d78"; duration: 1800; easing.type: Easing.InOutSine }
                    }
                }
                GradientStop {
                    position: 1.0
                    color: "#00f5ff"
                    SequentialAnimation on color {
                        loops: Animation.Infinite
                        ColorAnimation { to: "#bf5fff"; duration: 1800; easing.type: Easing.InOutSine }
                        ColorAnimation { to: "#ff2d78"; duration: 1800; easing.type: Easing.InOutSine }
                        ColorAnimation { to: "#00f5ff"; duration: 1800; easing.type: Easing.InOutSine }
                    }
                }
            }
        }

        MultiEffect {
            source: passField
            anchors.fill: passField
            blurEnabled: true
            blur: 0.8
            blurMax: 16
            colorization: 1.0
            colorizationColor: "#00f5ff"
            opacity: passInput.text.length > 0 ? 0.3 : 0
            z: -1
            Behavior on opacity { NumberAnimation { duration: 200 } }
        }

        TextInput {
            id: passInput
            anchors.fill: parent
            anchors.leftMargin: 20
            anchors.rightMargin: 20
            verticalAlignment: TextInput.AlignVCenter
            horizontalAlignment: TextInput.AlignHCenter
            color: loginForm.cText
            font.family: loginForm.monoFamily
            font.pixelSize: 20
            clip: true
            echoMode: TextInput.Password
            passwordCharacter: "•"
            Keys.onReturnPressed: loginForm.loginRequested()
            Keys.onEnterPressed:  loginForm.loginRequested()
        }
        Text {
            anchors.centerIn: parent
            text: "••••"
            color: loginForm.cMuted
            font.family: loginForm.monoFamily
            font.pixelSize: 20
            visible: passInput.text === "" && !passInput.activeFocus
        }
    }

    // ── Error reaction ────────────────────────────────────────────────────
    Text {
        id: errorLine
        anchors.horizontalCenter: parent.horizontalCenter
        height: 16
        text: "authentication failed"
        color: loginForm.cMagenta
        font.family: loginForm.monoFamily
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
