import QtQuick
import Aloi
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
    // In the middle of a wide window the conversation keeps to a readable
    // column instead of running edge to edge.
    readonly property real gutter: Math.max(0, (width - 860) / 2)
    readonly property bool over: engine.selectedMeeting.state === "ended"
    // During a call: catching up. Afterwards: what to take away from it.
    readonly property var chips: over ? [
        qsTr("Summarize this meeting"),
        qsTr("What did I commit to?"),
        qsTr("What did the others commit to?"),
        qsTr("What's still open or undecided?")
    ] : [
        qsTr("What did I miss in the last 5 minutes?"),
        qsTr("Summarize so far"),
        qsTr("What action items have come up?"),
        qsTr("Has anyone asked me something I haven't answered?")
    ]
    readonly property bool ready: engine.selected !== "" && !engine.loading
    function ask(text) {
        if (text.trim() === "" || !ready) return
        agent.ask(text)
        field.text = ""
        list.stick = true
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: pane.gutter
        anchors.rightMargin: pane.gutter
        spacing: 0

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            topMargin: 16
            bottomMargin: 16
            spacing: 18
            model: agent.messageModel
            visible: count > 0
            // Every answer laid out, not estimated, so the scroll range
            // doesn't shift as rows come into view.
            cacheBuffer: 100000
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            // Follows the answer as it streams in only while you're at the
            // bottom; scroll up to read and it stays put until you come back.
            property bool stick: true
            property bool following: false
            function follow() { following = true; positionViewAtEnd(); following = false }
            onCountChanged: if (stick) Qt.callLater(follow)
            onContentHeightChanged: if (stick) Qt.callLater(follow)
            onContentYChanged: if (!following && height > 0) stick = atYEnd || contentHeight <= height
            onHeightChanged: if (height > 0 && stick) Qt.callLater(follow)
            Kinetic { target: list }

            // ListView pins delegates to x: 0, so the margin goes inside a full-width item.
            delegate: Item {
                required property var entry
                readonly property var modelData: entry
                required property int index
                width: list.width
                height: message.implicitHeight
                HoverHandler { id: answerHover }

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
                // Hovering a finished answer offers to copy it.
                Text {
                    visible: !message.mine && modelData.streaming !== true && modelData.text !== ""
                    opacity: answerHover.hovered ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 120 } }
                    text: qsTr("Copy")
                    color: copyHover.hovered ? theme.accent : ui.faint
                    font.pixelSize: 11
                    HoverHandler { id: copyHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: { engine.copyToClipboard(modelData.text); toast.show(qsTr("Copied the answer.")) } }
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

        // Before the first question: what it can do, at the top where the
        // answers will be.
        Item {
            Layout.fillWidth: true
            implicitHeight: intro.implicitHeight + 36
            // Only while there's nothing better to show.
            visible: agent.messages.length === 0 && !(engine.brief.related || []).length && !engine.takeaways.updated
            Column {
                id: intro
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 18
                spacing: 6
                Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    color: ui.muted
                    font.pixelSize: 12
                    lineHeight: 1.15
                    text: qsTr("Reads this meeting's transcript and looks things up with your skills: a customer's numbers, your mail and calendar, Notion. Anything beyond a lookup asks you first.")
                }
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
                        KeyButton {
                            text: index === 0 ? qsTr("Allow (Y)") : qsTr("Allow")
                            primary: true
                            onClicked: agent.decide(modelData.id, "once")
                        }
                        KeyButton {
                            visible: modelData.skill !== ""
                            text: qsTr("Always for %1").arg(modelData.skill)
                            onClicked: agent.decide(modelData.id, "skill")
                        }
                        KeyButton {
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

        BriefCard {
            Layout.fillWidth: true
            Layout.leftMargin: 14
            Layout.rightMargin: 14
            Layout.topMargin: 6
            // Going in, before the first question; the answers take over after.
            visible: related.length > 0 && agent.messages.length === 0
            onAsk: prompt => pane.ask(prompt)
        }
        TakeawaysCard {
            Layout.fillWidth: true
            Layout.leftMargin: 14
            Layout.rightMargin: 14
            Layout.topMargin: 6
        }
        LookupCards {
            Layout.fillWidth: true
            Layout.leftMargin: 14
            Layout.rightMargin: 14
            Layout.topMargin: 8
            onLook: prompt => pane.ask(prompt)
        }
        // Before the first question the takeaways sit under the intro; after
        // it, the answers take the room above them.
        Item { Layout.fillHeight: true; visible: agent.messages.length === 0 }

        Flow {
            id: chipRow
            Layout.fillWidth: true
            Layout.leftMargin: 14
            Layout.rightMargin: 14
            Layout.topMargin: 6
            spacing: 6
            // Before the first question, or while in the box; 1–4 work anyway.
            visible: !agent.running && (agent.messages.length === 0 || field.activeFocus)
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
            Layout.leftMargin: 14
            Layout.rightMargin: 14
            Layout.topMargin: 10
            Layout.bottomMargin: 14
            spacing: 8
            TextField {
                id: field
                Layout.fillWidth: true
                enabled: pane.ready
                placeholderText: agent.running ? qsTr("Answering…") : agent.wide ? qsTr("Ask across all your meetings")
                               : pane.over ? qsTr("Ask about this meeting") : qsTr("Ask about the call")
                Material.roundedScale: theme.radius
                font.pixelSize: 14
                onAccepted: pane.ask(text)
                placeholderTextColor: agent.wide ? theme.accent : ui.faint
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_A && (event.modifiers & Qt.ControlModifier) && text === "") {
                        agent.wide = !agent.wide; event.accepted = true
                    }
                }
                Keys.onEscapePressed: {
                    if (agent.running) agent.stop()
                    else focus = false
                }
            }
            KeyButton {
                text: agent.running ? qsTr("Stop") : qsTr("Ask")
                glyph: agent.running ? "stop" : "send"
                primary: !agent.running
                implicitHeight: field.height - 8
                onClicked: agent.running ? agent.stop() : pane.ask(field.text)
            }
        }
        // What the keys do here, as under every Aloi agent's box.
        Label {
            Layout.leftMargin: 18
            Layout.bottomMargin: 10
            Layout.topMargin: -6
            textFormat: Text.StyledText
            text: "<font color='" + theme.accent + "'>enter</font> asks    <font color='" + theme.accent + "'>ctrl+a</font> "
                  + (agent.wide ? qsTr("back to this meeting") : qsTr("asks every meeting"))
                  + "    <font color='" + theme.accent + "'>esc</font> " + (agent.running ? qsTr("stops it") : qsTr("leaves"))
            color: ui.faint
            font.pixelSize: 11
        }
    }
}
