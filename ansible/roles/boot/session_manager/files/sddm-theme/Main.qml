// =============================================================================
// Main.qml — RaBbLE Aether SDDM greeter — Retrowave Edition
//
// Synthwave outrun grid. Pure QML — no image assets. Qt6 / SDDM 0.21.
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
    readonly property color cPink:    "#ff79c6"
    readonly property color cText:    "#e8e6f0"
    readonly property color cMuted:   "#6b6880"

    readonly property string monoFamily:    "JetBrains Mono"
    readonly property string displayFamily: orbitronLoader.status === 1
                                            ? orbitronLoader.name : "JetBrains Mono"

    FontLoader { id: exo2Loader;    source: "assets/fonts/Exo2-Variable.ttf"    }
    FontLoader { id: orbitronLoader; source: "assets/fonts/Orbitron-Variable.ttf" }
    property bool authBusy: false
    property string currentUser: userModel.lastUser
    property int currentSessionIndex: sessionModel.lastIndex
    property string notifyMsg: ""

    function doLogin() {
        if (authBusy || currentUser === "")
            return;
        authBusy = true;
        sddm.login(currentUser, passInput.text, currentSessionIndex);
    }

    function cycleUser() {
        if (userModel.count < 2) {
            root.notifyMsg = "no other users";
            notifyAnim.restart();
            return;
        }
        for (var i = 0; i < userModel.count; i++) {
            if (userModel.get(i, "name") === currentUser) {
                currentUser = userModel.get((i + 1) % userModel.count, "name");
                return;
            }
        }
        currentUser = userModel.get(0, "name");
    }

    function cycleSession() {
        if (sessionModel.count < 2) {
            root.notifyMsg = "no other sessions";
            notifyAnim.restart();
            return;
        }
        currentSessionIndex = (currentSessionIndex + 1) % sessionModel.count;
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

    // ── Background ────────────────────────────────────────────────────────────
    Image {
        anchors.fill: parent
        source: "assets/bg.png"
        fillMode: Image.PreserveAspectCrop
        smooth: true
    }

    // ── Top "waybar" strip (Aether-styled status bar) ───────────────────────────
    // NOTE: the SDDM greeter cannot host the real Waybar or live battery/network
    // widgets — those need a running user session. This is the Aether-styled strip
    // from the mockup, showing what the greeter actually knows: a RaBbLE workspace
    // pill (left) and session + caps-lock state (right). Live battery/wifi widgets
    // are a follow-up that needs a small backend feeding the greeter.
    Rectangle {
        id: topBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 34
        color: Qt.rgba(0.07, 0.075, 0.16, 0.55)   // cSurface @ ~55%

        Rectangle {   // Aether hairline along the bottom edge
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: root.cBorder
        }

        Rectangle {   // left: RaBbLE workspace pill
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            width: rabbleTag.width + 20
            height: 22
            radius: 11
            color: Qt.rgba(1.0, 0.176, 0.443, 0.16)   // magenta tint
            border.color: root.cMagenta
            border.width: 1
            Text {
                id: rabbleTag
                anchors.centerIn: parent
                text: "◈ RaBbLE"
                color: root.cMagenta
                font.family: root.monoFamily
                font.pixelSize: 12
                font.letterSpacing: 1
            }
        }

        Row {   // right: caps-lock + session (real greeter state)
            anchors.right: parent.right
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 18
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: keyboard.capsLock ? "⇪ CAPS" : ""
                color: root.cMagenta
                font.family: root.monoFamily
                font.pixelSize: 11
                font.letterSpacing: 2
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: sessionModel.count > 0
                      ? sessionModel.get(root.currentSessionIndex, "name") : ""
                color: root.cCyan
                font.family: root.monoFamily
                font.pixelSize: 11
                font.letterSpacing: 2
            }
        }
    }

    // ── Clock ─────────────────────────────────────────────────────────────────
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: clockText.refresh()
    }

    Text {
        id: clockText
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: topBar.bottom
        anchors.topMargin: parent.height * 0.10

        function refresh() {
            var d = new Date();
            var h = d.getHours();
            var m = d.getMinutes();
            var sfx = h >= 12 ? " pm" : " am";
            h = h % 12 || 12;
            text = h + ":" + (m < 10 ? "0" + m : m) + sfx;
        }
        Component.onCompleted: refresh()

        color: root.cText
        font.family: root.displayFamily
        font.pixelSize: Math.min(root.width * 0.095, 104)
        font.weight: Font.Black
        font.letterSpacing: 6
        opacity: 0.95
    }

    // ── Entity — independent, centered slightly below mid ─────────────────────
    // opacity 0 + 500ms fade-in masks the Plymouth→SDDM DRM handoff gap.
    Item {
        id: entityArea
        width: 520
        height: 520
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: 0
        opacity: 0
        Behavior on opacity { NumberAnimation { duration: 500 } }

        Image {
            id: entityAnim
            anchors.centerIn: parent
            width: 520
            height: 520
            fillMode: Image.PreserveAspectFit
            smooth: true
            source: "assets/entity-idle-%1.png".arg(
                ("000" + entityAnim.frameIdx).slice(-3))

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
            colorizationColor: "#00f5ff"
            opacity: 0.65
        }
    }

    // ── Form column: username + passphrase — sits at the vanishing line ────────
    Column {
        id: centerCol
        width: Math.min(460, root.width - 80)
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: parent.height * 0.57
        spacing: 10

        // Username — Orbitron, color-cycles through Aether neons
        // Transforms known lowercase username to canonical RaBbLE case
        Text {
            id: usernameText
            anchors.horizontalCenter: parent.horizontalCenter
            text: {
                var u = root.currentUser;
                if (u === "") return "guest";
                if (u.toLowerCase() === "rabble") return "RaBbLE";
                return u.charAt(0).toUpperCase() + u.slice(1).toLowerCase();
            }
            font.family: root.displayFamily
            font.pixelSize: 54
            font.weight: Font.Black
            font.letterSpacing: 3
            color: root.cCyan
            SequentialAnimation on color {
                loops: Animation.Infinite
                ColorAnimation { to: root.cMagenta; duration: 900; easing.type: Easing.InOutSine }
                ColorAnimation { to: root.cViolet;  duration: 900; easing.type: Easing.InOutSine }
                ColorAnimation { to: root.cCyan;    duration: 900; easing.type: Easing.InOutSine }
            }
        }

        Item { width: 1; height: 6 }

        // ── Passphrase field ──
        Rectangle {
            id: passField
            width: parent.width
            height: 48
            radius: 24
            color: root.cRaised

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
                color: root.cText
                font.family: root.monoFamily
                font.pixelSize: 20
                clip: true
                echoMode: TextInput.Password
                passwordCharacter: "•"
                Keys.onReturnPressed: root.doLogin()
                Keys.onEnterPressed: root.doLogin()
            }
            Text {
                anchors.centerIn: parent
                text: "••••"
                color: root.cMuted
                font.family: root.monoFamily
                font.pixelSize: 20
                visible: passInput.text === "" && !passInput.activeFocus
            }
        }

        // ── Reaction line ──
        Text {
            id: errorLine
            anchors.horizontalCenter: parent.horizontalCenter
            height: 16
            text: "authentication failed"
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

    // ── Notify toast (no other user / no other session) ───────────────────────
    Text {
        id: notifyLine
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: sessionLabel.top
        anchors.bottomMargin: 6
        text: root.notifyMsg
        color: root.cViolet
        font.family: root.monoFamily
        font.pixelSize: 13
        font.letterSpacing: 1
        opacity: 0

        SequentialAnimation {
            id: notifyAnim
            NumberAnimation { target: notifyLine; property: "opacity"; to: 1; duration: 200 }
            PauseAnimation { duration: 2000 }
            NumberAnimation { target: notifyLine; property: "opacity"; to: 0; duration: 400 }
        }
    }

    // ── Session label (above footer) ─────────────────────────────────────────
    Text {
        id: sessionLabel
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: footerRow.top
        anchors.bottomMargin: 8
        text: sessionModel.count > 0 ? sessionModel.get(root.currentSessionIndex, "name") : ""
        color: root.cMuted
        font.family: root.monoFamily
        font.pixelSize: 11
        font.letterSpacing: 2
        opacity: 0.6
    }

    // ── Footer ────────────────────────────────────────────────────────────────
    // Contrast backing pill — the power glyphs were low-contrast against the
    // magenta floor grid; this translucent surface + Aether border lifts them.
    Rectangle {
        anchors.horizontalCenter: footerRow.horizontalCenter
        anchors.verticalCenter: footerRow.verticalCenter
        width: footerRow.width + 48
        height: footerRow.height + 22
        radius: height / 2
        color: Qt.rgba(0.039, 0.0, 0.063, 0.62)   // cVoid @ ~62%
        border.color: root.cBorder
        border.width: 1
    }

    Row {
        id: footerRow
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 28
        spacing: 40

        Text {
            text: "⏻"
            visible: sddm.canPowerOff
            font.pixelSize: 26
            color: powerMouse.containsMouse ? root.cCyan : root.cText
            MouseArea {
                id: powerMouse
                anchors.fill: parent
                anchors.margins: -10
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: sddm.powerOff()
            }
        }

        Text {
            text: "↺"
            visible: sddm.canReboot
            font.pixelSize: 26
            color: rebootMouse.containsMouse ? root.cCyan : root.cText
            MouseArea {
                id: rebootMouse
                anchors.fill: parent
                anchors.margins: -10
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: sddm.reboot()
            }
        }

        Text {
            text: "⏾"
            visible: sddm.canSuspend
            font.pixelSize: 26
            color: suspendMouse.containsMouse ? root.cCyan : root.cText
            MouseArea {
                id: suspendMouse
                anchors.fill: parent
                anchors.margins: -10
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: sddm.suspend()
            }
        }

        // Change user — cycles userModel, updates username display
        Text {
            text: "⇌"
            font.pixelSize: 26
            color: userCycleMouse.containsMouse ? root.cCyan : root.cText
            MouseArea {
                id: userCycleMouse
                anchors.fill: parent
                anchors.margins: -10
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.cycleUser()
            }
        }

        // Swap DE — cycles sessionModel, updates session label
        Text {
            text: "⊞"
            font.pixelSize: 26
            color: sessionCycleMouse.containsMouse ? root.cCyan : root.cText
            MouseArea {
                id: sessionCycleMouse
                anchors.fill: parent
                anchors.margins: -10
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.cycleSession()
            }
        }
    }

    Component.onCompleted: {
        passInput.forceActiveFocus();
        entityArea.opacity = 1;
    }
}
