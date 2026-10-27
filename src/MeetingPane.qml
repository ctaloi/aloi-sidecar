import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "sidecar.js" as Sidecar

// The meeting on screen, beside the agent: what was said, live, and once
// it's over what it came to. It folds away (]) when the agent wants the room.
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
    signal collapse()
    // Notes or Transcript, for a meeting that's over. A meeting opens on its
    // notes once it has them, and on its transcript until then.
    property string tab: "notes"
    readonly property bool notesShown: over && tab === "notes"
    onMChanged: if (m.id !== shownId) { shownId = m.id || ""; tab = "notes" }
    property string shownId: ""

    function rename() { meetingHeader.rename() }
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
    function openMenu() { meetingHeader.openMenu() }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Transcript, and once it's over Notes; the header above the agent
        // says what the meeting is.
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 46
            Layout.fillHeight: false
            Layout.leftMargin: 14
            Layout.rightMargin: 8
            spacing: 6
            visible: pane.has
            UnderlineTabs {
                Layout.fillWidth: true
                Layout.fillHeight: true
                tabs: pane.over ? [
                    { label: qsTr("Notes"), count: 0, current: pane.tab === "notes", keys: "T", run: () => pane.tab = "notes",
                      dot: pane.stage === "drafting" || pane.stage === "ready" || pane.stage === "draftFailed" || pane.stage === "sendFailed" },
                    { label: qsTr("Transcript"), count: pane.m.lines || 0, current: pane.tab === "transcript", keys: "T", run: () => pane.tab = "transcript" }
                ] : [
                    { label: pane.live ? qsTr("Live transcript") : qsTr("Transcript"), count: transcript.count, current: true, run: () => {} }
                ]
            }
            ActionButton {
                text: "›"
                tip: qsTr("Fold this panel away (])")
                implicitHeight: 28
                implicitWidth: 28
                onClicked: pane.collapse()
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

}
