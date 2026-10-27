import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "sidecar.js" as Sidecar

// The meeting under its header, as tabs: the agent, where a call is worked;
// the transcript, what's being said underneath; and once it's over, the
// notes it came to. A call opens on the agent, a finished meeting on its
// notes when it has them.
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
    property alias agentPane: agentView
    // "agent", "transcript" or "notes".
    property string tab: "agent"
    readonly property bool hasNotes: over && stage !== "none" && stage !== "skipped"
    // Chosen once the meeting's stage has caught up with the switch.
    onMChanged: if (m.id !== shownId) { shownId = m.id || ""; Qt.callLater(() => tab = hasNotes ? "notes" : "agent") }
    onHasNotesChanged: if (!hasNotes && tab === "notes") tab = "agent"
    property string shownId: ""
    readonly property var tabs: hasNotes ? ["agent", "transcript", "notes"] : ["agent", "transcript"]

    function rename() { meetingHeader.rename() }
    function note() { if (has) { tab = "transcript"; Qt.callLater(transcriptView.startNote) } }
    function toggleTab() { tab = tabs[(tabs.indexOf(tab) + 1) % tabs.length] }
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

        // The tabs, and at their right what the next question is about and
        // a fresh start, while the agent's the one showing.
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            Layout.fillHeight: false
            Layout.leftMargin: 18
            Layout.rightMargin: 14
            spacing: 12
            visible: pane.has
            UnderlineTabs {
                Layout.fillWidth: true
                Layout.fillHeight: true
                tabs: {
                    const out = [
                        { label: qsTr("Agent"), current: pane.tab === "agent", keys: "T", run: () => pane.tab = "agent",
                          dot: agent.running || agent.approvals.length > 0 },
                        { label: pane.live ? qsTr("Live transcript") : qsTr("Transcript"), count: pane.isCurrent ? transcript.count : (pane.m.lines || 0),
                          current: pane.tab === "transcript", keys: "T", run: () => pane.tab = "transcript" }
                    ]
                    if (pane.hasNotes)
                        out.push({ label: qsTr("Notes"), current: pane.tab === "notes", keys: "T", run: () => pane.tab = "notes",
                                   dot: pane.stage === "drafting" || pane.stage === "ready" || pane.stage === "draftFailed" || pane.stage === "sendFailed" })
                    return out
                }
            }
            // Which meetings the next question is about: this one, or (ctrl+A)
            // all of them for one question.
            Label {
                visible: pane.tab === "agent"
                text: (agent.wide ? "◎ " + qsTr("All meetings") : qsTr("This meeting")) + "  ▾"
                color: agent.wide ? theme.accent : scopeHover.hovered ? ui.muted : ui.faint
                font.pixelSize: 12
                HoverHandler { id: scopeHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: agent.wide = !agent.wide }
                ToolTip.visible: scopeHover.hovered
                ToolTip.delay: 400
                ToolTip.text: agent.wide ? qsTr("The next question searches every meeting (ctrl+A switches back)")
                                         : qsTr("Ask the next question across every meeting (ctrl+A)")
            }
            ActionButton {
                visible: pane.tab === "agent" && agent.messages.length > 0
                enabled: !agent.running
                text: qsTr("New chat")
                implicitHeight: 28
                onClicked: agent.forget()
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: ui.line; visible: pane.has }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: pane.tab === "notes" ? 2 : pane.tab === "transcript" ? 1 : 0
            AgentPane { id: agentView }
            TranscriptPane { id: transcriptView }
            WrapupPane {
                id: wrapupView
                now: pane.now
                onShowLine: id => pane.showLine(id)
            }
        }
    }
}
