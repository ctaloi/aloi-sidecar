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
    function toLive() { list.stick = true; list.positionViewAtEnd() }
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
    Timer { id: flashTimer; interval: 2200; onTriggered: pane.flash = -1 }

    ListView {
        id: list
        anchors.fill: parent
        anchors.margins: 0
        topMargin: 14
        bottomMargin: 14
        clip: true
        model: transcript
        boundsBehavior: Flickable.StopAtBounds
        reuseItems: true
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        // Stay on the live end as lines arrive, unless Chris scrolled up to read.
        property bool stick: true
        // Another meeting on screen starts at its live end.
        Connections {
            target: engine
            function onSelectedChanged() { list.stick = true; Qt.callLater(list.positionViewAtEnd) }
        }
        onMovementEnded: stick = atYEnd
        onCountChanged: if (stick) Qt.callLater(positionViewAtEnd)
        onContentHeightChanged: if (stick && !moving) Qt.callLater(positionViewAtEnd)

        delegate: Item {
            id: row
            required property int index
            required property int lineId
            required property string speaker
            required property string text
            required property string time
            required property double start
            required property bool mine
            // A run of lines from the same side shows the name once.
            required property bool runStart
            readonly property bool sameAsAbove: !runStart
            width: list.width
            height: body.implicitHeight + (sameAsAbove ? 4 : 12)

            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                radius: Math.min(4, theme.radius)
                color: ui.alpha(theme.accent, 0.14)
                opacity: pane.flash === row.lineId ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 400 } }
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
                width: 56
                visible: !row.sameAsAbove
                text: row.mine ? qsTr("Me") : qsTr("Them")
                color: row.mine ? ui.me : ui.them
                font.pixelSize: 13
                font.bold: true
            }
            TextEdit {
                id: body
                x: 146
                y: row.sameAsAbove ? 2 : 8
                width: row.width - x - 22
                text: row.text
                color: ui.text
                font.pixelSize: 14
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
                        text: modelData.speaker === "Them" ? qsTr("Them") : qsTr("Me")
                        color: ui.alpha(modelData.speaker === "Them" ? ui.them : ui.me, 0.6)
                        font.pixelSize: 13
                        font.bold: true
                    }
                    Text {
                        id: live
                        x: 146
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

    ActionButton {
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: 12
        visible: !pane.following && transcript.count > 0
        text: qsTr("↓ Live  (End)")
        primary: true
        onClicked: pane.toLive()
    }
}
