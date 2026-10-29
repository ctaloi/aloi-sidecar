import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Things said on the call worth checking (a customer, a number, a ticket, a
// circuit), picked out with the takeaways. One click has the agent look it
// up with Chris's skills; nothing is looked up until he clicks.
Flow {
    id: cards
    spacing: 8
    readonly property var items: engine.takeaways.lookups || []
    // What's been asked about, per meeting, so a card dims once it's done.
    property var asked: ({})
    signal look(string prompt)
    visible: items.length > 0
    // Even columns across the pane, so a row of cards doesn't leave a ragged
    // gap down the right.
    readonly property int columns: Math.max(1, Math.min(items.length, Math.floor((width + spacing) / 230)))
    readonly property real cardWidth: Math.floor((width - spacing * (columns - 1)) / columns)

    FontMetrics { id: whyMetrics; font.pixelSize: 11 }

    readonly property var kinds: ({
        customer: qsTr("customer"), number: qsTr("number"), ticket: qsTr("ticket"),
        circuit: qsTr("circuit"), person: qsTr("person"), other: qsTr("look up")
    })

    Repeater {
        model: cards.items
        delegate: Rectangle {
            id: card
            required property var modelData
            readonly property string key: engine.selected + "|" + modelData.query
            readonly property bool done: !!cards.asked[key]
            width: cards.cardWidth
            height: body.implicitHeight + 16
            radius: Math.min(4, theme.radius)
            color: hover.hovered && !card.done ? ui.hover : ui.raised
            border.color: hover.hovered && !card.done ? ui.alpha(theme.accent, 0.6) : ui.line
            opacity: card.done ? 0.5 : 1
            Column {
                id: body
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 2
                Row {
                    spacing: 6
                    Glyph { name: card.done ? "check" : "search"; color: theme.accent; font.pixelSize: 12 }
                    Text {
                        text: (cards.kinds[card.modelData.kind] || cards.kinds.other).toUpperCase()
                        color: ui.faint
                        font.pixelSize: 9
                        font.letterSpacing: 1.2
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                Text {
                    width: parent.width
                    text: card.modelData.query
                    color: ui.text
                    font.pixelSize: 13
                    font.bold: true
                    elide: Text.ElideRight
                }
                // Once a conversation's going, just what it is.
                Text {
                    width: parent.width
                    visible: text !== "" && agent.messages.length === 0
                    text: card.modelData.why
                    color: ui.muted
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    // Two lines' room either way, so cards side by side match.
                    height: Math.max(implicitHeight, Math.ceil(whyMetrics.height * 2))
                }
            }
            HoverHandler { id: hover; cursorShape: card.done ? Qt.ArrowCursor : Qt.PointingHandCursor }
            TapHandler {
                enabled: !card.done && !agent.running
                onTapped: {
                    const a = Object.assign({}, cards.asked)
                    a[card.key] = true
                    cards.asked = a
                    cards.look(qsTr("Look up %1 (%2): %3. Use your skills, only look, don't change anything, and answer in a few lines.")
                               .arg(card.modelData.query).arg(cards.kinds[card.modelData.kind] || card.modelData.kind).arg(card.modelData.why))
                }
            }
            ToolTip.visible: hover.hovered && !card.done
            ToolTip.delay: 500
            ToolTip.text: agent.messages.length > 0 && card.modelData.why ? card.modelData.why : qsTr("Have the agent look this up")
        }
    }
}
