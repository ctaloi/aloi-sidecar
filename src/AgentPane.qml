import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// Ask about the call. Each question carries what was said since the last
// one; the agent can look things up with Chris's skills, and anything
// beyond a lookup waits here for his Allow.
Rectangle {
    id: pane
    color: ui.panel

    property alias input: field
    readonly property var chips: [
        qsTr("What did I miss in the last 5 minutes?"),
        qsTr("Summarize so far"),
        qsTr("What action items have come up?"),
        qsTr("Has anyone asked me something I haven't answered?")
    ]
    function ask(text) {
        if (text.trim() === "") return
        agent.ask(text)
        field.text = ""
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            topMargin: 16
            bottomMargin: 16
            spacing: 18
            model: agent.messages
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            onCountChanged: Qt.callLater(positionViewAtEnd)
            onContentHeightChanged: if (!moving) Qt.callLater(positionViewAtEnd)

            // ListView pins delegates to x: 0, so the margin goes inside a full-width item.
            delegate: Item {
                required property var modelData
                required property int index
                width: list.width
                height: message.implicitHeight

            Column {
                id: message
                readonly property bool mine: modelData.role === "you"
                x: 18
                width: parent.width - 36
                spacing: 6

                Text {
                    visible: message.mine
                    width: parent.width
                    text: modelData.text
                    color: theme.accent
                    font.pixelSize: 14
                    font.bold: true
                    wrapMode: Text.Wrap
                }
                Repeater {
                    model: message.mine ? [] : (modelData.steps || [])
                    delegate: Text {
                        required property string modelData
                        width: parent.width
                        text: "· " + modelData
                        color: ui.faint
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                }
                TextEdit {
                    visible: !message.mine && text !== ""
                    width: parent.width
                    text: message.mine ? "" : modelData.text
                    textFormat: TextEdit.MarkdownText
                    color: ui.text
                    font.pixelSize: 14
                    wrapMode: TextEdit.Wrap
                    readOnly: true
                    selectByMouse: true
                    selectionColor: ui.alpha(theme.accent, 0.35)
                    selectedTextColor: ui.text
                    onLinkActivated: link => Qt.openUrlExternally(link)
                }
                Text {
                    visible: !message.mine && modelData.streaming === true && modelData.text === ""
                    text: agent.activity || qsTr("Thinking…")
                    color: ui.muted
                    font.pixelSize: 12
                    font.italic: true
                }
            }
            }
        }

        Column {
            Layout.fillWidth: true
            Layout.margins: 18
            Layout.topMargin: 0
            spacing: 8
            visible: agent.messages.length === 0
            Text {
                width: parent.width
                text: qsTr("Ask about the call")
                color: ui.text
                font.pixelSize: 16
                font.bold: true
            }
            Text {
                width: parent.width
                wrapMode: Text.Wrap
                color: ui.muted
                font.pixelSize: 12
                text: qsTr("Claude reads the transcript and can look things up with your skills: a customer's numbers, your mail and calendar, Notion. Anything beyond a lookup asks you first.")
            }
        }

        // What the agent wants to run, with the exact command.
        Repeater {
            model: agent.approvals
            delegate: Rectangle {
                required property var modelData
                required property int index
                Layout.fillWidth: true
                Layout.leftMargin: 12
                Layout.rightMargin: 12
                Layout.bottomMargin: 8
                implicitHeight: card.implicitHeight + 24
                radius: theme.radius
                color: ui.wash(theme.accent, 0.12)
                border.color: ui.alpha(theme.accent, 0.6)
                ColumnLayout {
                    id: card
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 8
                    Text {
                        Layout.fillWidth: true
                        text: modelData.description ? qsTr("The agent wants to run this (%1):").arg(modelData.description)
                                                    : qsTr("The agent wants to run this:")
                        color: ui.text
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: cmd.implicitHeight + 16
                        radius: Math.min(4, theme.radius)
                        color: ui.window
                        TextEdit {
                            id: cmd
                            anchors.fill: parent
                            anchors.margins: 8
                            text: modelData.command
                            color: ui.text
                            font.pixelSize: 12
                            wrapMode: TextEdit.WrapAnywhere
                            readOnly: true
                            selectByMouse: true
                        }
                    }
                    Flow {
                        Layout.fillWidth: true
                        spacing: 8
                        ActionButton {
                            text: index === 0 ? qsTr("Allow (Y)") : qsTr("Allow")
                            primary: true
                            onClicked: agent.decide(modelData.id, "once")
                        }
                        ActionButton {
                            visible: modelData.skill !== ""
                            text: qsTr("Always for %1").arg(modelData.skill)
                            onClicked: agent.decide(modelData.id, "skill")
                        }
                        ActionButton {
                            text: index === 0 ? qsTr("Deny (N)") : qsTr("Deny")
                            onClicked: agent.decide(modelData.id, "deny")
                        }
                    }
                }
            }
        }

        Text {
            Layout.fillWidth: true
            Layout.leftMargin: 18
            Layout.rightMargin: 18
            visible: agent.error !== ""
            text: agent.error
            color: ui.danger
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }

        Flow {
            id: chipRow
            Layout.fillWidth: true
            Layout.leftMargin: 14
            Layout.rightMargin: 14
            Layout.topMargin: 6
            spacing: 6
            visible: !agent.running
            Repeater {
                model: pane.chips
                delegate: Rectangle {
                    required property string modelData
                    required property int index
                    implicitWidth: Math.min(chipText.implicitWidth + 20, chipRow.width)
                    implicitHeight: chipText.implicitHeight + 10
                    radius: Math.min(theme.radius, implicitHeight / 2)
                    color: chipMouse.containsMouse ? ui.hover : ui.raised
                    border.color: ui.line
                    Text {
                        id: chipText
                        anchors.centerIn: parent
                        width: Math.min(implicitWidth, chipRow.width - 20)
                        elide: Text.ElideRight
                        text: (index + 1) + "  " + modelData
                        color: chipMouse.containsMouse ? ui.text : ui.muted
                        font.pixelSize: 11
                    }
                    MouseArea {
                        id: chipMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: pane.ask(modelData)
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 14
            spacing: 8
            TextField {
                id: field
                Layout.fillWidth: true
                placeholderText: agent.running ? qsTr("Answering… Esc stops") : qsTr("Ask about the call  ( / )")
                Material.roundedScale: theme.radius
                font.pixelSize: 14
                onAccepted: pane.ask(text)
                Keys.onEscapePressed: {
                    if (agent.running) agent.stop()
                    else focus = false
                }
            }
            ActionButton {
                text: agent.running ? qsTr("Stop") : qsTr("Ask")
                primary: !agent.running
                implicitHeight: field.height - 8
                onClicked: agent.running ? agent.stop() : pane.ask(field.text)
            }
        }
    }
}
