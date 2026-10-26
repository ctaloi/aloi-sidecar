import QtQuick
import QtQuick.Controls

// A plain button in the theme's colors: filled with the accent when it's
// the main action, quiet otherwise, red-lettered when it can't be undone.
// Material's own rendered without a fill in places, and this stays legible
// in every theme. It never takes focus, so clicking one doesn't pull the
// keyboard out of what you're writing.
Rectangle {
    id: button
    property string text
    property bool primary: false
    property bool danger: false
    // The key that does the same, shown in the button.
    property string keys: ""
    // A small ▾ after the text: it opens a menu.
    property bool menu: false
    // Shown on hover, for a button with only a glyph.
    property string tip: ""
    // Something is underway: the label dims and a dot pulses.
    property bool busy: false
    readonly property alias hovered: mouse.containsMouse
    signal clicked()

    implicitWidth: content.implicitWidth + (text === "" ? 20 : 28)
    implicitHeight: 34
    radius: Math.min(4, theme.radius)
    color: primary ? (mouse.containsMouse ? Qt.lighter(theme.accent, 1.12) : theme.accent)
                   : (mouse.containsMouse ? ui.hover : ui.raised)
    border.color: primary ? "transparent" : danger && mouse.containsMouse ? ui.alpha(ui.danger, 0.6) : ui.line
    opacity: enabled ? 1 : 0.45
    Behavior on color { ColorAnimation { duration: 90 } }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: 9
        Rectangle {
            visible: button.busy
            anchors.verticalCenter: parent.verticalCenter
            width: 7; height: 7; radius: 3.5
            color: button.primary ? theme.accentForeground : theme.accent
            SequentialAnimation on opacity {
                running: button.busy
                loops: Animation.Infinite
                NumberAnimation { to: 0.25; duration: 600; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1; duration: 600; easing.type: Easing.InOutSine }
            }
        }
        Text {
            id: label
            visible: button.text !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: button.text
            color: button.primary ? theme.accentForeground : button.danger ? ui.danger : ui.text
            font.pixelSize: 13
            font.bold: button.primary
        }
        Text {
            visible: button.menu
            anchors.verticalCenter: parent.verticalCenter
            text: button.text === "" ? "⋯" : "▾"
            color: button.primary ? theme.accentForeground : ui.muted
            font.pixelSize: button.text === "" ? 16 : 10
        }
        KeyCap {
            visible: button.keys !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: button.keys
            tone: button.primary ? theme.accentForeground : ui.faint
        }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (button.enabled) button.clicked()
    }
    ToolTip.visible: mouse.containsMouse && button.tip !== ""
    ToolTip.delay: 500
    ToolTip.text: button.tip
}
