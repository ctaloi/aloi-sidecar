import QtQuick

// A plain button in the theme's colors: filled with the accent when it's
// the main action, quiet otherwise. Material's own rendered without a fill
// in places, and this stays legible in every theme.
Rectangle {
    id: button
    property string text
    property bool primary: false
    signal clicked()

    implicitWidth: label.implicitWidth + 28
    implicitHeight: 36
    radius: Math.min(4, theme.radius)
    color: primary ? (mouse.containsMouse ? Qt.lighter(theme.accent, 1.12) : theme.accent)
                   : (mouse.containsMouse ? ui.hover : ui.raised)
    border.color: primary ? "transparent" : ui.line
    opacity: enabled ? 1 : 0.5

    Text {
        id: label
        anchors.centerIn: parent
        text: button.text
        color: button.primary ? theme.accentForeground : ui.text
        font.pixelSize: 13
        font.bold: button.primary
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: button.clicked()
    }
}
