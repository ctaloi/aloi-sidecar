import QtQuick
import QtQuick.Controls

// The transcript and notes folded away to a strip at the right edge (]).
// Clicking it brings them back; a dot pulses while the call is heard.
Rectangle {
    id: rail
    color: hover.hovered ? ui.hover : ui.panel
    implicitWidth: 40
    property string label: qsTr("Transcript")
    signal open()

    Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: ui.line }

    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 16
        spacing: 14
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "‹"
            color: hover.hovered ? ui.text : ui.muted
            font.pixelSize: 18
        }
        KeyCap { text: "]"; anchors.horizontalCenter: parent.horizontalCenter }
        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: label.implicitHeight
            height: label.implicitWidth
            Label {
                id: label
                anchors.centerIn: parent
                rotation: 90
                text: rail.label
                color: hover.hovered ? ui.text : ui.muted
                font.pixelSize: 12
                font.bold: true
            }
        }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: engine.listening
            width: 8; height: 8; radius: 4
            color: ui.live
            SequentialAnimation on opacity {
                running: engine.listening
                loops: Animation.Infinite
                NumberAnimation { to: 0.3; duration: 600 }
                NumberAnimation { to: 1; duration: 600 }
            }
        }
    }

    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: rail.open() }
    ToolTip.visible: hover.hovered
    ToolTip.delay: 500
    ToolTip.text: qsTr("Show the %1 (])").arg(rail.label.toLowerCase())
}
