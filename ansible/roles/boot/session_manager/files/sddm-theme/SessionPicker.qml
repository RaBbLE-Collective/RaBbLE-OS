// SessionPicker.qml — modal desktop-session menu
//
// Bind from Main.qml: model (sessionModel), currentIndex, palette, fonts.
// Interface:
//   property int  currentIndex   — session SDDM will log in with (bound from root)
//   signal picked(int index)     — user chose a row (mouse click or Enter)
//   signal closed()              — menu dismissed (Esc, scrim click, or after pick)
//   function open()              — show, highlight currentIndex, take keyboard focus
//   function close()
// Keys while open: Up/Down move, Home/End jump, Enter picks, Esc closes.
import QtQuick

Item {
    id: picker
    visible: false
    focus: visible

    // ── Bound from root ───────────────────────────────────────────────────
    property var    model
    property int    currentIndex: 0
    property color  cVoid:    "#0a0010"
    property color  cSurface: "#12132a"
    property color  cRaised:  "#1a1b2e"
    property color  cBorder:  "#2a2840"
    property color  cCyan:    "#00f5ff"
    property color  cViolet:  "#bf5fff"
    property color  cText:    "#e8e6f0"
    property color  cMuted:   "#6b6880"
    property string monoFamily:    "JetBrains Mono"
    property string displayFamily: "JetBrains Mono"

    signal picked(int index)
    signal closed()

    // ── Public interface ──────────────────────────────────────────────────
    function open() {
        list.currentIndex = Math.max(0, picker.currentIndex);
        list.positionViewAtIndex(list.currentIndex, ListView.Contain);
        picker.visible = true;
        picker.forceActiveFocus();
    }
    function close() {
        picker.visible = false;
        picker.closed();
    }

    readonly property int rowH: 52
    readonly property int maxRows: 7   // taller lists scroll

    // ── Scrim: dims the greeter, click outside the panel closes ───────────
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0.039, 0.0, 0.063, 0.72)   // cVoid @ ~72%
        MouseArea { anchors.fill: parent; onClicked: picker.close() }
    }

    // ── Panel ─────────────────────────────────────────────────────────────
    Rectangle {
        id: panel
        anchors.centerIn: parent
        width: Math.min(460, picker.width - 80)
        height: titleText.height + 36 + Math.min(list.count, picker.maxRows) * picker.rowH
                + hint.height + 12
        radius: 14
        color: picker.cSurface
        border.color: picker.cCyan
        border.width: 1

        Text {
            id: titleText
            anchors.top: parent.top
            anchors.topMargin: 16
            anchors.horizontalCenter: parent.horizontalCenter
            text: "SESSION"
            color: picker.cCyan
            font.family: picker.displayFamily
            font.pixelSize: 14
            font.weight: Font.Bold
            font.letterSpacing: 4
        }

        ListView {
            id: list
            anchors.top: titleText.bottom
            anchors.topMargin: 12
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            height: Math.min(count, picker.maxRows) * picker.rowH
            model: picker.model
            clip: true
            interactive: count > picker.maxRows
            boundsBehavior: Flickable.StopAtBounds
            highlightMoveDuration: 80

            delegate: Rectangle {
                id: row
                width: list.width
                height: picker.rowH
                radius: 8
                readonly property bool isCurrent: index === picker.currentIndex
                readonly property bool isFocused: index === list.currentIndex
                color: isFocused ? picker.cRaised : "transparent"
                border.color: isFocused ? picker.cViolet : "transparent"
                border.width: 1

                Text {   // marker for the session login will use
                    id: mark
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.isCurrent ? "◈" : ""
                    color: picker.cCyan
                    font.family: picker.monoFamily
                    font.pixelSize: 14
                }
                Column {
                    anchors.left: mark.right
                    anchors.leftMargin: 10
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text {
                        width: parent.width
                        text: model.name
                        elide: Text.ElideRight
                        color: row.isCurrent ? picker.cCyan : picker.cText
                        font.family: picker.monoFamily
                        font.pixelSize: 15
                        font.letterSpacing: 1
                    }
                    Text {
                        width: parent.width
                        visible: text !== ""
                        text: model.comment ? model.comment : ""
                        elide: Text.ElideRight
                        color: picker.cMuted
                        font.family: picker.monoFamily
                        font.pixelSize: 11
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onPositionChanged: list.currentIndex = index   // real motion only: a list scrolling under a still cursor must not steal the keyboard highlight
                    onClicked: { picker.picked(index); picker.close(); }
                }
            }
        }

        Text {
            id: hint
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 12
            anchors.horizontalCenter: parent.horizontalCenter
            text: "↑↓ choose · ⏎ select · esc close"
            color: picker.cMuted
            font.family: picker.monoFamily
            font.pixelSize: 11
            font.letterSpacing: 1
        }
    }

    // ── Keyboard ──────────────────────────────────────────────────────────
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
            picker.close();
        } else if (event.key === Qt.Key_Down) {
            list.currentIndex = Math.min(list.count - 1, list.currentIndex + 1);
        } else if (event.key === Qt.Key_Up) {
            list.currentIndex = Math.max(0, list.currentIndex - 1);
        } else if (event.key === Qt.Key_Home) {
            list.currentIndex = 0;
        } else if (event.key === Qt.Key_End) {
            list.currentIndex = list.count - 1;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            picker.picked(list.currentIndex);
            picker.close();
        }
        event.accepted = true;   // modal: swallow everything while open
    }
}
