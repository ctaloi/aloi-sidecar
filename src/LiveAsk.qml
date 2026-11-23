import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Popup {
    id: popup
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(640, parent.width - 32)
    height: Math.min(460, parent.height - 32)
    padding: 0
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    property string meetingId: ""
    readonly property bool sameCall: engine.listening && meetingId === engine.current && meetingId === engine.selected
    onSameCallChanged: if (visible && !sameCall) close()
    onOpened: chat.input.forceActiveFocus()

    function openForCall(id, question) {
        if (meetingId !== id) chat.input.clear()
        meetingId = id
        if (question !== undefined) {
            chat.input.text = question
            chat.input.cursorPosition = question.length
        }
        open()
    }

    Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.22) }
    background: Rectangle {
        radius: Math.max(8, theme.radius)
        color: ui.alpha(ui.raised, 0.95)
        border.color: ui.line
    }

    contentItem: ColumnLayout {
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 16
            spacing: 12
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4
                Label {
                    text: qsTr("Ask about this call")
                    color: ui.text
                    font.pixelSize: 16
                    font.bold: true
                }
                Label {
                    Layout.fillWidth: true
                    text: engine.selectedMeeting.title || qsTr("Live call")
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: ui.muted
                    font.pixelSize: 12
                }
            }
            KeyButton {
                glyph: "close"
                text: qsTr("Close")
                compact: true
                keys: "esc"
                onClicked: popup.close()
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: ui.line }
        AgentPane {
            id: chat
            quickAsk: true
            Layout.fillWidth: true
            Layout.fillHeight: true
            onDismissRequested: popup.close()
        }
    }
}
