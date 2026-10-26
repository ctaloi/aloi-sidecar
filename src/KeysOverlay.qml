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
        ["Space", qsTr("Start / stop listening")],
        ["/", qsTr("Ask about the call")],
        ["1 – 4", qsTr("Ask a suggested question")],
        ["Esc", qsTr("Stop the agent, leave the ask box")],
        ["Y / N", qsTr("Allow / deny what the agent wants to run")],
        ["End", qsTr("Back to the live end of the transcript")],
        ["Ctrl+N", qsTr("Start a new meeting")],
        ["Ctrl+Shift+K", qsTr("Clear the conversation with the agent")],
        ["?", qsTr("These keys")],
        ["Q", qsTr("Quit (stops listening)")]
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
