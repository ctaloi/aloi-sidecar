import QtQuick
import QtQuick.Controls
import "sidecar.js" as Sidecar

// A list of things said across meetings (decisions, questions, promises),
// each with the meeting it's from and when. A row opens that meeting at
// the line.
Rectangle {
    id: ledger
    property string title
    property int total: 0
    property color tone: ui.text
    // [{text, title, started, due?, who?, meeting, at}]
    property var items: []
    property double asOf: Date.now()
    // Only so many until asked for all (0: all of them).
    property int limit: 0
    property bool all: false
    readonly property var shown: limit > 0 && !all ? items.slice(0, limit) : items
    signal picked(var item)

    implicitHeight: ledgerColumn.implicitHeight + 8
    radius: theme.radius
    color: ui.panel
    border.color: ui.line
    clip: true
    Column {
        id: ledgerColumn
        width: parent.width
        Item {
            width: parent.width
            height: 38
            Rectangle {
                x: 16
                anchors.verticalCenter: parent.verticalCenter
                width: 8; height: 8; radius: 4
                color: ledger.tone
            }
            Label {
                x: 32
                anchors.verticalCenter: parent.verticalCenter
                text: ledger.title
                color: ui.text
                font.pixelSize: 12
                font.bold: true
            }
            Label {
                anchors.right: parent.right
                anchors.rightMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                text: ledger.total > ledger.items.length ? qsTr("%1 of %2").arg(ledger.items.length).arg(ledger.total)
                                                         : ledger.items.length
                color: ui.faint
                font.pixelSize: 11
            }
        }
        Repeater {
            model: ledger.shown
            Rectangle {
                id: entry
                required property var modelData
                width: ledgerColumn.width
                height: entryColumn.implicitHeight + 16
                color: entryHover.hovered ? ui.hover : "transparent"
                Rectangle { x: 16; width: parent.width - 32; height: 1; color: ui.line; opacity: 0.5 }
                Column {
                    id: entryColumn
                    x: 16; y: 8
                    width: parent.width - 32
                    spacing: 3
                    Label {
                        width: parent.width
                        text: (entry.modelData.who ? entry.modelData.who + ": " : "") + entry.modelData.text
                        textFormat: Text.PlainText
                        color: ui.text
                        font.pixelSize: 12
                        lineHeight: 1.2
                        wrapMode: Text.Wrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                    }
                    Label {
                        width: parent.width
                        text: [entry.modelData.due || "", entry.modelData.title || qsTr("Untitled"),
                               Sidecar.when(entry.modelData.started, ledger.asOf)].filter(x => x).join("  ·  ")
                        color: ui.faint
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                }
                HoverHandler { id: entryHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: ledger.picked(entry.modelData) }
            }
        }
        Rectangle {
            visible: ledger.limit > 0 && ledger.items.length > ledger.limit
            width: ledgerColumn.width
            height: 30
            color: moreHover.hovered ? ui.hover : "transparent"
            Rectangle { x: 16; width: parent.width - 32; height: 1; color: ui.line; opacity: 0.5 }
            Label {
                x: 16
                anchors.verticalCenter: parent.verticalCenter
                text: ledger.all ? qsTr("Fold them away") : qsTr("%n more", "", ledger.items.length - ledger.limit) + "  ·  " + qsTr("show all")
                color: moreHover.hovered ? ui.text : ui.muted
                font.pixelSize: 11
            }
            HoverHandler { id: moreHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: ledger.all = !ledger.all }
        }
    }
}
