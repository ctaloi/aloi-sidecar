import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "sidecar.js" as Sidecar

// The meeting on screen: what it is (the title, which you can rename),
// when and how long, the switches for it, and then either what was said or,
// once it's over, what it came to.
Rectangle {
    id: pane
    color: ui.window

    property double now: Date.now()
    readonly property var m: engine.selectedMeeting
    readonly property bool has: m.id !== undefined
    readonly property bool isCurrent: has && m.id === engine.current
    readonly property bool live: isCurrent && engine.listening
    readonly property bool over: has && m.state === "ended"
    readonly property string stage: Sidecar.stage(m)
    property alias transcriptPane: transcriptView
    property bool editing: false
    // The switches sit beside the title while at least a short title still
    // fits there, and drop under it otherwise.
    readonly property bool narrow: width - 48 < switches.needed + Math.min(title.implicitWidth, 240) + 14
    // Notes or Transcript, for a meeting that's over. A meeting opens on its
    // notes once it has them, and on its transcript until then.
    property string tab: "notes"
    readonly property bool notesShown: over && tab === "notes"
    onMChanged: if (m.id !== shownId) { shownId = m.id || ""; tab = "notes" }
    property string shownId: ""

    function rename() { if (has) { titleEdit.text = m.title; editing = true; titleEdit.forceActiveFocus(); titleEdit.selectAll() } }
    function note() { if (has) { tab = "transcript"; Qt.callLater(transcriptView.startNote) } }
    function toggleTab() { if (over) tab = tab === "notes" ? "transcript" : "notes" }
    // From a follow-up: once the meeting's transcript has loaded, show the line.
    property int pendingLine: -1
    function showLineWhenLoaded(id) { pendingLine = id; if (!engine.loading && transcript.count > 0) Qt.callLater(flushLine) }
    function flushLine() { if (pendingLine >= 0) { const id = pendingLine; pendingLine = -1; showLine(id) } }
    Connections {
        target: engine
        function onLoadingChanged() { if (!engine.loading) Qt.callLater(pane.flushLine) }
    }
    function showLine(id) { tab = "transcript"; Qt.callLater(() => transcriptView.showLine(id)) }
    function revertNotes() { wrapupView.revert() }
    function openMenu() { if (has) meetingMenu.show(m, moreButton, 0, moreButton.height + 4) }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        CallBanner { Layout.fillWidth: true }

        // What the meeting is, on one line with its switches; when and who
        // on a quiet line under it; then, once it's over, Notes and Transcript.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: pane.narrow ? 18 : 28
            Layout.rightMargin: pane.narrow ? 14 : 20
            Layout.topMargin: 14
            Layout.bottomMargin: pane.over ? 0 : 12
            spacing: 6
            visible: pane.has

            GridLayout {
                Layout.fillWidth: true
                columns: pane.narrow ? 1 : 2
                columnSpacing: 14
                rowSpacing: 8
                Item {
                    Layout.fillWidth: true
                    implicitHeight: Math.max(title.implicitHeight, titleEdit.implicitHeight)
                    Label {
                        id: title
                        visible: !pane.editing
                        width: parent.width
                        text: pane.m.title || ""
                        color: ui.text
                        font.pixelSize: 21
                        font.bold: true
                        elide: Text.ElideRight
                        HoverHandler { id: titleHover; cursorShape: Qt.IBeamCursor }
                        TapHandler { onDoubleTapped: pane.rename() }
                        ToolTip.visible: titleHover.hovered
                        ToolTip.delay: 900
                        ToolTip.text: title.truncated ? pane.m.title + "\n" + qsTr("Double-click or R to rename") : qsTr("Double-click or R to rename")
                    }
                    TextInput {
                        id: titleEdit
                        visible: pane.editing
                        width: parent.width
                        color: ui.text
                        font.pixelSize: 21
                        font.bold: true
                        selectByMouse: true
                        selectionColor: ui.alpha(theme.accent, 0.4)
                        onAccepted: { engine.rename(pane.m.id, text); pane.editing = false }
                        Keys.onEscapePressed: pane.editing = false
                        onActiveFocusChanged: if (!activeFocus) pane.editing = false
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
                    Layout.fillWidth: pane.narrow
                    Layout.preferredWidth: pane.narrow ? -1 : needed
                    ActionButton {
                        visible: pane.isCurrent
                        primary: true
                        implicitHeight: 30
                        text: pane.live ? qsTr("Pause") : qsTr("Resume")
                        keys: "space"
                        onClicked: engine.toggleListening()
                    }
                    ActionButton {
                        visible: pane.isCurrent
                        implicitHeight: 30
                        text: qsTr("End")
                        keys: "E"
                        tip: qsTr("End the meeting and draft its wrap-up")
                        onClicked: win.act("end", pane.m)
                    }
                    ActionButton {
                        visible: pane.isCurrent
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
                        onClicked: pane.note()
                    }
                    ActionButton {
                        id: moreButton
                        implicitHeight: 30
                        menu: true
                        tip: qsTr("Everything for this meeting (right-click it in the list, too)")
                        onClicked: pane.openMenu()
                    }
                }
            }

            // When, how long, how much, with whom; and where the wrap-up is.
            Flow {
                Layout.fillWidth: true
                spacing: 0
                Repeater {
                    id: metaItems
                    model: {
                        const out = []
                        if (pane.isCurrent)
                            out.push({ text: pane.live ? "● " + qsTr("Live %1").arg(Sidecar.elapsed(pane.m, pane.now)) : "● " + qsTr("Paused"),
                                       color: pane.live ? ui.live : ui.muted })
                        out.push({ text: Sidecar.span(pane.m) + (pane.over ? " · " + Sidecar.length(pane.m, pane.now) : ""), color: ui.muted })
                        out.push({ text: qsTr("%n lines", "", pane.isCurrent ? transcript.count : (pane.m.lines || 0)), color: ui.faint })
                        const people = pane.m.people || []
                        if (people.length > 0)
                            out.push({ text: people.length === 1 ? qsTr("with %1").arg(people[0]) : qsTr("with %1 +%2").arg(people[0]).arg(people.length - 1),
                                       color: ui.muted, tip: people.join("\n") })
                        else if (pane.m.event)
                            out.push({ text: qsTr("from your calendar"), color: ui.faint })
                        if (pane.isCurrent && engine.echoes > 0)
                            out.push({ text: qsTr("%n echoes dropped", "", engine.echoes), color: ui.faint })
                        return out
                    }
                    delegate: Label {
                        required property var modelData
                        required property int index
                        readonly property bool last: index === metaItems.count - 1
                        height: 22
                        verticalAlignment: Text.AlignVCenter
                        text: modelData.text + (last ? "" : "   ·   ")
                        color: modelData.color
                        font.pixelSize: 12
                        HoverHandler { id: metaHover; enabled: !!modelData.tip }
                        ToolTip.visible: metaHover.hovered && (modelData.tip || "").indexOf("\n") >= 0
                        ToolTip.delay: 300
                        ToolTip.text: modelData.tip || ""
                    }
                }
                Item { width: 12; height: 22; visible: stageChip.visible }
                StageChip { id: stageChip; stage: pane.stage; m: pane.m }
            }

            UnderlineTabs {
                Layout.fillWidth: true
                Layout.leftMargin: -10
                Layout.topMargin: 2
                visible: pane.over
                tabs: [
                    { label: qsTr("Notes"), count: 0, current: pane.tab === "notes", keys: "T", run: () => pane.tab = "notes",
                      dot: pane.stage === "drafting" || pane.stage === "ready" || pane.stage === "draftFailed" || pane.stage === "sendFailed" },
                    { label: qsTr("Transcript"), count: pane.m.lines || 0, current: pane.tab === "transcript", keys: "T", run: () => pane.tab = "transcript" }
                ]
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: ui.line; visible: pane.has }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: pane.notesShown ? 1 : 0
            TranscriptPane { id: transcriptView }
            WrapupPane {
                id: wrapupView
                now: pane.now
                onShowLine: id => pane.showLine(id)
            }
        }
    }

    MeetingMenu { id: meetingMenu }

}
