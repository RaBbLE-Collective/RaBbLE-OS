// config/quickshell/bar/SystemTrayWidget.qml
import Quickshell.Services.SystemTray
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

RowLayout {
    spacing: 4

    Repeater {
        model: SystemTray.items

        delegate: Item {
            required property SystemTrayItem modelData
            width:  20
            height: 20

            Image {
                anchors.centerIn: parent
                source:   modelData.icon
                width:    16
                height:   16
                fillMode: Image.PreserveAspectFit
                smooth:   true

                ToolTip {
                    visible: hov.hovered
                    text:    modelData.tooltip?.title ?? modelData.title ?? ""
                    delay:   400
                }

                HoverHandler { id: hov }

                TapHandler {
                    acceptedButtons: Qt.LeftButton
                    onTapped: modelData.activate()
                }

                TapHandler {
                    acceptedButtons: Qt.RightButton
                    onTapped: (event) => modelData.contextMenu?.open(Qt.point(event.x, event.y))
                }
            }
        }
    }
}
