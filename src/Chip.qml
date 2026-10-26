import QtQuick

// A small labeled mark: a meeting's state, its length, where it's from.
// Tinted with its color, so a row reads at a glance.
Rectangle {
    id: chip
    property string text
    property color tone: ui.muted
    property string glyph: ""
    property bool filled: false
    implicitWidth: row.implicitWidth + 14
    implicitHeight: 22
    radius: Math.min(4, theme.radius)
    color: filled ? ui.alpha(tone, 0.16) : "transparent"
    border.color: ui.alpha(tone, filled ? 0.55 : 0.4)

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 5
        Text {
            visible: chip.glyph !== ""
            text: chip.glyph
            color: chip.tone
            font.pixelSize: 11
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: chip.text
            color: chip.tone
            font.pixelSize: 11
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
