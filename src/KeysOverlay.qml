import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// Every key, on ?.
Popup {
    id: popup
    modal: true
    anchors.centerIn: Overlay.overlay
    padding: 22
    Material.roundedScale: theme.radius

    readonly property var keys: [
        ["Space", qsTr("Listen / pause (starts a meeting if none is on)")],
        ["E", qsTr("End the meeting")],
        ["Ctrl+N", qsTr("Start a new meeting")],
        ["R", qsTr("Rename the meeting on screen")],
        ["J / K", qsTr("Next / previous meeting")],
        ["G", qsTr("Go to the meeting that's on now")],
        ["\\", qsTr("Show / hide the meetings list")],
        ["Ctrl+F", qsTr("Search meetings")],
        ["/", qsTr("Ask about the meeting on screen")],
        ["1 – 4", qsTr("Ask a suggested question")],
        ["Esc", qsTr("Stop the agent, leave the ask box")],
        ["Y / N", qsTr("Allow / deny what the agent wants to run")],
        ["Ctrl+Shift+K", qsTr("New chat with the agent")],
        ["End", qsTr("Back to the live end of the transcript")],
        ["?", qsTr("These keys")],
        ["Q", qsTr("Quit (pauses listening)")]
    ]

    contentItem: GridLayout {
        columns: 2
        columnSpacing: 22
        rowSpacing: 8
        Repeater {
            model: popup.keys.length * 2
            delegate: Text {
                required property int index
                readonly property var entry: popup.keys[Math.floor(index / 2)]
                text: index % 2 === 0 ? entry[0] : entry[1]
                color: index % 2 === 0 ? theme.accent : ui.text
                font.pixelSize: 13
                font.bold: index % 2 === 0
            }
        }
    }
}
