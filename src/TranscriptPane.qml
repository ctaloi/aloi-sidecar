import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import "sidecar.js" as Sidecar

// The meeting as it's said: settled lines, then what each side is saying
// right now in faint italics. It follows the live end until you scroll up,
// and a button brings you back.
Rectangle {
    id: pane
    color: ui.window

    readonly property bool following: list.stick
    // Each voice past the first gets its own hue, so a run of lines reads by colour.
    function voiceColor(v) {
        const hues = [0.58, 0.78, 0.09, 0.95, 0.45, 0.68]
        return Qt.hsla(hues[(v - 2) % hues.length], 0.55, theme.dark ? 0.7 : 0.38, 1)
    }
    // With one other person in the meeting, the other side has their name.
    readonly property string them: {
        const people = engine.selectedMeeting.people || []
        return people.length === 1 ? people[0].split(" ")[0] : qsTr("Them")
    }
    function toLive() { list.stick = true; list.follow() }
    // Scroll to a line (from a wrap-up item) and light it up for a moment.
    function showLine(id) {
        const row = transcript.rowOf(id)
        if (row < 0) return
        list.stick = false
        list.positionViewAtIndex(row, ListView.Center)
        flash = id
        flashTimer.restart()
    }
    property int flash: -1
    // N: a line of Chris's own into the meeting on screen.
    property bool noting: false
    function startNote() { noting = true; noteField.text = ""; noteField.forceActiveFocus() }
    Timer { id: flashTimer; interval: 2200; onTriggered: pane.flash = -1 }

    SideMenu {
        id: lineMenu
        property var line: ({})
        MenuRow {
            text: qsTr("Ask the agent about this")
            onTriggered: {
                win.showAgent()
                meetingPane.agentPane.input.text = qsTr("About what %1 said at %2, “%3”: ").arg(lineMenu.line.speaker).arg(lineMenu.line.time.slice(0, 5)).arg(lineMenu.line.text)
                meetingPane.agentPane.input.forceActiveFocus()
                meetingPane.agentPane.input.cursorPosition = meetingPane.agentPane.input.text.length
            }
        }
        // Whose voice it is, for a line told apart by voice.
        Repeater {
            model: lineMenu.line.voice > 0 ? (engine.selectedMeeting.people || []).slice(0, 6) : []
            delegate: MenuRow {
                required property string modelData
                text: qsTr("This is %1").arg(modelData)
                onTriggered: engine.nameVoice(engine.selected, lineMenu.line.voice, modelData)
            }
        }
        MenuRow {
            visible: lineMenu.line.voice > 0
            text: qsTr("Name this voice…")
            onTriggered: {
                const v = lineMenu.line.voice, id = engine.selected
                palette.choose(qsTr("Who is %1? Type a name").arg(lineMenu.line.who),
                               (engine.selectedMeeting.people || []).map(p => ({ label: p, run: () => engine.nameVoice(id, v, p) })),
                               text => engine.nameVoice(id, v, text))
            }
        }
        MenuRow {
            visible: lineMenu.line.voice > 0 && lineMenu.line.who !== qsTr("Voice %1").arg(lineMenu.line.voice)
            text: qsTr("Forget this voice's name")
            onTriggered: engine.nameVoice(engine.selected, lineMenu.line.voice, "")
        }
        MenuLine { visible: lineMenu.line.voice > 0 }
        MenuRow {
            text: qsTr("Copy this line")
            onTriggered: { engine.copyToClipboard(lineMenu.line.text); toast.show(qsTr("Copied the line.")) }
        }
        MenuRow {
            text: qsTr("Copy the transcript")
            keys: "shift+C"
            onTriggered: win.act("copyTranscript", engine.selectedMeeting)
        }
    }

    ListView {
        id: list
        anchors.fill: parent
        // A readable column in a wide window, like the agent's.
        anchors.leftMargin: Math.max(0, (pane.width - 980) / 2)
        anchors.rightMargin: Math.max(0, (pane.width - 980) / 2)
        anchors.margins: 0
        topMargin: 14
        bottomMargin: 14
        clip: true
        model: transcript
        boundsBehavior: Flickable.StopAtBounds
        reuseItems: true
        cacheBuffer: 3000
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        // Stay on the live end as lines arrive, unless Chris scrolled up to read.
        property bool stick: true
        // Another meeting on screen starts at its live end.
        Connections {
            target: engine
            function onSelectedChanged() { list.stick = true; Qt.callLater(list.follow) }
        }
        property bool following: false
        function follow() { following = true; positionViewAtEnd(); following = false }
        onContentYChanged: if (!following && height > 0) stick = atYEnd || contentHeight <= height
        // Shown again after another tab (it had no height meanwhile).
        onHeightChanged: if (height > 0 && (stick || contentHeight <= height)) { stick = true; Qt.callLater(follow) }
        onCountChanged: if (stick) Qt.callLater(follow)
        onContentHeightChanged: if (stick) Qt.callLater(follow)
        SmoothScroll { flick: list }

        delegate: Item {
            id: row
            required property int index
            required property int lineId
            required property string speaker
            required property string text
            required property string time
            required property double start
            required property bool mine
            required property int voice
            required property string voiceName
            // A run of lines from the same side shows the name once.
            required property bool runStart
            readonly property bool sameAsAbove: !runStart
            readonly property bool isNote: speaker === "Note"
            readonly property bool isMark: speaker === "Mark"
            width: list.width
            height: body.implicitHeight + (sameAsAbove ? 4 : 12)

            // Right-click a line: copy it, or ask the agent about it.
            TapHandler {
                acceptedButtons: Qt.RightButton
                onTapped: (point) => { lineMenu.line = { text: row.text, time: row.time, speaker: row.mine ? qsTr("I") : who.text, voice: row.voice, who: row.voiceName }; lineMenu.popup(row, point.position.x, point.position.y) }
            }

            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                radius: Math.min(4, theme.radius)
                color: ui.alpha(theme.accent, 0.14)
                opacity: pane.flash === row.lineId ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 400 } }
            }
            // A mark: a band across the moment.
            Rectangle {
                visible: row.isMark
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                anchors.topMargin: 3
                anchors.bottomMargin: 1
                radius: Math.min(4, theme.radius)
                color: ui.alpha(theme.accent, 0.1)
                Rectangle { width: 3; height: parent.height; color: theme.accent; radius: 1 }
            }

            Text {
                id: stamp
                x: 18
                y: body.y + 2
                width: 64
                // The same clock as the meetings list, to the second.
                text: Sidecar.seconds(row.start)
                color: ui.faint
                font.pixelSize: 11
            }
            Text {
                id: who
                x: 86
                y: body.y
                width: 78
                visible: !row.sameAsAbove || row.isMark
                text: row.mine ? qsTr("Me") : row.isNote ? qsTr("Note") : row.isMark ? "⚑" : row.voice > 0 ? row.voiceName : pane.them
                color: row.mine ? ui.me : row.isNote || row.isMark ? theme.accent : row.voice > 1 ? pane.voiceColor(row.voice) : ui.them
                font.pixelSize: 13
                font.bold: true
                elide: Text.ElideRight
            }
            TextEdit {
                id: body
                x: 170
                y: row.sameAsAbove ? 2 : 8
                width: row.width - x - 22
                text: row.text
                color: row.isMark ? theme.accent : ui.text
                font.pixelSize: 14
                font.italic: row.isNote
                wrapMode: TextEdit.Wrap
                readOnly: true
                selectByMouse: true
                selectionColor: ui.alpha(theme.accent, 0.35)
                selectedTextColor: ui.text
            }
        }

        footer: Column {
            width: list.width
            topPadding: 4
            Repeater {
                model: engine.interims
                delegate: Item {
                    required property var modelData
                    width: list.width
                    height: live.implicitHeight + 10
                    Text {
                        x: 18
                        y: 7
                        text: "···"
                        color: ui.faint
                        font.pixelSize: 11
                    }
                    Text {
                        x: 86
                        y: 5
                        text: modelData.speaker === "Them" ? pane.them : qsTr("Me")
                        color: ui.alpha(modelData.speaker === "Them" ? ui.them : ui.me, 0.6)
                        font.pixelSize: 13
                        font.bold: true
                    }
                    Text {
                        id: live
                        x: 170
                        y: 5
                        width: list.width - x - 22
                        text: modelData.text
                        color: ui.muted
                        font.pixelSize: 14
                        font.italic: true
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
    }

    Column {
        anchors.centerIn: parent
        spacing: 8
        visible: transcript.count === 0 && engine.interims.length === 0
        width: Math.min(parent.width - 48, 420)
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            color: ui.muted
            font.pixelSize: 15
            text: !engine.connected ? qsTr("Waiting for the engine…")
                : engine.loading ? qsTr("Opening the meeting…")
                : engine.selected === "" ? qsTr("No meeting on.")
                : engine.selected !== engine.current ? qsTr("Nobody spoke in this one.")
                : engine.listening ? qsTr("Listening. Lines show up here as people talk.")
                : qsTr("Paused.")
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            color: ui.faint
            font.pixelSize: 12
            visible: engine.connected && !engine.listening && !engine.loading
                     && (engine.selected === "" || engine.selected === engine.current)
            text: qsTr("Space starts listening to your mic and every speaker.")
        }
    }

    // The note being typed, along the bottom.
    Rectangle {
        id: noteBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: pane.noting ? 52 : 0
        visible: height > 0
        clip: true
        color: ui.panel
        Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Rectangle { width: parent.width; height: 1; color: ui.line }
        Row {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 18
            anchors.rightMargin: 18
            spacing: 12
            Text { text: qsTr("Note"); color: theme.accent; font.pixelSize: 13; font.bold: true; anchors.verticalCenter: parent.verticalCenter; width: 56 }
            TextInput {
                id: noteField
                width: parent.width - 56 - hint.width - 24
                anchors.verticalCenter: parent.verticalCenter
                color: ui.text
                font.pixelSize: 14
                font.italic: true
                selectByMouse: true
                clip: true
                onAccepted: { engine.addNote(engine.selected, text); pane.noting = false }
                Keys.onEscapePressed: pane.noting = false
                onActiveFocusChanged: if (!activeFocus && text === "") pane.noting = false
                Text {
                    visible: noteField.text === ""
                    text: qsTr("Something nobody said out loud, like “check their contract end date”")
                    color: ui.faint
                    font: noteField.font
                    width: parent.width
                    elide: Text.ElideRight
                }
            }
            Text {
                id: hint
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.StyledText
                text: "<font color='" + theme.accent + "'>enter</font> " + qsTr("adds") + "  <font color='" + theme.accent + "'>esc</font> " + qsTr("cancels")
                color: ui.faint
                font.pixelSize: 11
            }
        }
    }

    ActionButton {
        anchors.bottom: noteBar.top
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: 12
        visible: !pane.following && transcript.count > 0 && list.contentHeight > list.height
        text: engine.selected === engine.current && engine.listening ? qsTr("↓ Live  (End)") : qsTr("↓ End")
        primary: true
        onClicked: pane.toLive()
    }
}
