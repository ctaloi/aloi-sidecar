import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "sidecar.js" as Sidecar

// The meeting at the top of the call: its title (which you can rename), the
// switches for it, and when and with whom, on one quiet line.
Rectangle {
    id: head
    color: ui.window
    implicitHeight: has ? column.implicitHeight + 14 + 8 : 0
    visible: has

    property double now: Date.now()
    readonly property var m: engine.selectedMeeting
    readonly property bool has: m.id !== undefined
    readonly property bool isCurrent: has && m.id === engine.current
    readonly property bool live: isCurrent && engine.listening
    readonly property bool over: has && m.state === "ended"
    readonly property string stage: Sidecar.stage(m)
    property bool editing: false
    // The switches sit beside the title while at least a short title still
    // fits there, and drop under it otherwise.
    readonly property bool narrow: width - 48 < switches.needed + Math.min(title.implicitWidth, 240) + 14

    function rename() { if (has) { titleEdit.text = m.title; editing = true; titleEdit.forceActiveFocus(); titleEdit.selectAll() } }
    function openMenu() { if (has) meetingMenu.show(m, moreButton, 0, moreButton.height + 4) }

    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: ui.line }

        // What the meeting is, on one line with its switches; when and who
        // on a quiet line under it; then, once it's over, Notes and Transcript.
        ColumnLayout {
            id: column
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: head.narrow ? 18 : 28
            anchors.rightMargin: head.narrow ? 14 : 20
            anchors.topMargin: 14
            spacing: 6

            GridLayout {
                Layout.fillWidth: true
                columns: head.narrow ? 1 : 2
                columnSpacing: 14
                rowSpacing: 8
                Item {
                    Layout.fillWidth: true
                    implicitHeight: Math.max(title.implicitHeight, titleEdit.implicitHeight)
                    Label {
                        id: title
                        visible: !head.editing
                        width: parent.width
                        text: head.m.title || ""
                        color: ui.text
                        font.pixelSize: 21
                        font.bold: true
                        elide: Text.ElideRight
                        HoverHandler { id: titleHover; cursorShape: Qt.IBeamCursor }
                        TapHandler { onDoubleTapped: head.rename() }
                        ToolTip.visible: titleHover.hovered
                        ToolTip.delay: 900
                        ToolTip.text: title.truncated ? head.m.title + "\n" + qsTr("Double-click or R to rename") : qsTr("Double-click or R to rename")
                    }
                    TextInput {
                        id: titleEdit
                        visible: head.editing
                        width: parent.width
                        color: ui.text
                        font.pixelSize: 21
                        font.bold: true
                        selectByMouse: true
                        selectionColor: ui.alpha(theme.accent, 0.4)
                        onAccepted: { engine.rename(head.m.id, text); head.editing = false }
                        Keys.onEscapePressed: head.editing = false
                        onActiveFocusChanged: if (!activeFocus) head.editing = false
                        Rectangle { anchors.top: parent.bottom; width: parent.width; height: 1; color: theme.accent }
                    }
                }
                // While it's on: listen/pause, end, mark, note. Afterwards only
                // Note; rename and copy are a key or the ⋯ away.
                Flow {
                    id: switches
                    spacing: 6
                    readonly property real needed: {
                        let w = 0, n = 0
                        for (const c of children) if (c.visible) { w += c.implicitWidth; n++ }
                        return w + Math.max(0, n - 1) * spacing
                    }
                    Layout.fillWidth: head.narrow
                    Layout.preferredWidth: head.narrow ? -1 : needed
                    ActionButton {
                        visible: head.isCurrent
                        primary: true
                        implicitHeight: 30
                        text: head.live ? qsTr("Pause") : qsTr("Resume")
                        keys: "space"
                        onClicked: engine.toggleListening()
                    }
                    ActionButton {
                        visible: head.isCurrent
                        implicitHeight: 30
                        text: qsTr("End")
                        keys: "E"
                        tip: qsTr("End the meeting and draft its wrap-up")
                        onClicked: win.act("end", head.m)
                    }
                    ActionButton {
                        visible: head.isCurrent
                        implicitHeight: 30
                        text: qsTr("Mark")
                        keys: "M"
                        tip: qsTr("Flag this moment as one that matters")
                        onClicked: win.markNow()
                    }
                    ActionButton {
                        implicitHeight: 30
                        text: qsTr("Note")
                        keys: "N"
                        tip: qsTr("Type a line of your own into the transcript")
                        onClicked: meetingPane.note()
                    }
                    ActionButton {
                        id: moreButton
                        implicitHeight: 30
                        menu: true
                        tip: qsTr("Everything for this meeting (right-click it in the list, too)")
                        onClicked: head.openMenu()
                    }
                }
            }

            // When, how long, with whom; and, while it's heard, who's talking.
            RowLayout {
                Layout.fillWidth: true
                spacing: 14
                // When, how long, how much, with whom; and where the wrap-up is.
                Flow {
                    Layout.fillWidth: true
                    spacing: 0
                    Repeater {
                        id: metaItems
                        model: {
                            const out = []
                            if (head.isCurrent)
                                out.push({ text: head.live ? "● " + qsTr("Live %1").arg(Sidecar.elapsed(head.m, head.now)) : "● " + qsTr("Paused"),
                                           color: head.live ? ui.live : ui.muted })
                            out.push({ text: Sidecar.span(head.m), color: ui.muted })
                            if (head.over) out.push({ text: Sidecar.length(head.m, head.now), color: ui.muted })
                            out.push({ text: qsTr("%n lines", "", head.isCurrent ? transcript.count : (head.m.lines || 0)), color: ui.faint })
                            const people = head.m.people || []
                            if (people.length > 0)
                                out.push({ text: people.length === 1 ? qsTr("with %1").arg(people[0]) : qsTr("with %1 +%2").arg(people[0]).arg(people.length - 1),
                                           color: ui.muted, tip: people.join("\n") })
                            else if (head.m.event)
                                out.push({ text: qsTr("from your calendar"), color: ui.faint })
                            if (head.isCurrent && engine.echoes > 0)
                                out.push({ text: qsTr("%n echoes dropped", "", engine.echoes), color: ui.faint })
                            return out
                        }
                        delegate: Label {
                            required property var modelData
                            required property int index
                            readonly property bool last: index === metaItems.count - 1
                            height: 22
                            verticalAlignment: Text.AlignVCenter
                            text: modelData.text + (last ? "" : "  ·  ")
                            color: modelData.color
                            font.pixelSize: 12
                            HoverHandler { id: metaHover; enabled: !!modelData.tip }
                            ToolTip.visible: metaHover.hovered && (modelData.tip || "").indexOf("\n") >= 0
                            ToolTip.delay: 300
                            ToolTip.text: modelData.tip || ""
                        }
                    }
                    Item { width: 12; height: 22; visible: stageChip.visible }
                    StageChip { id: stageChip; stage: head.stage; m: head.m }
                }
            }
            // While it's heard: who's talking, across the header.
            LevelTrace {
                visible: head.live
                Layout.fillWidth: true
                Layout.preferredHeight: 36
                Layout.topMargin: 4
            }
            Item { implicitHeight: 6 }
        }

    MeetingMenu { id: meetingMenu }
}
