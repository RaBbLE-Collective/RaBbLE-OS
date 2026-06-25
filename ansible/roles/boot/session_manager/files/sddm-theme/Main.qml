// =============================================================================
// Main.qml — RaBbLE Aether SDDM greeter — Retrowave Edition
//
// Synthwave outrun grid. Qt6 / SDDM 0.21. Components: EntityDisplay, LoginForm.
// Palette: RaBbLE-Grimoire/RaBbLE-Agent/RaBbLE-Palette.md only.
// To reposition elements edit the LAYOUT KNOBS section — not the anchors.
// =============================================================================
import QtQuick
import QtQuick.Effects

Rectangle {
    id: root
    color: "#0a0010"

    // ── Palette ───────────────────────────────────────────────────────────────
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

    // ── Layout knobs ──────────────────────────────────────────────────────────
    // Edit here to move things. Fractions are relative to live screen height.
    // Safe content zone for the Liminal BG: 0.42 – 0.65 (void between grids).
    // See RaBbLE-Grimoire/RaBbLE-OS/desktop/RaBbLE-OS-Desktop-SDDM-Layout.md
    readonly property real  lClockTop:   0.10    // clock: topMargin from topBar as fraction of screen h
    readonly property int   lEntitySize: 520     // entity: frame px (glow scales with it)
    readonly property real  lEntityV:   -0.04    // entity: vertical offset from center (negative = up)
    readonly property real  lFormTop:    0.57    // login form: top edge as fraction of screen h

    // ── Fonts ─────────────────────────────────────────────────────────────────
    FontLoader { id: exo2Loader;     source: "assets/fonts/Exo2-Variable.ttf"     }
    FontLoader { id: orbitronLoader; source: "assets/fonts/Orbitron-Variable.ttf" }

    // ── State ─────────────────────────────────────────────────────────────────
    property bool   authBusy:            false
    property string currentUser:         userModel.lastUser
    property int    currentSessionIndex: sessionModel.lastIndex
    property string notifyMsg:           ""

    function doLogin() {
        if (authBusy || currentUser === "")
            return;
        authBusy = true;
        sddm.login(currentUser, loginForm.password, currentSessionIndex);
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
            loginForm.clearInput();
            loginForm.focusInput();
            loginForm.shakeError();
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

    // ── Top "waybar" strip (Aether-styled status bar) ─────────────────────────
    // NOTE: real Waybar/battery/wifi widgets need a running user session.
    // This strip shows only what the greeter itself knows.
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

        Row {   // right: caps-lock + session
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
        anchors.topMargin: parent.height * root.lClockTop

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

    // ── Entity ────────────────────────────────────────────────────────────────
    // opacity 0 + 500ms fade-in masks the Plymouth→SDDM DRM handoff gap.
    EntityDisplay {
        id: entityArea
        size:      root.lEntitySize
        glowColor: root.cCyan
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: parent.height * root.lEntityV
        opacity: 0
        Behavior on opacity { NumberAnimation { duration: 500 } }
    }

    // ── Login form ────────────────────────────────────────────────────────────
    LoginForm {
        id: loginForm
        width: Math.min(460, root.width - 80)
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: parent.height * root.lFormTop

        currentUser:   root.currentUser
        displayFamily: root.displayFamily
        monoFamily:    root.monoFamily
        cText:         root.cText
        cMuted:        root.cMuted
        cMagenta:      root.cMagenta
        cCyan:         root.cCyan
        cViolet:       root.cViolet
        cRaised:       root.cRaised

        onLoginRequested: root.doLogin()
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

    // ── Session label (above footer) ──────────────────────────────────────────
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
    // Contrast backing pill — power glyphs need lift against the magenta grid.
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
        loginForm.focusInput();
        entityArea.opacity = 1;
    }
}
