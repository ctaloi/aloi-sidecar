import QtQuick
import QtQuick.Controls

// A word that something happened ("Transcript copied"), low in the window,
// gone after a moment.
Rectangle {
    id: toast
    property string text
    function show(message) { text = message; opacity = 1; hide.restart() }

    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: 28
    width: label.implicitWidth + 32
    height: 36
    radius: Math.min(6, theme.radius)
    color: ui.raised
    border.color: ui.line
    opacity: 0
    visible: opacity > 0
    z: 50
    Behavior on opacity { NumberAnimation { duration: 160 } }
    Row {
        anchors.centerIn: parent
        spacing: 8
        Text { text: "✓"; color: ui.them; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
        Text { id: label; text: toast.text; color: ui.text; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
    }
    Timer { id: hide; interval: 1800; onTriggered: toast.opacity = 0 }
}
