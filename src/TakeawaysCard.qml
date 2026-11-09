import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "sidecar.js" as Sidecar

// While the call goes on: what needs Chris right now, which is what he's been
// asked and hasn't answered and what he's said he'd do, the latest three of
// each, kept current by Haiku every couple of minutes. What's decided and
// what's open stay a count until he taps for them: a glance, not a read.
// Each item jumps to where it was said.
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
    readonly property int glance: 3  // of each list, before he asks for all of it
    // Tapped open: every list, whole. Otherwise the two that need him, or
    // just the counts once a conversation wants the room.
    property bool full: false
    readonly property bool open: full || agent.messages.length === 0
    function toggle() { full = !full }
    readonly property var folded: sections.filter(s => !listed.includes(s))
    readonly property var listed: !open ? [] : full ? sections : sections.filter(s => s.key === "asked" || s.key === "mine")

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
                visible: card.full
                Layout.fillWidth: true
                text: card.t.updated ? qsTr("as of %1").arg(Sidecar.clock(card.t.updated)) : ""
                color: ui.faint
                font.pixelSize: 10
            }
            // What isn't listed: how many of each, in their colors.
            Row {
                visible: !card.full
                Layout.fillWidth: true
                clip: true
                spacing: 12
                Repeater {
                    model: card.folded
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
            Glyph {
                name: card.full ? "rolldown" : "chevron"
                color: ui.faint
                font.pixelSize: 13
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
                columns: card.width >= 620 ? Math.max(1, card.listed.filter(x => (card.t[x.key] || []).length > 0).length) : 1
                columnSpacing: 18
                rowSpacing: 8
                Repeater {
                    model: card.listed
                    delegate: ColumnLayout {
                        id: section
                        required property var modelData
                        readonly property var every: card.t[modelData.key] || []
                        // Most recent last, so the latest are the ones to keep.
                        readonly property var items: card.full ? every : every.slice(-card.glance)
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
                        Label {
                            visible: section.every.length > section.items.length
                            text: qsTr("+%n earlier", "", section.every.length - section.items.length)
                            color: ui.faint
                            font.pixelSize: 10
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
