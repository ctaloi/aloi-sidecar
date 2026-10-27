import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "sidecar.js" as Sidecar

// Going in: what's on file from earlier meetings in the same series or with
// the same people. Their gist, what Chris still owes, what the others said
// they'd do. It's all already in Sidecar, so it costs nothing; the button
// asks the agent for more (mail, Teams) only when he wants it.
Rectangle {
    id: card
    readonly property var b: engine.brief
    readonly property var related: b.related || []
    readonly property var mine: b.mine || []
    readonly property var theirs: b.theirs || []
    signal ask(string prompt)
    visible: related.length > 0
    implicitHeight: column.implicitHeight + 22
    radius: Math.min(6, theme.radius)
    color: ui.window
    border.color: ui.line

    ColumnLayout {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 11
        anchors.leftMargin: 14
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            Label {
                text: qsTr("GOING IN")
                color: ui.muted
                font.pixelSize: 10
                font.letterSpacing: 1.4
                font.bold: true
            }
            Label {
                Layout.fillWidth: true
                text: card.related[0] && card.related[0].series ? qsTr("from earlier in this series") : qsTr("from earlier meetings with them")
                color: ui.faint
                font.pixelSize: 10
            }
            Label {
                text: qsTr("Brief me with mail and Teams")
                color: briefHover.hovered ? theme.accent : ui.muted
                font.pixelSize: 11
                visible: !agent.running
                HoverHandler { id: briefHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    onTapped: {
                        const m = engine.selectedMeeting
                        card.ask(qsTr("Brief me for “%1” with %2: look through my recent mail and Teams messages with them (only look) and tell me in a few lines what's going on and what I should raise.")
                                 .arg(m.title).arg((m.people || []).join(", ") || qsTr("the people in it")))
                    }
                }
            }
        }

        // The earlier meetings, newest first, each with its gist.
        Repeater {
            model: card.related
            delegate: ColumnLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 2
                Label {
                    Layout.fillWidth: true
                    text: modelData.title + "  ·  " + Sidecar.when(modelData.started, Date.now())
                    color: titleHover.hovered ? theme.accent : ui.text
                    font.pixelSize: 12
                    font.bold: true
                    elide: Text.ElideRight
                    HoverHandler { id: titleHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: win.openFrom(modelData.id, -1) }
                }
                Label {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: modelData.tldr
                    color: ui.muted
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }
            }
        }

        GridLayout {
            Layout.fillWidth: true
            columns: card.width >= 560 && card.mine.length && card.theirs.length ? 2 : 1
            columnSpacing: 18
            rowSpacing: 8
            visible: card.mine.length + card.theirs.length > 0
            Repeater {
                model: [
                    { title: qsTr("You still owe"), tone: theme.accent, items: card.mine.map(i => i.text + (i.due ? " (" + i.due + ")" : "")) },
                    { title: qsTr("They said they'd"), tone: ui.them, items: card.theirs.map(i => (i.who ? i.who + ": " : "") + i.text + (i.due ? " (" + i.due + ")" : "")) }
                ].filter(s => s.items.length)
                delegate: ColumnLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Layout.alignment: Qt.AlignTop
                    spacing: 3
                    Label { text: modelData.title; color: modelData.tone; font.pixelSize: 11; font.bold: true }
                    Repeater {
                        model: modelData.items.slice(0, 4)
                        delegate: Label {
                            required property string modelData
                            Layout.fillWidth: true
                            text: "· " + modelData
                            color: ui.muted
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }
                    }
                    Label {
                        visible: modelData.items.length > 4
                        text: qsTr("+%n more", "", modelData.items.length - 4)
                        color: ui.faint
                        font.pixelSize: 10
                    }
                }
            }
        }
    }
}
