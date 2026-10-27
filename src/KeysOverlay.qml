import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// Every key, on ?.
Popup {
    id: popup
    modal: true
    anchors.centerIn: Overlay.overlay
    Material.roundedScale: theme.radius

    readonly property var keys: [
        [qsTr("During a call")],
        ["Space", qsTr("Listen / pause (starts a meeting if none is on)")],
        ["E", qsTr("End the meeting; Opus drafts its wrap-up")],
        ["Ctrl+N", qsTr("Start a new meeting")],
        ["M", qsTr("Mark this moment as one that matters")],
        ["N", qsTr("Type a note into the transcript")],
        ["End", qsTr("Back to the live end of the transcript")],
        [qsTr("Meetings")],
        ["J / K", qsTr("Next / previous meeting")],
        ["G", qsTr("Go to the meeting that's on now")],
        ["F", qsTr("Follow-ups / meetings")],
        ["R", qsTr("Rename the meeting on screen")],
        ["T", qsTr("Next tab: agent, transcript, notes")],
        ["Menu", qsTr("Everything for the meeting (or right-click it)")],
        [qsTr("Right-click"), qsTr("A transcript line: ask the agent about it, copy it")],
        ["Del", qsTr("Delete the meeting (to the trash folder)")],
        ["\\", qsTr("Show / hide the meetings list")],
        ["Ctrl+F", qsTr("Search what was said, in every meeting")],
        [qsTr("Wrap-up")],
        ["D", qsTr("Draft the wrap-up (again)")],
        ["S", qsTr("Send to Notion")],
        ["O", qsTr("Open it in Notion")],
        ["W", qsTr("Write the follow-up email (to Outlook Drafts)")],
        ["C / Shift+C", qsTr("Copy the wrap-up / the transcript")],
        ["X", qsTr("No wrap-up needed (or needed after all)")],
        [qsTr("Agent")],
        ["/", qsTr("Ask about the meeting on screen")],
        ["1 – 4", qsTr("Ask a suggested question")],
        ["Ctrl+A", qsTr("Next question across all meetings (in the ask box)")],
        ["Y / N", qsTr("Allow / deny what the agent wants to run")],
        ["Esc", qsTr("Stop the agent, leave a text box")],
        ["Ctrl+Shift+K", qsTr("New chat with the agent")],
        [qsTr("Sidecar")],
        ["Ctrl+K", qsTr("Do anything, go to any meeting")],
        ["?", qsTr("These keys")],
        ["Q", qsTr("Quit (pauses listening)")]
    ]

    readonly property real inner: Math.min(win.width - 96, 920)
    readonly property bool twoColumns: inner >= 760
    width: inner + leftPadding + rightPadding
    height: Math.min(win.height - 60, implicitHeight)
    padding: 26
    background: Rectangle {
        color: ui.raised
        border.color: ui.line
        radius: theme.radius
    }
    Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.55) }

    // Two columns of groups when there's room, one when there isn't.
    contentItem: Flickable {
        implicitHeight: flow.implicitHeight
        contentHeight: flow.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Flow {
            id: flow
            width: popup.inner
            spacing: 28
            Repeater {
                model: {
                    const groups = []
                    for (const k of popup.keys) {
                        if (k.length === 1) groups.push({ title: k[0], rows: [] })
                        else groups[groups.length - 1].rows.push(k)
                    }
                    return groups
                }
                delegate: Column {
                    id: group
                    required property var modelData
                    width: popup.twoColumns ? (popup.inner - 28) / 2 : popup.inner
                    spacing: 7
                    Text {
                        text: group.modelData.title.toUpperCase()
                        color: ui.muted
                        font.pixelSize: 10
                        font.letterSpacing: 1.4
                        font.bold: true
                        bottomPadding: 2
                    }
                    Repeater {
                        model: group.modelData.rows
                        delegate: Row {
                            required property var modelData
                            spacing: 14
                            Text { width: 104; text: modelData[0]; color: theme.accent; font.pixelSize: 12; font.bold: true }
                            Text { width: group.width - 118; text: modelData[1]; color: ui.text; font.pixelSize: 12; wrapMode: Text.Wrap }
                        }
                    }
                }
            }
        }
    }
}
