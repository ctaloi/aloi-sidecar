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
    // Notes or Transcript, for a meeting that's over. A meeting opens on its
    // notes once it has them, and on its transcript until then.
    property string tab: "notes"
    readonly property bool notesShown: over && tab === "notes"
    onMChanged: if (m.id !== shownId) { shownId = m.id || ""; tab = "notes" }
    property string shownId: ""

    function rename() { if (has) { titleEdit.text = m.title; editing = true; titleEdit.forceActiveFocus(); titleEdit.selectAll() } }
    function toggleTab() { if (over) tab = tab === "notes" ? "transcript" : "notes" }
    function showLine(id) { tab = "transcript"; Qt.callLater(() => transcriptView.showLine(id)) }
    function revertNotes() { wrapupView.revert() }
    function openMenu() { if (has) meetingMenu.show(m, moreButton, 0, moreButton.height + 4) }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        CallBanner { Layout.fillWidth: true }

        // What the meeting is.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: pane.width < 520 ? 18 : 32
            Layout.rightMargin: pane.width < 520 ? 18 : 32
            Layout.topMargin: 20
            spacing: 10
            visible: pane.has

            Label {
                text: qsTr("Meetings") + "  ›  " + (pane.isCurrent ? qsTr("Now") : Sidecar.dayLabel(pane.m))
                color: ui.faint
                font.pixelSize: 11
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                Item {
                    Layout.fillWidth: true
                    implicitHeight: Math.max(title.implicitHeight, titleEdit.implicitHeight)
                    Label {
                        id: title
                        visible: !pane.editing
                        width: parent.width
                        text: pane.m.title || ""
                        color: ui.text
                        font.pixelSize: 26
                        font.bold: true
                        wrapMode: Text.Wrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        HoverHandler { id: titleHover; cursorShape: Qt.IBeamCursor }
                        TapHandler { onDoubleTapped: pane.rename() }
                        ToolTip.visible: titleHover.hovered
                        ToolTip.delay: 900
                        ToolTip.text: qsTr("Double-click or R to rename")
                    }
                    TextInput {
                        id: titleEdit
                        visible: pane.editing
                        width: parent.width
                        color: ui.text
                        font.pixelSize: 26
                        font.bold: true
                        selectByMouse: true
                        selectionColor: ui.alpha(theme.accent, 0.4)
                        onAccepted: { engine.rename(pane.m.id, text); pane.editing = false }
                        Keys.onEscapePressed: pane.editing = false
                        onActiveFocusChanged: if (!activeFocus) pane.editing = false
                        Rectangle { anchors.top: parent.bottom; width: parent.width; height: 1; color: theme.accent }
                    }
                }
                ActionButton {
                    id: moreButton
                    Layout.alignment: Qt.AlignTop
                    menu: true
                    tip: qsTr("Everything for this meeting (right-click it in the list, too)")
                    onClicked: pane.openMenu()
                }
            }

            Flow {
                Layout.fillWidth: true
                spacing: 8
                Chip {
                    visible: pane.isCurrent
                    filled: true
                    tone: pane.live ? ui.live : ui.muted
                    glyph: "●"
                    text: pane.live ? qsTr("Live  %1").arg(Sidecar.elapsed(pane.m, pane.now)) : qsTr("Paused")
                }
                Chip {
                    visible: pane.has
                    tone: ui.muted
                    text: Sidecar.span(pane.m) + (pane.over ? "  ·  " + Sidecar.length(pane.m, pane.now) : "")
                }
                Chip {
                    visible: pane.has
                    tone: ui.faint
                    text: qsTr("%n lines", "", pane.isCurrent ? transcript.count : (pane.m.lines || 0))
                }
                Chip {
                    visible: pane.has && !!pane.m.event
                    tone: ui.muted
                    glyph: "▦"
                    text: qsTr("From your calendar")
                }
                StageChip { stage: pane.stage; m: pane.m }
                Chip {
                    visible: pane.isCurrent && engine.echoes > 0
                    tone: ui.faint
                    text: qsTr("%n echoes dropped", "", engine.echoes)
                }
            }

            // The switches: while it's on, listen/pause and end; afterwards,
            // the notes and the transcript as tabs.
            Flow {
                Layout.fillWidth: true
                Layout.topMargin: 4
                Layout.bottomMargin: pane.over ? 0 : 16
                spacing: 8
                visible: !pane.over
                ActionButton {
                    visible: pane.isCurrent
                    primary: true
                    text: pane.live ? qsTr("Pause") : qsTr("Resume")
                    keys: "space"
                    onClicked: engine.toggleListening()
                }
                ActionButton {
                    visible: pane.isCurrent
                    text: qsTr("End meeting")
                    keys: "E"
                    onClicked: win.act("end", pane.m)
                }
                ActionButton {
                    text: qsTr("Rename")
                    keys: "R"
                    onClicked: pane.rename()
                }
                ActionButton {
                    text: qsTr("Copy transcript")
                    keys: "shift+C"
                    enabled: transcript.count > 0
                    onClicked: win.act("copyTranscript", pane.m)
                }
            }
            UnderlineTabs {
                Layout.fillWidth: true
                Layout.leftMargin: -10
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
