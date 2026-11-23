import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Along the bottom while several wrap-ups go to Notion: which one is going,
// how many are done, and a bar that fills. When it's over it says what came
// of it (sent, failed, a page to pick) and stays until it's closed, so a
// send never ends without a word.
Rectangle {
    id: bar
    readonly property var b: engine.bulk
    readonly property bool running: !!b.running
    readonly property int total: b.total || 0
    readonly property int handled: (b.done || 0) + (b.failed || 0) + (b.choose || []).length
    readonly property var going: running && b.current ? engine.meetingById(b.current) : ({})
    readonly property var failures: b.failures || []
    readonly property var toPick: b.choose || []
    // Asked for, before the engine has said it's begun.
    property bool asked: false
    property bool closed: false
    readonly property bool shown: asked || (total > 0 && (running || !closed))

    Connections {
        target: engine
        function onBulkChanged() {
            if (bar.running) { bar.closed = false; bar.asked = false }
        }
    }
    // If the engine never takes it up, don't sit there saying it's starting.
    Timer { interval: 8000; running: bar.asked; onTriggered: bar.asked = false }

    implicitHeight: shown ? 40 : 0
    color: ui.panel
    Rectangle { width: parent.width; height: 1; color: bar.failures.length > 0 && !bar.running ? ui.danger : ui.line }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 12
        spacing: 12
        visible: bar.shown

        Rectangle {
            width: 8; height: 8; radius: 4
            color: bar.running || bar.asked ? theme.accent : bar.failures.length > 0 ? ui.danger : ui.them
            SequentialAnimation on opacity {
                running: bar.running || bar.asked
                loops: Animation.Infinite
                alwaysRunToEnd: true
                NumberAnimation { to: 0.25; duration: 600 }
                NumberAnimation { to: 1; duration: 600 }
            }
        }
        Label {
            objectName: "bulkText"
            Layout.fillWidth: true
            Layout.maximumWidth: implicitWidth
            text: bar.asked && !bar.running ? qsTr("Starting to send to Notion…")
                : bar.running ? qsTr("Sending %1 of %2 to Notion").arg(Math.min(bar.handled + 1, bar.total)).arg(bar.total)
                                + (bar.going.title ? "  ·  " + bar.going.title : "")
                : [qsTr("%n sent to Notion", "", bar.b.done || 0),
                   bar.failures.length > 0 ? qsTr("%n failed", "", bar.failures.length) : "",
                   bar.toPick.length > 0 ? qsTr("%n waiting for you to pick a page", "", bar.toPick.length) : ""]
                      .filter(x => x).join("  ·  ")
            color: ui.text
            font.pixelSize: 12
            font.bold: true
            elide: Text.ElideRight
        }
        // Why the first one failed: the rest are on their cards.
        Label {
            Layout.fillWidth: true
            visible: !bar.running && bar.failures.length > 0
            text: bar.failures.length > 0 ? (engine.meetingById(bar.failures[0].id).title || "") + ": " + (bar.failures[0].error || "") : ""
            textFormat: Text.PlainText
            color: ui.danger
            font.pixelSize: 11
            elide: Text.ElideRight
        }
        Rectangle {
            Layout.fillWidth: true
            Layout.minimumWidth: 60
            visible: bar.running || bar.asked
            implicitHeight: 6
            radius: Math.min(3, theme.radius)
            color: ui.raised
            Rectangle {
                width: bar.total > 0 ? parent.width * bar.handled / bar.total : 0
                height: parent.height
                radius: parent.radius
                color: theme.accent
                Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            }
        }
        Item { Layout.fillWidth: true; visible: !bar.running && !bar.asked && bar.failures.length === 0 }
        Label {
            visible: bar.running
            text: bar.handled + " / " + bar.total
            color: ui.muted
            font.pixelSize: 11
        }
        Label {
            visible: !bar.running && !bar.asked && bar.toPick.length > 0
            text: qsTr("Pick a page") + "  ›"
            color: pickHover.hovered ? ui.text : theme.accent
            font.pixelSize: 11
            font.bold: true
            HoverHandler { id: pickHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: win.act("choosePage", engine.meetingById(bar.toPick[0])) }
        }
        Label {
            objectName: "bulkClose"
            visible: !bar.running && !bar.asked
            text: qsTr("Close")
            color: closeHover.hovered ? ui.text : ui.muted
            font.pixelSize: 11
            HoverHandler { id: closeHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: bar.closed = true }
        }
    }
}
