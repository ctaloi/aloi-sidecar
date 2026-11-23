import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Aloi
import "sidecar.js" as Sidecar

// A topic's own page, from Home's map: everything on file under it, all
// the way back. How much there's been and what it comes up with (each of
// those opens in turn); every meeting, newest first, with what it came to
// and what came up in it (a click opens its notes; esc comes back here);
// and beside them what was decided, what's still open, and what was
// promised either way.
Rectangle {
    id: root
    color: ui.window

    readonly property var t: engine.topic
    readonly property bool loaded: (t.count || 0) > 0
    readonly property var meetings: t.meetings || []
    readonly property var mine: (t.mine || []).filter(i => !i.done)
    readonly property bool wide: content.width >= 820
    property double asOf: Date.now()

    onVisibleChanged: if (visible && win.topicName !== "") { asOf = Date.now(); engine.fetchTopic(win.topicName) }
    Connections {
        target: engine
        function onTopicChanged() { flick.contentY = 0 }
    }

    function span(minutes) {
        const m = Math.round(minutes || 0)
        if (m < 60) return m + "m"
        return m < 600 ? Math.floor(m / 60) + "h " + (m % 60 < 10 ? "0" : "") + m % 60 + "m" : Math.round(m / 60) + "h"
    }
    function day(s) { return new Date(s * 1000).toLocaleDateString(Qt.locale(), "d MMM") }
    function open(id, at) {
        win.openFrom(id, at === undefined ? -1 : at)
        if (at === undefined || at < 0) meetingPane.tab = "notes"
        win.viaTopic = true
    }

    Flickable {
        id: flick
        objectName: "topicFlick"
        anchors.fill: parent
        contentHeight: content.implicitHeight + 72
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar {}
        Kinetic { target: flick }

        ColumnLayout {
            id: content
            x: Math.max(32, (flick.width - width) / 2)
            y: 32
            width: Math.min(flick.width - 64, 1080)
            spacing: 24

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6
                Row {
                    spacing: 8
                    Label {
                        text: "‹  " + qsTr("Home")
                        color: homeHover.hovered ? ui.text : theme.accent
                        font.pixelSize: 11
                        font.bold: true
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: 1.4
                        HoverHandler { id: homeHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: win.goHome() }
                    }
                    Label {
                        text: "·  " + qsTr("Topic")
                        color: ui.faint
                        font.pixelSize: 11
                        font.bold: true
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: 1.4
                    }
                }
                Label {
                    Layout.fillWidth: true
                    text: root.t.name || ""
                    color: ui.text
                    font.pixelSize: 30
                    font.bold: true
                    wrapMode: Text.Wrap
                }
                Label {
                    Layout.fillWidth: true
                    text: root.loaded ? [qsTr("%n meetings", "", root.t.count), root.span(root.t.minutes),
                                         root.t.count > 1 ? qsTr("since %1").arg(root.day(root.t.first)) : "",
                                         qsTr("last %1").arg(Sidecar.when(root.t.last, root.asOf)),
                                         root.t.recent > 0 ? qsTr("%n this week", "", root.t.recent) : ""].filter(x => x).join("  ·  ")
                        : root.t.loading ? qsTr("Looking it up…") : qsTr("Nothing on file under this topic.")
                    color: root.loaded && root.t.recent > 0 ? theme.accent : ui.muted
                    font.pixelSize: 13
                    wrapMode: Text.Wrap
                }
            }

            // What it comes up with: each opens in turn.
            Flow {
                Layout.fillWidth: true
                visible: root.loaded && (root.t.related || []).length > 0
                spacing: 8
                Label {
                    text: qsTr("Comes up with")
                    color: ui.faint
                    font.pixelSize: 11
                    height: 26
                    verticalAlignment: Text.AlignVCenter
                }
                Repeater {
                    model: root.t.related || []
                    Rectangle {
                        id: other
                        required property var modelData
                        width: otherRow.implicitWidth + 20
                        height: 26
                        radius: 13
                        color: otherHover.hovered ? ui.alpha(theme.accent, 0.18) : ui.panel
                        border.color: otherHover.hovered ? theme.accent : ui.line
                        Row {
                            id: otherRow
                            anchors.centerIn: parent
                            spacing: 7
                            Label { text: other.modelData.name; color: ui.text; font.pixelSize: 11 }
                            Label { text: other.modelData.n; color: ui.faint; font.pixelSize: 11 }
                        }
                        HoverHandler { id: otherHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: win.openTopic(other.modelData.name) }
                    }
                }
            }

            GridLayout {
                Layout.fillWidth: true
                visible: root.loaded
                columns: root.wide ? 2 : 1
                columnSpacing: 16
                rowSpacing: 16

                // Every meeting under it, newest first.
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 3
                    Layout.alignment: Qt.AlignTop
                    spacing: 10
                    SectionTitle {
                        Layout.fillWidth: true
                        title: qsTr("Conversations")
                        detail: qsTr("newest first; one opens its notes, esc comes back")
                    }
                    Repeater {
                        model: root.meetings
                        Rectangle {
                            id: card
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: cardColumn.implicitHeight + 24
                            radius: theme.radius
                            color: cardHover.hovered ? ui.wash(theme.accent, 0.08) : ui.panel
                            border.color: cardHover.hovered ? theme.accent : ui.line
                            HoverHandler { id: cardHover; cursorShape: Qt.PointingHandCursor }
                            MouseArea { anchors.fill: parent; onClicked: root.open(card.modelData.id) }
                            ColumnLayout {
                                id: cardColumn
                                x: 16; y: 12
                                width: parent.width - 32
                                spacing: 5
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 10
                                    Label {
                                        Layout.fillWidth: true
                                        text: card.modelData.title || qsTr("Untitled")
                                        color: ui.text
                                        font.pixelSize: 13
                                        font.bold: true
                                        elide: Text.ElideRight
                                    }
                                    Label {
                                        text: Sidecar.when(card.modelData.started, root.asOf) + "  ·  " + root.span(card.modelData.minutes)
                                        color: ui.faint
                                        font.pixelSize: 11
                                    }
                                }
                                Label {
                                    Layout.fillWidth: true
                                    visible: text !== ""
                                    text: card.modelData.tldr
                                    textFormat: Text.PlainText
                                    color: ui.muted
                                    font.pixelSize: 12
                                    lineHeight: 1.25
                                    wrapMode: Text.Wrap
                                }
                                Repeater {
                                    model: card.modelData.threads.slice(0, 6)
                                    Label {
                                        required property string modelData
                                        Layout.fillWidth: true
                                        text: "·  " + modelData
                                        textFormat: Text.PlainText
                                        color: ui.text
                                        font.pixelSize: 11
                                        elide: Text.ElideRight
                                    }
                                }
                                // Its other topics: a way across to them.
                                Flow {
                                    Layout.fillWidth: true
                                    Layout.topMargin: 3
                                    visible: card.modelData.tags.length > 0
                                    spacing: 6
                                    Repeater {
                                        model: card.modelData.tags
                                        Rectangle {
                                            id: tag
                                            required property string modelData
                                            width: tagLabel.implicitWidth + 14
                                            height: 20
                                            radius: 10
                                            color: tagHover.hovered ? ui.alpha(theme.accent, 0.18) : ui.raised
                                            border.color: tagHover.hovered ? theme.accent : ui.line
                                            Label {
                                                id: tagLabel
                                                anchors.centerIn: parent
                                                text: tag.modelData
                                                color: ui.muted
                                                font.pixelSize: 10
                                            }
                                            HoverHandler { id: tagHover }
                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: win.openTopic(tag.modelData)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // What they came to, taken together.
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 2
                    Layout.alignment: Qt.AlignTop
                    spacing: 12
                    SectionTitle {
                        Layout.fillWidth: true
                        title: qsTr("What it's come to")
                        detail: qsTr("each opens at the moment")
                    }
                    Ledger {
                        Layout.fillWidth: true
                        visible: items.length > 0
                        title: qsTr("For me to do")
                        tone: theme.accent
                        items: root.mine
                        asOf: root.asOf
                        limit: 5
                        onPicked: item => root.open(item.meeting, item.at)
                    }
                    Ledger {
                        Layout.fillWidth: true
                        visible: items.length > 0
                        title: qsTr("Decided")
                        tone: ui.them
                        items: root.t.decisions || []
                        asOf: root.asOf
                        limit: 5
                        onPicked: item => root.open(item.meeting, item.at)
                    }
                    Ledger {
                        Layout.fillWidth: true
                        visible: items.length > 0
                        title: qsTr("Still open")
                        tone: ui.hot
                        items: root.t.questions || []
                        asOf: root.asOf
                        limit: 5
                        onPicked: item => root.open(item.meeting, item.at)
                    }
                    Ledger {
                        Layout.fillWidth: true
                        visible: items.length > 0
                        title: qsTr("Others said they'd")
                        tone: ui.muted
                        items: root.t.theirs || []
                        asOf: root.asOf
                        limit: 5
                        onPicked: item => root.open(item.meeting, item.at)
                    }
                    Label {
                        Layout.fillWidth: true
                        visible: (root.t.people || []).length > 0
                        text: qsTr("With") + "  " + (root.t.people || []).map(p => p.name + " (" + p.count + ")").join(",  ")
                        color: ui.faint
                        font.pixelSize: 11
                        lineHeight: 1.3
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
    }
}
