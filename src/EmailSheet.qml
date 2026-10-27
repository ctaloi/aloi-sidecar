import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The follow-up email, in Chris's voice: who it's to, the subject and the
// words, all editable, then saved to his Outlook Drafts (never sent) or
// copied. Ctrl+Enter saves; Esc closes and keeps what he typed.
Rectangle {
    id: root
    color: Qt.rgba(0, 0, 0, 0.55)
    visible: false
    opacity: visible ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 110 } }

    property var meeting: ({})
    readonly property var mail: (engine.selected === meeting.id && engine.wrapup.email) || ({})
    readonly property string state: mail.state || ""

    function open(m) {
        meeting = m
        visible = true
        const e = engine.selected === m.id ? engine.wrapup.email : null
        if (!e || e.state === "failed" || (!e.body && e.state !== "writing")) engine.writeEmail(m.id)
        box.forceActiveFocus()
    }
    function close() { if (pending) flush(); visible = false }
    // Typing is kept as it goes, a moment after the last key.
    property bool pending: false
    function flush() {
        saveTimer.stop()
        pending = false
        engine.editEmail(meeting.id, { to: splitList(toField.text), subject: subjectField.text, body: bodyField.text })
    }
    function splitList(text) { return text.split(/[,;\s]+/).map(s => s.trim()).filter(s => s.indexOf("@") > 0) }
    function save() {
        if (state !== "ready" && state !== "saved") return
        if (pending) flush()
        engine.saveEmail(meeting.id)
    }
    Timer { id: saveTimer; interval: 600; onTriggered: root.flush() }
    function touched() { pending = true; saveTimer.restart() }

    // A new version from the engine fills the fields, unless they're being typed in.
    onMailChanged: {
        if (!toField.activeFocus) toField.text = (mail.to || []).join(", ")
        if (!subjectField.activeFocus) subjectField.text = mail.subject || ""
        if (!bodyField.activeFocus) bodyField.text = mail.body || ""
    }

    MouseArea { anchors.fill: parent; onClicked: root.close() }

    Rectangle {
        id: box
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 680)
        height: Math.min(parent.height - 48, 640)
        radius: theme.radius
        color: ui.raised
        border.color: ui.line
        focus: true
        scale: root.visible ? 1 : 0.97
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Keys.onEscapePressed: root.close()
        Keys.onPressed: event => {
            if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
                root.save(); event.accepted = true
            }
        }
        MouseArea { anchors.fill: parent }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 24
            spacing: 12

            RowLayout {
                Layout.fillWidth: true
                Label {
                    Layout.fillWidth: true
                    text: qsTr("Follow-up email")
                    color: ui.text
                    font.pixelSize: 16
                    font.bold: true
                }
                Label {
                    text: root.state === "writing" ? qsTr("Opus is writing it in your voice…")
                        : root.state === "saving" ? qsTr("Saving to Outlook…")
                        : root.state === "saved" ? qsTr("✓ In your Outlook Drafts")
                        : qsTr("Saved to your Outlook Drafts, never sent")
                    color: root.state === "saved" ? ui.them : ui.muted
                    font.pixelSize: 12
                }
            }

            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: 12
                rowSpacing: 8
                Label { text: qsTr("To"); color: ui.faint; font.pixelSize: 12 }
                Box {
                    Layout.fillWidth: true
                    TextInput {
                        id: toField
                        anchors.fill: parent
                        anchors.margins: 8
                        color: ui.text
                        font.pixelSize: 13
                        clip: true
                        selectByMouse: true
                        onTextEdited: root.touched()
                        Text {
                            visible: toField.text === ""
                            text: qsTr("No invitees on the calendar; add addresses, comma-separated")
                            color: ui.faint
                            font: toField.font
                        }
                    }
                }
                Label { text: qsTr("Subject"); color: ui.faint; font.pixelSize: 12 }
                Box {
                    Layout.fillWidth: true
                    TextInput {
                        id: subjectField
                        anchors.fill: parent
                        anchors.margins: 8
                        color: ui.text
                        font.pixelSize: 13
                        font.bold: true
                        clip: true
                        selectByMouse: true
                        onTextEdited: root.touched()
                    }
                }
            }

            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                background: Rectangle { color: ui.panel; radius: Math.min(4, theme.radius); border.color: bodyField.activeFocus ? ui.alpha(theme.accent, 0.6) : ui.line }
                TextArea {
                    id: bodyField
                    topPadding: 14
                    bottomPadding: 14
                    leftPadding: 14
                    rightPadding: 14
                    topInset: 0
                    bottomInset: 0
                    wrapMode: TextEdit.Wrap
                    color: ui.text
                    font.pixelSize: 13
                    selectByMouse: true
                    selectionColor: ui.alpha(theme.accent, 0.35)
                    background: null
                    placeholderText: root.state === "writing" ? "" : qsTr("The email")
                    onTextChanged: if (activeFocus) root.touched()
                }
            }

            Label {
                Layout.fillWidth: true
                visible: !!root.mail.error
                text: root.mail.error || ""
                color: ui.danger
                font.pixelSize: 12
                wrapMode: Text.Wrap
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Label {
                    Layout.fillWidth: true
                    textFormat: Text.StyledText
                    text: "<font color='" + theme.accent + "'>esc</font> " + qsTr("closes")
                    color: ui.faint
                    font.pixelSize: 11
                }
                ActionButton {
                    text: qsTr("Write again")
                    enabled: root.state !== "writing" && root.state !== "saving"
                    onClicked: engine.writeEmail(root.meeting.id)
                }
                ActionButton {
                    text: qsTr("Copy")
                    enabled: bodyField.text !== ""
                    onClicked: { engine.copyToClipboard(subjectField.text + "\n\n" + bodyField.text); toast.show(qsTr("Email copied")) }
                }
                ActionButton {
                    primary: true
                    busy: root.state === "saving"
                    enabled: (root.state === "ready" || root.state === "saved") && bodyField.text !== ""
                    text: root.state === "saved" ? qsTr("Save again") : qsTr("Save to Outlook Drafts")
                    keys: "ctrl+enter"
                    onClicked: root.save()
                }
            }
        }
    }

    component Box: Rectangle {
        implicitHeight: 34
        radius: Math.min(4, theme.radius)
        color: ui.panel
        border.color: ui.line
    }
}
