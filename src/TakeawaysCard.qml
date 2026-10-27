import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "sidecar.js" as Sidecar

// While the call goes on: what Chris has committed to, what he's been asked
// and hasn't answered, what's decided and what's open, kept current by
// Haiku every couple of minutes. A glance, not a read; each item jumps to
// where it was said.
Rectangle {
    id: card
    property double now: Date.now()
    readonly property var t: engine.takeaways
    readonly property bool live: engine.selected !== "" && engine.selected === engine.current
    readonly property var sections: [
        { key: "asked", title: qsTr("Asked, not answered"), tone: ui.live },
        { key: "mine", title: qsTr("You said you'd"), tone: theme.accent },
        { key: "decisions", title: qsTr("Decided"), tone: ui.them },
        { key: "questions", title: qsTr("Open"), tone: ui.muted }
    ]
    readonly property int total: sections.reduce((n, s) => n + ((t[s.key] || []).length), 0)
    // Open while there's no conversation to make room for; folded to its
    // counts once there is, unless Chris opens or folds it himself.
    property bool chosen: false
    property bool chosenOpen: true
    readonly property bool open: chosen ? chosenOpen : agent.messages.length === 0
    function toggle() { chosenOpen = !open; chosen = true }

    visible: live && total > 0
    implicitHeight: column.implicitHeight + (open ? 20 : 16)
    radius: Math.min(6, theme.radius)
    color: ui.window
    border.color: ui.line

    ColumnLayout {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: card.open ? 10 : 8
        anchors.leftMargin: 14
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Label {
                text: qsTr("TAKEAWAYS")
                color: ui.muted
                font.pixelSize: 10
                font.letterSpacing: 1.4
                font.bold: true
            }
            Label {
                visible: card.open
                Layout.fillWidth: true
                text: card.t.updated ? qsTr("as of %1").arg(Sidecar.clock(card.t.updated)) : ""
                color: ui.faint
                font.pixelSize: 10
            }
            // Folded: how many of each, in their colors.
            Row {
                visible: !card.open
                Layout.fillWidth: true
                clip: true
                spacing: 12
                Repeater {
                    model: card.sections
                    delegate: Label {
                        required property var modelData
                        readonly property int n: (card.t[modelData.key] || []).length
                        visible: n > 0
                        text: n + " " + ({ asked: qsTr("asked"), mine: qsTr("yours"), decisions: qsTr("decided"), questions: qsTr("open") })[modelData.key]
                        color: modelData.tone
                        font.pixelSize: 11
                    }
                }
            }
            Label {
                text: card.open ? "▾" : "▸"
                color: ui.faint
                font.pixelSize: 11
            }
        }

        Flickable {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(lists.implicitHeight, 260)
            visible: card.open
            contentHeight: lists.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            // Side by side across a wide agent, a board to glance at; stacked
            // when it's narrow.
            GridLayout {
                id: lists
                width: parent.width
                columns: card.width >= 620 ? Math.max(1, card.sections.filter(x => (card.t[x.key] || []).length > 0).length) : 1
                columnSpacing: 18
                rowSpacing: 8
                Repeater {
                    model: card.sections
                    delegate: ColumnLayout {
                        id: section
                        required property var modelData
                        readonly property var items: card.t[modelData.key] || []
                        visible: items.length > 0
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        Layout.alignment: Qt.AlignTop
                        spacing: 3
                        Label {
                            text: section.modelData.title
                            color: section.modelData.tone
                            font.pixelSize: 11
                            font.bold: true
                        }
                        Repeater {
                            model: section.items
                            delegate: Label {
                                required property var modelData
                                Layout.fillWidth: true
                                text: "· " + modelData.text
                                color: itemHover.hovered ? ui.text : ui.muted
                                font.pixelSize: 12
                                wrapMode: Text.Wrap
                                HoverHandler { id: itemHover; cursorShape: modelData.at >= 0 ? Qt.PointingHandCursor : Qt.ArrowCursor }
                                TapHandler { onTapped: if (modelData.at >= 0) meetingPane.showLine(modelData.at) }
                            }
                        }
                    }
                }
            }
        }
    }
    TapHandler {
        // The header folds it away.
        onTapped: (point) => { if (point.position.y < 30) card.toggle() }
    }
}
