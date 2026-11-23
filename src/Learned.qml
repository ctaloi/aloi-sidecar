import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "sidecar.js" as Sidecar

// Home's other half: not what's waiting on you, but what the meetings have
// come to, taken together. How much there was and on which days; the topics
// as a map (a click opens a topic's own page), with what was said under each;
// what was decided, what's still
// open, and who it was with. All of it is what the wrap-ups already say
// (the engine counts and joins them; no model is asked).
ColumnLayout {
    id: root
    spacing: 12

    // How far back: 14 or 30 days, or 0 for everything.
    property int days: 30
    property string pinned: ""
    // Read when the numbers arrive, not off the ticking clock.
    property double asOf: Date.now()

    readonly property var info: engine.learned
    readonly property var totals: info.totals || ({})
    readonly property var topics: info.topics || []
    readonly property var links: info.links || []
    readonly property var daily: info.daily || []
    readonly property var people: info.people || []
    readonly property bool any: (totals.wrapped || 0) > 0
    readonly property bool wide: width >= 760

    function refresh() { if (engine.connected) engine.fetchLearned(days) }
    onDaysChanged: refresh()
    onVisibleChanged: if (visible) refresh()
    Component.onCompleted: refresh()
    Connections {
        target: engine
        function onConnectedChanged() { root.refresh() }
        // A wrap-up drafted or edited changes what's here; not on every line of a live call.
        function onMeetingsChanged() { if (root.visible && !later.running) later.start() }
        function onLearnedChanged() {
            root.asOf = Date.now()
            if (root.pinned !== "" && !root.topics.some(t => t.name === root.pinned)) root.pinned = ""
        }
    }
    Timer { id: later; interval: 4000; onTriggered: root.refresh() }

    function n(value) { return Number(value || 0).toLocaleString(Qt.locale(), 'f', 0) }
    function span(minutes) {
        const m = Math.round(minutes || 0)
        if (m < 60) return m + "m"
        return m < 600 ? Math.floor(m / 60) + "h " + (m % 60 < 10 ? "0" : "") + m % 60 + "m" : Math.round(m / 60) + "h"
    }
    function when(t) { return Sidecar.when(t, asOf) }
    function topic(name) { return topics.find(t => t.name === name) || null }
    function open(item) { win.openFrom(item.meeting || item.id, item.at === undefined ? -1 : item.at) }

    // The name, how far back, and the choice of how far.
    RowLayout {
        Layout.fillWidth: true
        spacing: 10
        Label {
            text: qsTr("What we've learned")
            color: ui.text
            font.pixelSize: 14
            font.bold: true
        }
        Label {
            Layout.fillWidth: true
            text: !root.any ? ""
                : root.days === 0 ? qsTr("from %n wrap-ups, all of them", "", root.totals.wrapped)
                : qsTr("from %n wrap-ups", "", root.totals.wrapped) + " " + qsTr("in the last %n days", "", root.days)
            color: ui.faint
            font.pixelSize: 11
            elide: Text.ElideRight
        }
        Row {
            spacing: 2
            Repeater {
                model: [{ d: 14, label: qsTr("2 weeks") }, { d: 30, label: qsTr("30 days") }, { d: 0, label: qsTr("All") }]
                Rectangle {
                    id: choice
                    required property var modelData
                    readonly property bool on: root.days === modelData.d
                    width: choiceLabel.implicitWidth + 16
                    height: 22
                    radius: Math.min(4, theme.radius)
                    color: on ? ui.raised : choiceHover.hovered ? ui.hover : "transparent"
                    border.color: on ? ui.line : "transparent"
                    Label {
                        id: choiceLabel
                        anchors.centerIn: parent
                        text: choice.modelData.label
                        color: choice.on ? ui.text : ui.muted
                        font.pixelSize: 11
                        font.bold: choice.on
                    }
                    HoverHandler { id: choiceHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.days = choice.modelData.d }
                }
            }
        }
    }

    Label {
        Layout.fillWidth: true
        visible: !root.any
        text: (root.totals.meetings || 0) > 0
              ? qsTr("Nothing from this stretch has a wrap-up yet. What a meeting came to shows here once it's drafted.")
              : qsTr("No meetings in this stretch. What they come to, taken together, shows here.")
        color: ui.muted
        font.pixelSize: 12
        wrapMode: Text.Wrap
    }

    // How much there was, and on which days.
    Rectangle {
        Layout.fillWidth: true
        visible: root.any
        implicitHeight: pulse.implicitHeight + 28
        radius: theme.radius
        color: ui.panel
        border.color: ui.line
        ColumnLayout {
            id: pulse
            x: 16; y: 14
            width: parent.width - 32
            spacing: 14
            GridLayout {
                Layout.fillWidth: true
                columns: root.width >= 860 ? 6 : 3
                columnSpacing: 12
                rowSpacing: 12
                Stat { value: root.n(root.totals.meetings); label: qsTr("meetings") }
                Stat { value: root.span(root.totals.minutes); label: qsTr("in them") }
                Stat { value: root.n(root.totals.topics); label: qsTr("topics") }
                Stat { value: root.n(root.totals.decisions); label: qsTr("decisions"); tone: ui.them }
                Stat { value: root.n(root.totals.questions); label: qsTr("left open"); tone: ui.hot }
                Stat {
                    value: root.n(root.totals.done) + " / " + root.n(root.totals.followups)
                    label: qsTr("follow-ups done")
                    tone: theme.accent
                }
            }
            // A bar a day, as tall as the time spent in meetings.
            Item {
                id: strip
                Layout.fillWidth: true
                implicitHeight: 64
                readonly property int count: root.daily.length
                readonly property real slot: count > 0 ? width / count : 0
                readonly property real most: root.daily.reduce((a, d) => Math.max(a, d.minutes), 1)
                // Mondays named, as many as there's room for.
                readonly property int stride: Math.max(1, Math.ceil(70 / Math.max(1, slot * 7)))
                Repeater {
                    model: root.daily
                    Item {
                        id: dayBar
                        required property var modelData
                        required property int index
                        readonly property bool today: index === strip.count - 1
                        x: index * strip.slot
                        width: strip.slot
                        height: strip.height
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: 46 - height
                            width: Math.max(2, Math.min(18, parent.width - (parent.width > 8 ? 3 : 1)))
                            height: dayBar.modelData.meetings > 0 ? Math.max(3, 44 * dayBar.modelData.minutes / strip.most) : 2
                            radius: Math.min(2, theme.radius)
                            color: dayBar.modelData.meetings === 0 ? ui.line
                                 : dayBar.today || dayHover.hovered ? theme.accent : ui.alpha(theme.accent, 0.5)
                        }
                        Label {
                            // Every stride-th Monday, counted back from today's week.
                            visible: dayBar.modelData.weekday === 0
                                     && Math.floor((strip.count - 1 - dayBar.index) / 7) % strip.stride === 0
                            y: 51
                            text: new Date(dayBar.modelData.t * 1000).toLocaleDateString(Qt.locale(), "d MMM")
                            color: ui.faint
                            font.pixelSize: 10
                        }
                        HoverHandler { id: dayHover }
                        ToolTip.visible: dayHover.hovered
                        ToolTip.delay: 200
                        ToolTip.text: new Date(dayBar.modelData.t * 1000).toLocaleDateString(Qt.locale(), "ddd d MMM") + "  ·  "
                                      + (dayBar.modelData.meetings === 0 ? qsTr("no meetings")
                                         : qsTr("%n meetings", "", dayBar.modelData.meetings) + ", " + root.span(dayBar.modelData.minutes))
                    }
                }
            }
        }
    }

    // The topics as a map, and beside it what was said: lately, or under
    // the topic pointed at.
    Rectangle {
        id: mapCard
        Layout.fillWidth: true
        visible: root.any && root.topics.length > 0
        implicitHeight: root.wide ? 520 : 380 + side.implicitHeight + 28
        radius: theme.radius
        color: ui.panel
        border.color: ui.line
        clip: true

        readonly property real sideWidth: root.wide ? Math.min(360, width * 0.38) : width
        // The topic last pointed at stays beside the map, so what's said
        // under it can be reached. Narrow, that would make the page jump:
        // there a topic is only opened.
        readonly property var shown: root.wide ? root.topic(topicMap.active) : null

        TopicMap {
            id: topicMap
            x: 8; y: 8
            width: (root.wide ? parent.width - mapCard.sideWidth : parent.width) - 16
            height: (root.wide ? parent.height : 380) - 16 - 22
            all: root.topics
            links: root.links
            pinned: root.pinned
            onPointed: name => root.pinned = name
            onOpened: name => win.openTopic(name)
        }
        // How to read it.
        Row {
            x: 16
            y: topicMap.y + topicMap.height + 4
            spacing: 6
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 8; height: 8; radius: 4
                color: theme.accent
            }
            Label { text: qsTr("this week"); color: ui.faint; font.pixelSize: 10 }
            Item { width: 6; height: 1 }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 8; height: 8; radius: 4
                color: Qt.tint(ui.panel, ui.alpha(ui.muted, 0.30))
                border.color: ui.alpha(ui.muted, 0.7)
            }
            Label { text: qsTr("earlier"); color: ui.faint; font.pixelSize: 10 }
            Label {
                visible: topicMap.width > 600
                text: "  ·  " + qsTr("bigger: more meetings  ·  joined: come up together  ·  click opens one")
                color: ui.faint
                font.pixelSize: 10
            }
        }
        Rectangle {
            x: root.wide ? parent.width - mapCard.sideWidth : 16
            y: root.wide ? 1 : 380
            width: root.wide ? 1 : parent.width - 32
            height: root.wide ? parent.height - 2 : 1
            color: ui.line
        }

        ColumnLayout {
            id: side
            x: (root.wide ? parent.width - mapCard.sideWidth : 0) + 18
            y: (root.wide ? 0 : 380) + 14
            width: mapCard.sideWidth - 36
            spacing: 6

            // Nothing pointed at: the last few conversations and what they came to.
            Heading { visible: !mapCard.shown; text: qsTr("Lately") }
            Repeater {
                model: mapCard.shown ? [] : (root.info.recent || []).slice(0, 4)
                ColumnLayout {
                    id: talk
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.bottomMargin: 6
                    spacing: 2
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Label {
                            Layout.fillWidth: true
                            text: talk.modelData.title || qsTr("Untitled")
                            color: talkHover.hovered ? theme.accent : ui.text
                            font.pixelSize: 12
                            font.bold: true
                            elide: Text.ElideRight
                        }
                        Label {
                            text: root.when(talk.modelData.started) + "  ·  " + root.span(talk.modelData.minutes)
                            color: ui.faint
                            font.pixelSize: 10
                        }
                    }
                    Label {
                        Layout.fillWidth: true
                        text: talk.modelData.tldr
                        textFormat: Text.PlainText
                        color: ui.muted
                        font.pixelSize: 11
                        lineHeight: 1.25
                        wrapMode: Text.Wrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                    }
                    HoverHandler { id: talkHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.open(talk.modelData) }
                }
            }

            // A topic: how much, what it goes with, and what was said under it.
            RowLayout {
                Layout.fillWidth: true
                visible: !!mapCard.shown
                spacing: 8
                Label {
                    Layout.fillWidth: true
                    text: mapCard.shown ? mapCard.shown.name : ""
                    color: ui.text
                    font.pixelSize: 16
                    font.bold: true
                    elide: Text.ElideRight
                }
                Label {
                    text: qsTr("Open") + "  ›"
                    color: openHover.hovered ? ui.text : theme.accent
                    font.pixelSize: 11
                    font.bold: true
                    HoverHandler { id: openHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: if (mapCard.shown) win.openTopic(mapCard.shown.name) }
                }
            }
            Label {
                Layout.fillWidth: true
                visible: !!mapCard.shown
                text: mapCard.shown ? [qsTr("%n meetings", "", mapCard.shown.count), root.span(mapCard.shown.minutes),
                                       qsTr("last %1").arg(root.when(mapCard.shown.last))].join("  ·  ") : ""
                color: ui.muted
                font.pixelSize: 11
                elide: Text.ElideRight
            }
            Flow {
                id: goesWith
                Layout.fillWidth: true
                Layout.topMargin: 2
                readonly property var names: mapCard.shown
                    ? root.links.filter(l => l.a === mapCard.shown.name || l.b === mapCard.shown.name)
                          .map(l => l.a === mapCard.shown.name ? l.b : l.a).slice(0, 5) : []
                visible: names.length > 0
                spacing: 6
                Label { text: qsTr("with"); color: ui.faint; font.pixelSize: 11; height: 20; verticalAlignment: Text.AlignVCenter }
                Repeater {
                    model: goesWith.names
                    Rectangle {
                        id: other
                        required property string modelData
                        width: otherLabel.implicitWidth + 14
                        height: 20
                        radius: 10
                        color: otherHover.hovered ? ui.alpha(theme.accent, 0.18) : ui.raised
                        border.color: otherHover.hovered ? theme.accent : ui.line
                        Label {
                            id: otherLabel
                            anchors.centerIn: parent
                            text: other.modelData
                            color: ui.text
                            font.pixelSize: 10
                        }
                        HoverHandler { id: otherHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: root.pinned = other.modelData }
                    }
                }
            }
            Heading { visible: threads.count > 0; text: qsTr("Came up") }
            Repeater {
                id: threads
                model: mapCard.shown ? mapCard.shown.threads.slice(0, 3) : []
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
            Heading { visible: decided.count > 0; text: qsTr("Decided"); tone: ui.them }
            Repeater {
                id: decided
                model: mapCard.shown ? mapCard.shown.decisions.slice(0, 2) : []
                Said { required property var modelData; item: modelData }
            }
            Heading { visible: asked.count > 0; text: qsTr("Still open"); tone: ui.hot }
            Repeater {
                id: asked
                model: mapCard.shown ? mapCard.shown.questions.slice(0, 2) : []
                Said { required property var modelData; item: modelData }
            }
            Heading { visible: held.count > 0; text: qsTr("Meetings") }
            Repeater {
                id: held
                model: mapCard.shown ? mapCard.shown.meetings.slice(0, 3) : []
                RowLayout {
                    id: heldRow
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 8
                    Label {
                        Layout.fillWidth: true
                        text: heldRow.modelData.title || qsTr("Untitled")
                        color: heldHover.hovered ? theme.accent : ui.text
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                    Label { text: root.when(heldRow.modelData.started); color: ui.faint; font.pixelSize: 10 }
                    HoverHandler { id: heldHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.open(heldRow.modelData) }
                }
            }
        }
    }

    // What was decided and what's still open, newest first, and who it was with.
    GridLayout {
        Layout.fillWidth: true
        visible: root.any
        columns: root.wide ? 2 : 1
        columnSpacing: 12
        rowSpacing: 12
        Ledger {
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            Layout.alignment: Qt.AlignTop
            visible: items.length > 0
            title: qsTr("Decided lately")
            total: root.totals.decisions || 0
            tone: ui.them
            items: root.info.decisions || []
            asOf: root.asOf
            onPicked: item => root.open(item)
        }
        Ledger {
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            Layout.alignment: Qt.AlignTop
            visible: items.length > 0
            title: qsTr("Still open")
            total: root.totals.questions || 0
            tone: ui.hot
            items: root.info.questions || []
            asOf: root.asOf
            onPicked: item => root.open(item)
        }
    }

    Rectangle {
        Layout.fillWidth: true
        visible: root.any && root.people.length > 1
        implicitHeight: who.implicitHeight + 26
        radius: theme.radius
        color: ui.panel
        border.color: ui.line
        ColumnLayout {
            id: who
            x: 16; y: 12
            width: parent.width - 32
            spacing: 8
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Label { text: qsTr("Who it was with"); color: ui.text; font.pixelSize: 12; font.bold: true }
                Label {
                    Layout.fillWidth: true
                    text: qsTr("%n people on the invites", "", root.totals.people || 0)
                    color: ui.faint
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }
            GridLayout {
                Layout.fillWidth: true
                columns: root.wide ? 2 : 1
                columnSpacing: 28
                rowSpacing: 6
                Repeater {
                    model: root.people
                    RowLayout {
                        id: person
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        spacing: 10
                        Label {
                            Layout.preferredWidth: 150
                            text: person.modelData.name
                            color: ui.text
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                        Item {
                            Layout.fillWidth: true
                            implicitHeight: 6
                            Rectangle {
                                width: parent.width * person.modelData.count / Math.max(1, root.people[0].count)
                                height: parent.height
                                radius: Math.min(3, theme.radius)
                                color: ui.alpha(ui.them, 0.7)
                            }
                        }
                        Label {
                            Layout.preferredWidth: 22
                            text: person.modelData.count
                            color: ui.muted
                            font.pixelSize: 11
                            horizontalAlignment: Text.AlignRight
                        }
                    }
                }
            }
        }
    }

    // A number and what it counts.
    component Stat: Column {
        property string value
        property string label
        property color tone: ui.text
        Layout.fillWidth: true
        Layout.preferredWidth: 1
        spacing: 1
        Label {
            text: parent.value
            color: parent.tone
            font.pixelSize: 22
            font.bold: true
        }
        Label { text: parent.label; color: ui.muted; font.pixelSize: 11 }
    }

    // A small heading inside a card.
    component Heading: Label {
        property color tone: ui.faint
        Layout.fillWidth: true
        Layout.topMargin: 8
        color: tone
        font.pixelSize: 10
        font.bold: true
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 1.2
    }

    // Something said in a meeting: two lines of it, and it opens at that moment.
    component Said: Label {
        property var item: ({})
        Layout.fillWidth: true
        text: item.text || ""
        textFormat: Text.PlainText
        color: saidHover.hovered ? theme.accent : ui.text
        font.pixelSize: 11
        lineHeight: 1.2
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
        HoverHandler { id: saidHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: root.open(parent.item) }
    }
}
