import QtQuick
import QtQuick.Controls
import Aloi

// What's being said, right under the agent, so a question never means losing
// the call. It follows the live end until Chris scrolls up; the Transcript
// tab is still the whole thing. Beside it, his own notes: each is a Note line
// in the transcript, so the agent, the takeaways and the wrap-up all read it.
// Where there's no room for the column the box stays, under what's being said.
Rectangle {
    id: tail
    color: "transparent"
    signal openAll()

    property bool live: false
    readonly property bool wide: width >= 520
    function startNote() { box.forceActiveFocus() }

    // A note belongs to the meeting it was started in, and one still being
    // typed when that meeting goes is saved, not lost or moved to the next.
    property string noteFor: ""
    function addNote() {
        const text = box.text.trim()
        if (text !== "") engine.addNote(noteFor || engine.selected, text)
        box.text = ""
    }
    onLiveChanged: if (!live) addNote()

    readonly property string them: {
        const people = engine.selectedMeeting.people || []
        return people.length === 1 ? people[0].split(" ")[0] : qsTr("Them")
    }

    Row {
        id: heading
        x: 2
        spacing: 10
        Label {
            text: qsTr("LIVE")
            color: ui.live
            font.pixelSize: 10
            font.letterSpacing: 1.4
            font.bold: true
        }
        Label {
            text: qsTr("Full transcript")
            color: openHover.hovered ? theme.accent : ui.faint
            font.pixelSize: 10
            HoverHandler { id: openHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: tail.openAll() }
        }
    }

    ListView {
        id: list
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.right: tail.wide ? divider.left : parent.right
        anchors.bottom: tail.wide ? parent.bottom : field.top
        anchors.topMargin: heading.height + 6
        anchors.rightMargin: tail.wide ? 10 : 0
        anchors.bottomMargin: tail.wide ? 0 : 6
        clip: true
        model: transcript
        spacing: 3
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        property bool stick: true
        property bool following: false
        function follow() { following = true; positionViewAtEnd(); following = false }
        onContentYChanged: if (!following && height > 0) stick = atYEnd || contentHeight <= height
        onHeightChanged: if (height > 0 && stick) Qt.callLater(follow)
        onCountChanged: if (stick) Qt.callLater(follow)
        onContentHeightChanged: if (stick) Qt.callLater(follow)
        Kinetic { target: list }

        // The speaker in their colour, then what they said.
        delegate: Item {
            id: line
            required property string speaker
            required property string text
            required property bool mine
            required property int voice
            required property string voiceName
            width: list.width - 12
            // Notes have their own column when it's there.
            readonly property bool elsewhere: tail.wide && speaker === "Note"
            height: elsewhere ? 0 : said.implicitHeight
            visible: !elsewhere
            Text {
                width: 66
                text: line.mine ? qsTr("Me") : line.speaker === "Note" ? qsTr("Note")
                    : line.speaker === "Mark" ? "⚑" : line.voice > 0 ? line.voiceName : tail.them
                color: line.mine ? ui.me : line.speaker === "Note" || line.speaker === "Mark" ? theme.accent : ui.them
                font.pixelSize: 13
                font.bold: true
                elide: Text.ElideRight
            }
            Text {
                id: said
                x: 74
                width: parent.width - x
                text: line.text
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: ui.text
                font.pixelSize: 13
            }
        }

        footer: Column {
            width: list.width - 12
            Repeater {
                model: engine.interims
                delegate: Item {
                    id: now
                    required property var modelData
                    width: parent.width
                    height: saying.implicitHeight
                    Text {
                        width: 66
                        text: now.modelData.speaker === "Them" ? tail.them : qsTr("Me")
                        color: ui.alpha(now.modelData.speaker === "Them" ? ui.them : ui.me, 0.6)
                        font.pixelSize: 13
                        font.bold: true
                        elide: Text.ElideRight
                    }
                    Text {
                        id: saying
                        x: 74
                        width: parent.width - x
                        text: now.modelData.text
                        color: ui.muted
                        font.pixelSize: 13
                        font.italic: true
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
    }

    Label {
        anchors.left: parent.left
        anchors.leftMargin: 2
        y: heading.height + 10
        visible: transcript.count === 0 && engine.interims.length === 0
        text: qsTr("Nothing said yet.")
        color: ui.faint
        font.pixelSize: 12
    }

    Rectangle {
        id: divider
        visible: tail.wide
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.right: notes.left
        anchors.rightMargin: 12
        width: 1
        color: ui.line
    }

    Item {
        id: notes
        visible: tail.wide
        anchors.top: parent.top
        anchors.bottom: field.top
        anchors.bottomMargin: 6
        anchors.right: parent.right
        width: Math.round(tail.width * 0.36)
        Label {
            id: notesHeading
            text: qsTr("MY NOTES")
            color: theme.accent
            font.pixelSize: 10
            font.letterSpacing: 1.4
            font.bold: true
        }
        ListView {
            id: noteList
            anchors.fill: parent
            anchors.topMargin: notesHeading.height + 6
            clip: true
            model: transcript.notes
            spacing: 5
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            onCountChanged: Qt.callLater(positionViewAtEnd)
            onHeightChanged: Qt.callLater(positionViewAtEnd)
            delegate: Text {
                required property var modelData
                width: noteList.width - 10
                textFormat: Text.StyledText
                text: "<font color='" + ui.faint + "'>" + modelData.time.slice(0, 5) + "</font>&nbsp;&nbsp;"
                      + String(modelData.text).replace(/&/g, "&amp;").replace(/</g, "&lt;")
                color: ui.text
                font.pixelSize: 13
                wrapMode: Text.Wrap
            }
        }
        Label {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.rightMargin: 8
            y: notesHeading.height + 6
            visible: noteList.count === 0
            text: qsTr("What you type here goes to the agent and the wrap-up.")
            color: ui.faint
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }
    }

    // Enter adds it and stays here for the next one.
    Rectangle {
        id: field
        anchors.left: tail.wide ? notes.left : parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Math.min(box.implicitHeight + 12, Math.max(30, tail.height - heading.height - 30))
        radius: Math.min(4, theme.radius)
        color: ui.raised
        border.color: box.activeFocus ? ui.alpha(theme.accent, 0.6) : ui.line
        clip: true
        TextEdit {
            id: box
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 6
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            color: ui.text
            font.pixelSize: 13
            wrapMode: TextEdit.Wrap
            selectByMouse: true
            selectionColor: ui.alpha(theme.accent, 0.35)
            selectedTextColor: ui.text
            onTextChanged: tail.noteFor = text === "" ? "" : tail.noteFor || engine.selected
            Keys.onReturnPressed: tail.addNote()
            Keys.onEnterPressed: tail.addNote()
            Keys.onEscapePressed: focus = false
            Text {
                visible: box.text === ""
                width: parent.width
                text: qsTr("Add a note")
                color: ui.faint
                font: box.font
                elide: Text.ElideRight
            }
        }
    }
}
