import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Asks before something that can't be taken back, the way Tix does: Enter
// confirms, Esc or a click outside goes back, and the keys are written
// under the buttons. One overlay serves every question: ask() fills it in.
Rectangle {
    id: root
    color: Qt.rgba(0, 0, 0, 0.55)
    visible: false
    opacity: visible ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 110 } }

    property string title
    property string detail
    property string confirmText: qsTr("OK")
    property bool danger: false
    property var onYes: null

    function ask(options) {
        title = options.title
        detail = options.detail || ""
        confirmText = options.confirm || qsTr("OK")
        danger = !!options.danger
        onYes = options.run
        visible = true
        box.forceActiveFocus()
    }
    function accept() { visible = false; if (onYes) onYes(); onYes = null }
    function reject() { visible = false; onYes = null }

    MouseArea { anchors.fill: parent; onClicked: root.reject() }

    Rectangle {
        id: box
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 480)
        height: content.implicitHeight + 48
        radius: theme.radius
        color: ui.raised
        border.color: root.danger ? ui.alpha(ui.danger, 0.6) : ui.line
        focus: true
        scale: root.visible ? 1 : 0.97
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Keys.onEscapePressed: root.reject()
        Keys.onReturnPressed: root.accept()
        Keys.onEnterPressed: root.accept()

        MouseArea { anchors.fill: parent }

        ColumnLayout {
            id: content
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 24
            spacing: 12
            Label {
                Layout.fillWidth: true
                text: root.title
                color: ui.text
                font.pixelSize: 16
                font.bold: true
                wrapMode: Text.Wrap
            }
            Label {
                Layout.fillWidth: true
                visible: root.detail !== ""
                text: root.detail
                color: ui.muted
                font.pixelSize: 12
                lineHeight: 1.25
                wrapMode: Text.Wrap
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 8
                spacing: 8
                Label {
                    Layout.fillWidth: true
                    textFormat: Text.StyledText
                    text: "<font color='" + theme.accent + "'>enter</font> " + qsTr("confirms")
                          + "    <font color='" + theme.accent + "'>esc</font> " + qsTr("goes back")
                    color: ui.faint
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                }
                ActionButton { text: qsTr("Cancel"); onClicked: root.reject() }
                ActionButton {
                    primary: !root.danger
                    danger: root.danger
                    text: root.confirmText
                    keys: "enter"
                    onClicked: root.accept()
                }
            }
        }
    }
}
