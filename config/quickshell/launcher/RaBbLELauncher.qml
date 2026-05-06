// config/quickshell/launcher/RaBbLELauncher.qml
// =============================================================================
// App launcher overlay — fuzzy search over .desktop entries
// Toggle via: quickshell ipc call launcher toggle
// =============================================================================

import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

FloatingWindow {
    id: launcher
    visible: false
    width:   620
    height:  460

    function toggle() {
        if (visible) {
            close()
        } else {
            searchField.text = ""
            appModel.refresh()
            show()
            searchField.forceActiveFocus()
        }
    }

    function close() {
        visible = false
        searchField.text = ""
    }

    Keys.onEscapePressed: launcher.close()

    // ── Background ────────────────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color:        "#0d0f1a"
        opacity:      0.96
        radius:       14
        border.color: "#7c6fe0"
        border.width: 1
    }

    ColumnLayout {
        anchors { fill: parent; margins: 16 }
        spacing: 10

        // ── Search field ──────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            height:  42
            radius:  8
            color:   "#1a1b2e"
            border.color: searchField.activeFocus ? "#7c6fe0" : "#2a2840"
            border.width: 1

            RowLayout {
                anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                spacing: 8

                Text {
                    text:  ""
                    color: "#6b6880"
                    font { family: "JetBrainsMono Nerd Font"; pixelSize: 16 }
                }

                TextInput {
                    id: searchField
                    Layout.fillWidth: true
                    color: "#e8e6f0"
                    font  { family: "JetBrainsMono Nerd Font"; pixelSize: 14 }
                    selectByMouse: true
                    clip:  true

                    onTextChanged:       appModel.filter(text)
                    Keys.onReturnPressed: if (appList.currentItem) appList.currentItem.launch()
                    Keys.onUpPressed:    appList.decrementCurrentIndex()
                    Keys.onDownPressed:  appList.incrementCurrentIndex()
                }
            }
        }

        // ── App list ──────────────────────────────────────────────────────────
        ListView {
            id: appList
            Layout.fillWidth:  true
            Layout.fillHeight: true
            clip:         true
            model:        appModel.filtered
            spacing:      2
            currentIndex: 0

            delegate: Item {
                id: appItem
                required property var modelData
                width:  ListView.view.width
                height: 48

                function launch() {
                    Quickshell.exec(modelData.exec.replace(/%[fFuUdDnNickvm]/g, ""))
                    launcher.close()
                }

                Rectangle {
                    anchors.fill: parent
                    radius: 6
                    color:  appItem.ListView.isCurrentItem ? "#1e1b3a"
                          : hov.hovered                   ? "#161428"
                          : "transparent"

                    RowLayout {
                        anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                        spacing: 12

                        Image {
                            source:   modelData.icon || ""
                            width:    28; height: 28
                            fillMode: Image.PreserveAspectFit
                            smooth:   true
                            visible:  source !== ""
                        }

                        Rectangle {
                            width: 28; height: 28; radius: 6
                            color:   "#7c6fe033"
                            visible: modelData.icon === ""

                            Text {
                                anchors.centerIn: parent
                                text:  modelData.name?.charAt(0) ?? "?"
                                color: "#7c6fe0"
                                font { pixelSize: 14; weight: Font.Medium }
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1

                            Text {
                                text:  modelData.name ?? ""
                                color: "#e8e6f0"
                                font  { family: "JetBrainsMono Nerd Font"; pixelSize: 13; weight: Font.Medium }
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }

                            Text {
                                text:    modelData.comment ?? modelData.categories ?? ""
                                color:   "#6b6880"
                                font    { family: "JetBrainsMono Nerd Font"; pixelSize: 11 }
                                elide:   Text.ElideRight
                                visible: text !== ""
                                Layout.fillWidth: true
                            }
                        }
                    }
                }

                HoverHandler { id: hov; onHoveredChanged: if (hovered) appList.currentIndex = index }
                TapHandler   { onTapped: appItem.launch() }
            }
        }

        // ── Footer ────────────────────────────────────────────────────────────
        Text {
            text:  "↑↓ navigate  ·  ↵ launch  ·  Esc close"
            color: "#2a2840"
            font  { family: "JetBrainsMono Nerd Font"; pixelSize: 10 }
            Layout.alignment: Qt.AlignHCenter
        }
    }

    // ── App model ─────────────────────────────────────────────────────────────
    QtObject {
        id: appModel
        property var    filtered: []
        property string query:    ""

        function refresh() { filter(query) }

        function filter(q) {
            query = q
            const term = q.toLowerCase()
            const all  = Quickshell.applications
            if (!term) { filtered = all.slice(0, 50); return }
            filtered = all.filter(a => {
                const name    = (a.name    || "").toLowerCase()
                const comment = (a.comment || "").toLowerCase()
                const exec    = (a.exec    || "").toLowerCase()
                return name.includes(term) || comment.includes(term) || exec.includes(term)
            }).slice(0, 50)
        }

        Component.onCompleted: filter("")
    }
}
