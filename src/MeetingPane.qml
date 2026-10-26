import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import "sidecar.js" as Sidecar

// The meeting on screen: what it is (the title, which you can rename),
// when and how long, the switches for it while it's on, and what was said.
Rectangle {
    id: pane
    color: ui.window

    property double now: Date.now()
    readonly property var m: engine.selectedMeeting
    readonly property bool has: m.id !== undefined
    readonly property bool isCurrent: has && m.id === engine.current
    readonly property bool live: isCurrent && engine.listening
    property alias transcriptPane: transcriptView
    function rename() { if (has) { titleEdit.text = m.title; editing = true; titleEdit.forceActiveFocus(); titleEdit.selectAll() } }
    property bool editing: false

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // What the meeting is.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: pane.width < 520 ? 18 : 32
            Layout.rightMargin: pane.width < 520 ? 18 : 32
            Layout.topMargin: 22
            spacing: 10
            visible: pane.has

            Label {
                text: qsTr("Meetings") + "  ›  " + (pane.isCurrent ? qsTr("Now") : Sidecar.dayLabel(pane.m))
                color: ui.faint
                font.pixelSize: 11
            }

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
                    text: Sidecar.span(pane.m) + (pane.m.state === "ended" ? "  ·  " + Sidecar.length(pane.m, pane.now) : "")
                }
                Chip {
                    visible: pane.has
                    tone: ui.faint
                    text: qsTr("%n lines", "", transcript.count)
                }
                Chip {
                    visible: pane.has && !!pane.m.event
                    tone: ui.muted
                    glyph: "▦"
                    text: qsTr("From your calendar")
                }
                Chip {
                    visible: pane.has && !!pane.m.notion
                    tone: ui.them
                    glyph: "✓"
                    text: qsTr("In Notion")
                }
                Chip {
                    visible: pane.isCurrent && engine.echoes > 0
                    tone: ui.faint
                    text: qsTr("%n echoes dropped", "", engine.echoes)
                }
            }

            // The switches: while it's on, listen/pause and end; afterwards, copy.
            Flow {
                Layout.fillWidth: true
                Layout.topMargin: 4
                Layout.bottomMargin: 16
                spacing: 8
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
                    onClicked: endDialog.open()
                }
                ActionButton {
                    visible: !pane.isCurrent
                    primary: engine.current === ""
                    text: qsTr("New meeting")
                    keys: "ctrl+N"
                    onClicked: win.newMeeting()
                }
                ActionButton {
                    text: qsTr("Rename")
                    keys: "R"
                    onClicked: pane.rename()
                }
                ActionButton {
                    text: copied.running ? qsTr("Copied") : qsTr("Copy transcript")
                    enabled: transcript.count > 0
                    onClicked: { engine.copyToClipboard(engine.transcriptText()); copied.restart() }
                    Timer { id: copied; interval: 1500 }
                }
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: ui.line; visible: pane.has }

        TranscriptPane {
            id: transcriptView
            Layout.fillWidth: true
            Layout.fillHeight: true
        }
    }

    Dialog {
        id: endDialog
        anchors.centerIn: Overlay.overlay
        modal: true
        title: qsTr("End “%1”?").arg(pane.m.title || "")
        width: Math.min(460, win.width - 40)
        Material.roundedScale: theme.radius
        Label {
            width: endDialog.availableWidth
            wrapMode: Text.Wrap
            text: qsTr("Listening stops and the meeting is kept as it is. Space after this starts a new one.")
        }
        standardButtons: Dialog.Ok | Dialog.Cancel
        onAccepted: engine.endMeeting()
    }
    function confirmEnd() { if (isCurrent) endDialog.open() }
    readonly property bool dialogOpen: endDialog.visible
}
