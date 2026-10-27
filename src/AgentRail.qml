import QtQuick
import QtQuick.Controls

// The agent folded away to a strip at the right edge (A). Clicking it brings
// the agent back; a dot says it's still answering, or waiting for an Allow.
Rectangle {
    id: rail
    color: hover.hovered ? ui.hover : ui.panel
    implicitWidth: 40
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
        KeyCap { text: "A"; anchors.horizontalCenter: parent.horizontalCenter }
        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: label.implicitHeight
            height: label.implicitWidth
            Label {
                id: label
                anchors.centerIn: parent
                rotation: 90
                text: qsTr("Agent")
                color: hover.hovered ? ui.text : ui.muted
                font.pixelSize: 12
                font.bold: true
            }
        }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: agent.running || agent.approvals.length > 0
            width: 8; height: 8; radius: 4
            color: agent.approvals.length > 0 ? ui.danger : theme.accent
            SequentialAnimation on opacity {
                running: agent.running
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
    ToolTip.text: qsTr("Show the agent")
}
