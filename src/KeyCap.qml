import QtQuick

// A key, written the way it's pressed, beside what it does.
Rectangle {
    id: cap
    property string text
    property color tone: ui.faint
    implicitWidth: Math.max(18, label.implicitWidth + 10)
    implicitHeight: 18
    radius: Math.min(3, theme.radius)
    color: "transparent"
    border.color: ui.alpha(tone, 0.6)
    Text {
        id: label
        anchors.centerIn: parent
        text: cap.text
        color: cap.tone
        font.pixelSize: 10
    }
}
