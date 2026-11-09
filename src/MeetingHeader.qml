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
    // The title comes first. Beside it the switches have their labels; when
    // that would cut the title short they keep only their glyphs; when even
    // that would, they drop under it and the title may take two lines. Worked
    // out from what the title and labels measure, not from the buttons, so
    // the switches changing shape can't feed back into it.
    readonly property real room: width - 48 - 14 - titleMetrics.advanceWidth
    readonly property real glyphWidth: moreButton.implicitWidth
    readonly property real compactNeeded: (isCurrent ? pauseButton.implicitWidth + 3 * (glyphWidth + switches.spacing) : glyphWidth + switches.spacing)
                                          + glyphWidth
    readonly property real labelsWidth: (isCurrent ? endMetrics.advanceWidth + markMetrics.advanceWidth + 32 : 0) + noteMetrics.advanceWidth + 16
    readonly property bool compact: room < compactNeeded + labelsWidth
    readonly property bool narrow: room < compactNeeded

    TextMetrics { id: titleMetrics; font: title.font; text: head.m.title || "" }
    TextMetrics { id: endMetrics; font.pixelSize: 12; text: qsTr("End") }
    TextMetrics { id: markMetrics; font.pixelSize: 12; text: qsTr("Mark") }
    TextMetrics { id: noteMetrics; font.pixelSize: 12; text: qsTr("Note") }

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

            // Where it sits, as in every Aloi app: Home, then its group.
            Row {
                spacing: 8
                Label {
                    text: qsTr("Home")
                    color: crumbHover.hovered ? ui.text : ui.faint
                    font.pixelSize: 11
                    HoverHandler { id: crumbHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: win.goHome() }
                }
                Label { text: "›"; color: ui.faint; font.pixelSize: 11 }
                Label {
                    text: head.isCurrent ? qsTr("On now")
                        : Sidecar.needsWrapup(head.m, head.now) ? qsTr("Needs wrap-up")
                        : ({ today: qsTr("Today"), yesterday: qsTr("Yesterday") })[Sidecar.group(head.m, head.now)] || Sidecar.dayLabel(head.m)
                    color: ui.faint
                    font.pixelSize: 11
                }
            }

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
                        font.pixelSize: 26
                        font.bold: true
                        wrapMode: head.narrow ? Text.Wrap : Text.NoWrap
                        maximumLineCount: head.narrow ? 2 : 1
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
                        font.pixelSize: 26
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
                    KeyButton {
                        id: pauseButton
                        visible: head.isCurrent
                        primary: true
                        glyph: head.live ? "pause" : "mic"
                        text: head.live ? qsTr("Pause") : qsTr("Resume")
                        keys: "space"
                        onClicked: engine.toggleListening()
                    }
                    KeyButton {
                        visible: head.isCurrent
                        glyph: "stop"
                        text: qsTr("End")
                        compact: head.compact
                        keys: "e"
                        tip: qsTr("End the meeting and draft its wrap-up")
                        onClicked: win.act("end", head.m)
                    }
                    KeyButton {
                        visible: head.isCurrent
                        glyph: "flag"
                        text: qsTr("Mark")
                        compact: head.compact
                        keys: "m"
                        tip: qsTr("Flag this moment as one that matters")
                        onClicked: win.markNow()
                    }
                    KeyButton {
                        glyph: "note"
                        text: qsTr("Note")
                        compact: head.compact
                        keys: "n"
                        tip: qsTr("Type a note of your own into the meeting")
                        onClicked: meetingPane.note()
                    }
                    KeyButton {
                        id: moreButton
                        glyph: "more"
                        keys: "."
                        tip: qsTr("Everything for this meeting (right-click it in the list, too)")
                        onClicked: head.openMenu()
                    }
                }
            }

            // When, how long, with whom.
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
                            // Echoes (the call's own audio caught by the mic) are
                            // reassurance, not news: they're under the line count.
                            out.push({ text: qsTr("%n lines", "", head.isCurrent ? transcript.count : (head.m.lines || 0)), color: ui.faint,
                                       tip: head.isCurrent && engine.echoes > 0 ? qsTr("%n echoes of the call dropped", "", engine.echoes) : "" })
                            const people = head.m.people || []
                            if (people.length > 0)
                                out.push({ text: people.length === 1 ? qsTr("with %1").arg(people[0]) : qsTr("with %1 +%2").arg(people[0]).arg(people.length - 1),
                                           color: ui.muted, tip: people.length > 1 ? people.join("\n") : "" })
                            else if (head.m.event)
                                out.push({ text: qsTr("from your calendar"), color: ui.faint })
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
                            ToolTip.visible: metaHover.hovered && (modelData.tip || "") !== "" && modelData.tip !== modelData.text
                            ToolTip.delay: 300
                            ToolTip.text: modelData.tip || ""
                        }
                    }
                    Item { width: 12; height: 22; visible: stageChip.visible }
                    StageChip { id: stageChip; stage: head.stage; m: head.m }
                }
            }
            Item { implicitHeight: 6 }
        }

    MeetingMenu { id: meetingMenu }
}
