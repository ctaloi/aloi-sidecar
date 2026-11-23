import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Aloi
import "sidecar.js" as Sidecar

// Where Sidecar opens, as every Aloi app opens on what's waiting on you.
// One sentence: what's on, or how many meetings wait on a wrap-up. The
// week's meetings split by where each is after the call; the one on now,
// with its switches; the ones waiting on a wrap-up, newest first and folded
// to a row. Then
// what's been learned (Learned.qml): the topics as a map, what was decided
// and what's open. Then what you said you'd do, and what went to Notion
// lately.
Rectangle {
    id: root
    color: ui.window

    property double now: Date.now()

    readonly property var on: engine.current !== "" ? engine.meetingById(engine.current) : null
    // Newest first here: the ones still fresh, since not all of them get done.
    readonly property var waiting: win.waiting.slice().reverse()
    // Folded to a row of them unless asked for all.
    property bool allWaiting: false
    // The ready ones ticked to send, by id; chosen is those still sendable.
    property var picked: []
    readonly property var chosen: picked.filter(id => win.sendable.some(m => m.id === id))
    function pick(id) { picked = picked.includes(id) ? picked.filter(x => x !== id) : picked.concat([id]) }
    // The last seven days, by where each meeting is after the call.
    readonly property var week: engine.meetings.filter(m => m.state === "ended" && (m.lines || 0) > 0
                                                        && Date.now() / 1000 - m.started < 7 * 86400)
    function kind(m) {
        const s = Sidecar.stage(m)
        if (s === "sent") return "sent"
        if (s === "skipped") return "skipped"
        if (s === "drafting" || s === "sending") return "drafting"
        if (s === "ready" || s === "sendFailed") return "ready"
        return "wrap"
    }
    function count(k) { return week.filter(m => kind(m) === k).length }
    readonly property var split: [
        { k: "ready", c: count("ready"), label: qsTr("ready to check"), tone: theme.accent },
        { k: "wrap", c: count("wrap"), label: qsTr("to draft"), tone: ui.hot },
        { k: "drafting", c: count("drafting"), label: qsTr("drafting"), tone: ui.alpha(theme.accent, 0.5) },
        { k: "sent", c: count("sent"), label: qsTr("in Notion"), tone: ui.them },
        { k: "skipped", c: count("skipped"), label: qsTr("no wrap-up"), tone: ui.faint }
    ]
    // Flagged ones first, whichever meeting they came from.
    readonly property var open: {
        const o = engine.followups.filter(f => !f.done)
        return o.filter(f => f.flagged).concat(o.filter(f => !f.flagged))
    }
    readonly property var filed: engine.meetings.filter(m => Sidecar.stage(m) === "sent")
                                     .sort((a, b) => b.started - a.started).slice(0, 5)

    function n(value) { return Number(value || 0).toLocaleString(Qt.locale(), 'f', 0) }
    function people(m) {
        const p = m.people || []
        return p.length === 1 ? qsTr("with %1").arg(p[0]) : p.length > 1 ? qsTr("with %1 +%2").arg(p[0]).arg(p.length - 1) : ""
    }
    // Not by the ticking clock: a table built from this would be rebuilt every second.
    function when(m) {
        const today = Sidecar.group(m, Date.now()) === "today"
        return (today ? "" : Sidecar.dayLabel(m) + "  ·  ") + Sidecar.span(m)
    }
    function open_(m) {
        win.openFrom(m.id, -1)
        if (kind(m) === "ready") meetingPane.tab = "notes"
    }

    onVisibleChanged: if (visible) engine.fetchFollowups()
    Component.onCompleted: engine.fetchFollowups()
    Connections {
        target: engine
        function onConnectedChanged() { if (engine.connected && root.visible) engine.fetchFollowups() }
    }

    Flickable {
        id: flick
        objectName: "homeFlick"
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
            spacing: 28

            // One sentence: what's on, or what's waiting on you?
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6
                Row {
                    spacing: 8
                    Glyph { name: "home"; color: theme.accent; font.pixelSize: 13 }
                    Label {
                        text: qsTr("Today") + "  ·  " + new Date(root.now).toLocaleDateString(Qt.locale(), "dddd d MMMM")
                        color: theme.accent
                        font.pixelSize: 11
                        font.bold: true
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: 1.4
                    }
                }
                Label {
                    Layout.fillWidth: true
                    text: root.on && engine.listening ? qsTr("Listening to “%1”").arg(root.on.title || qsTr("this call"))
                        : root.on ? qsTr("“%1” is paused").arg(root.on.title || qsTr("The call"))
                        : root.waiting.length === 0 ? qsTr("Nothing is waiting on a wrap-up")
                        : qsTr("%n meetings wait on a wrap-up", "", root.waiting.length)
                    color: ui.text
                    font.pixelSize: 30
                    font.bold: true
                    wrapMode: Text.Wrap
                }
                Label {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: root.on ? qsTr("%1 in%2.  Space %3, e ends it.")
                                    .arg(Sidecar.elapsed(root.on, root.now))
                                    .arg(root.people(root.on) ? ", " + root.people(root.on) : "")
                                    .arg(engine.listening ? qsTr("pauses") : qsTr("carries on"))
                        : root.count("ready") > 0 ? qsTr("%n ready to check and send.", "", root.count("ready"))
                        : root.waiting.length > 0 ? qsTr("The oldest is from %1.").arg(Sidecar.dayLabel(win.waiting[0]))
                        : root.open.length > 0 ? qsTr("%n follow-ups still open.", "", root.open.length)
                        : engine.meetings.length === 0 ? qsTr("Space starts listening; the call becomes a meeting.") : ""
                    color: root.on && engine.listening ? ui.live : root.count("ready") > 0 ? ui.hot : ui.muted
                    font.pixelSize: 13
                    wrapMode: Text.Wrap
                }
            }

            // The week: a bar, and the counts under it as words.
            ColumnLayout {
                Layout.fillWidth: true
                visible: root.week.length > 0
                spacing: 10
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 8
                    radius: Math.min(4, theme.radius)
                    color: ui.raised
                    clip: true
                    Row {
                        anchors.fill: parent
                        Repeater {
                            model: root.split
                            Rectangle {
                                required property var modelData
                                width: parent.width * modelData.c / root.week.length
                                height: parent.height
                                color: modelData.tone
                                Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                            }
                        }
                    }
                }
                Flow {
                    Layout.fillWidth: true
                    spacing: 22
                    Repeater {
                        model: root.split.filter(x => x.c > 0)
                        Row {
                            id: legend
                            required property var modelData
                            spacing: 7
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 8; height: 8; radius: 4
                                color: legend.modelData.tone
                            }
                            Label {
                                text: root.n(legend.modelData.c)
                                color: ui.text
                                font.pixelSize: 14
                                font.bold: true
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Label {
                                text: legend.modelData.label
                                color: ui.muted
                                font.pixelSize: 12
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }
                    Label {
                        text: qsTr("%n meetings this week", "", root.week.length)
                        color: ui.faint
                        font.pixelSize: 12
                    }
                }
            }

            // The one on now, and its switches.
            ColumnLayout {
                Layout.fillWidth: true
                visible: root.on !== null
                spacing: 12
                SectionTitle {
                    Layout.fillWidth: true
                    title: qsTr("On now")
                    detail: qsTr("space pauses · m marks the moment · g n opens it")
                }
                Rectangle {
                    id: live
                    Layout.fillWidth: true
                    implicitHeight: liveColumn.implicitHeight + 28
                    radius: theme.radius
                    color: liveHover.hovered ? ui.wash(ui.live, 0.10) : ui.wash(ui.live, 0.05)
                    border.color: liveHover.hovered ? ui.live : ui.line
                    Behavior on color { ColorAnimation { duration: 120 } }
                    HoverHandler { id: liveHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: if (root.on) win.openFrom(root.on.id, -1) }
                    Rectangle {
                        y: Math.max(theme.radius, 1)
                        width: 3
                        height: parent.height - 2 * Math.max(theme.radius, 1)
                        color: engine.listening ? ui.live : ui.muted
                    }
                    ColumnLayout {
                        id: liveColumn
                        x: 18
                        y: 14
                        width: parent.width - 34
                        spacing: 8
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Rectangle {
                                width: 8; height: 8; radius: 4
                                color: engine.listening ? ui.live : ui.muted
                            }
                            Label {
                                Layout.fillWidth: true
                                text: root.on ? root.on.title || "" : ""
                                color: ui.text
                                font.pixelSize: 15
                                font.bold: true
                                elide: Text.ElideRight
                            }
                            Label {
                                text: root.on ? (engine.listening ? Sidecar.elapsed(root.on, root.now) : qsTr("Paused")) : ""
                                color: engine.listening ? ui.live : ui.muted
                                font.pixelSize: 13
                                font.bold: true
                                font.features: { "tnum": 1 }
                            }
                        }
                        Label {
                            Layout.fillWidth: true
                            text: root.on ? [Sidecar.span(root.on), root.people(root.on), qsTr("%n lines", "", root.on.lines || 0)]
                                            .filter(x => x).join("  ·  ") : ""
                            color: ui.faint
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                        RowLayout {
                            Layout.topMargin: 4
                            spacing: 8
                            KeyButton {
                                primary: true
                                glyph: engine.listening ? "pause" : "mic"
                                text: engine.listening ? qsTr("Pause") : qsTr("Resume")
                                keys: "space"
                                enabled: engine.connected
                                onClicked: engine.toggleListening()
                            }
                            KeyButton { glyph: "flag"; text: qsTr("Mark"); keys: "m"; onClicked: win.markNow() }
                            KeyButton {
                                glyph: "stop"
                                text: qsTr("End")
                                keys: "e"
                                onClicked: if (root.on) win.act("end", root.on)
                            }
                            KeyButton {
                                glyph: "spark"
                                text: qsTr("Ask AI")
                                keys: ">"
                                onClicked: {
                                    if (win.canAskLive) win.askLive()
                                    else if (root.on) { win.openFrom(root.on.id, -1); win.askAgent() }
                                }
                            }
                        }
                    }
                }
            }

            // Waiting on a wrap-up, newest first, a row of them; the rest fold away.
            // The ready ones can be ticked, to send only those.
            ColumnLayout {
                Layout.fillWidth: true
                visible: root.waiting.length > 0
                spacing: 12
                SectionTitle {
                    Layout.fillWidth: true
                    title: qsTr("Waiting on a wrap-up")
                    detail: qsTr("newest first; one drops off after a week")
                    action: engine.bulk.running ? qsTr("Sending %1 of %2").arg(Math.min((engine.bulk.done || 0) + (engine.bulk.failed || 0) + (engine.bulk.choose || []).length + 1, engine.bulk.total)).arg(engine.bulk.total)
                          : root.chosen.length > 0 ? qsTr("Send the %n ticked to Notion", "", root.chosen.length)
                          : win.sendable.length > 1 ? qsTr("Send all %n to Notion", "", win.sendable.length) : ""
                    onActionTriggered: win.act("sendAll", root.chosen.length > 0 ? { ids: root.chosen } : null)
                }
                GridLayout {
                    Layout.fillWidth: true
                    id: waitingGrid
                    columns: content.width > 860 ? 3 : 2
                    columnSpacing: 12
                    rowSpacing: 12
                    Repeater {
                        model: root.allWaiting ? root.waiting : root.waiting.slice(0, waitingGrid.columns)
                        MeetingCard {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1
                            Layout.fillHeight: true
                            m: modelData
                        }
                    }
                }
                // The rest, folded away: a line to bring them out or put them back.
                Rectangle {
                    objectName: "waitingFold"
                    Layout.fillWidth: true
                    visible: root.waiting.length > waitingGrid.columns
                    implicitHeight: 30
                    radius: theme.radius
                    color: foldHover.hovered ? ui.hover : "transparent"
                    border.color: ui.line
                    Row {
                        anchors.centerIn: parent
                        spacing: 8
                        Glyph {
                            name: root.allWaiting ? "up" : "down"
                            color: ui.muted
                            font.pixelSize: 11
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Label {
                            text: root.allWaiting ? qsTr("Fold them away")
                                : qsTr("%n more waiting", "", root.waiting.length - waitingGrid.columns) + "  ·  " + qsTr("show all")
                            color: foldHover.hovered ? ui.text : ui.muted
                            font.pixelSize: 11
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    HoverHandler { id: foldHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.allWaiting = !root.allWaiting }
                }
            }

            // What the meetings have come to, taken together.
            Learned {
                objectName: "learned"
                Layout.fillWidth: true
                Layout.topMargin: 4
                Layout.bottomMargin: 4
                visible: engine.meetings.length > 0
            }

            // What you said you'd do, newest meeting first.
            ColumnLayout {
                Layout.fillWidth: true
                visible: root.open.length > 0
                spacing: 10
                SectionTitle {
                    Layout.fillWidth: true
                    title: qsTr("Follow-ups")
                    detail: qsTr("what you said you'd do, newest meeting first")
                    action: root.open.length > 6 ? qsTr("All %1  ·  g f").arg(root.open.length) : qsTr("All  ·  g f")
                    onActionTriggered: win.showScope("followups")
                }
                Table {
                    Layout.fillWidth: true
                    rows: root.open.slice(0, 6).map(f => ({
                        mark: "followups", tone: theme.accent, text: f.text, detail: f.title || "",
                        right: f.due || "", rightTone: theme.accent, run: () => win.openFrom(f.meeting, f.at === undefined ? -1 : f.at),
                        check: () => {
                            engine.setFollowupDone(f.meeting, f.index, true)
                            toast.show(qsTr("Done. It's under Follow-ups › Done (g f)."))
                        }
                    }))
                }
            }

            // Filed lately: what's already in Notion.
            ColumnLayout {
                Layout.fillWidth: true
                visible: root.filed.length > 0
                spacing: 10
                SectionTitle {
                    Layout.fillWidth: true
                    title: qsTr("In Notion")
                    detail: qsTr("filed lately")
                }
                Table {
                    Layout.fillWidth: true
                    rows: root.filed.map(m => ({
                        mark: "check", tone: ui.them, text: m.title || qsTr("Untitled"), detail: root.people(m),
                        right: root.when(m), rightTone: ui.faint, run: () => win.openFrom(m.id, -1)
                    }))
                }
            }

            // Nothing at all yet.
            ColumnLayout {
                Layout.fillWidth: true
                visible: engine.meetings.length === 0 && engine.connected
                spacing: 8
                Label {
                    Layout.fillWidth: true
                    text: qsTr("No meetings yet. Space listens; a call that uses the mic is noticed by itself.")
                    color: ui.muted
                    font.pixelSize: 13
                    wrapMode: Text.Wrap
                }
            }
        }
    }

    // A meeting waiting on its wrap-up: where it stands, what it was, when,
    // and with whom. A bar down the leading edge says how far it's got.
    component MeetingCard: Rectangle {
        id: card
        property var m: ({})
        readonly property string k: root.kind(m)
        readonly property color tone: k === "ready" ? theme.accent : k === "drafting" ? ui.muted : ui.hot
        implicitHeight: cardColumn.implicitHeight + 26
        radius: theme.radius
        // Ready, or part way into Notion: it can be ticked to send with others.
        readonly property bool sendable: win.sendable.some(o => o.id === m.id)
        readonly property bool ticked: sendable && root.picked.includes(m.id)
        // Where it is in a send of several: on its way now, or still in line.
        readonly property bool going: Sidecar.stage(m) === "sending" || (!!engine.bulk.running && engine.bulk.current === m.id)
        readonly property bool queued: !going && !!engine.bulk.running && (engine.bulk.ids || []).includes(m.id)
                                       && !(engine.bulk.sent || []).includes(m.id) && sendable
        color: cardHover.hovered || ticked ? ui.wash(tone, 0.10) : ui.wash(tone, 0.04)
        border.color: cardHover.hovered || ticked ? tone : ui.line
        Behavior on color { ColorAnimation { duration: 120 } }

        HoverHandler { id: cardHover; cursorShape: Qt.PointingHandCursor }
        // A MouseArea, not a TapHandler, so the tick box's own takes the
        // click and the card doesn't open as well.
        MouseArea { anchors.fill: parent; onClicked: root.open_(card.m) }

        Rectangle {
            y: Math.max(theme.radius, 1)
            width: 3
            height: parent.height - 2 * Math.max(theme.radius, 1)
            color: card.tone
        }

        ColumnLayout {
            id: cardColumn
            x: 16
            y: 13
            width: parent.width - 30
            spacing: 6
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: card.going ? qsTr("Sending to Notion…")
                        : card.queued ? qsTr("Queued to send")
                        : Sidecar.stage(card.m) === "sendFailed" ? qsTr("Send failed")
                        : (engine.bulk.choose || []).includes(card.m.id) && card.k === "ready" ? qsTr("Pick a page")
                        : card.k === "ready" ? (card.m.edited ? qsTr("Wrap-up edited") : qsTr("Wrap-up ready"))
                        : card.k === "drafting" ? qsTr("Drafting…")
                        : Sidecar.stage(card.m) === "draftFailed" ? qsTr("Draft failed") : qsTr("Needs a wrap-up")
                    color: ["draftFailed", "sendFailed"].includes(Sidecar.stage(card.m)) ? ui.danger : card.tone
                    font.pixelSize: 11
                    font.bold: card.k === "ready"
                }
                Item { Layout.fillWidth: true }
                Label {
                    text: Sidecar.length(card.m, root.now)
                    color: ui.muted
                    font.pixelSize: 11
                }
                Rectangle {
                    objectName: "pickToSend"
                    visible: card.sendable && !engine.bulk.running
                    width: 16; height: 16
                    radius: Math.min(3, theme.radius)
                    color: card.ticked ? theme.accent : pickHover.hovered ? ui.wash(theme.accent, 0.18) : "transparent"
                    border.color: card.ticked || pickHover.hovered ? theme.accent : ui.muted
                    Glyph {
                        anchors.centerIn: parent
                        visible: card.ticked
                        name: "check"
                        color: theme.background
                        font.pixelSize: 11
                    }
                    HoverHandler { id: pickHover }
                    ToolTip.visible: pickHover.hovered
                    ToolTip.delay: 500
                    ToolTip.text: card.ticked ? qsTr("Leave it out") : qsTr("Tick to send with others")
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -7
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.pick(card.m.id)
                    }
                }
            }
            Label {
                Layout.fillWidth: true
                text: card.m.title || qsTr("Untitled")
                color: ui.text
                font.pixelSize: 13
                font.bold: true
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }
            Label {
                Layout.fillWidth: true
                text: [root.when(card.m), root.people(card.m)].filter(x => x).join("  ·  ")
                color: ui.faint
                font.pixelSize: 11
                elide: Text.ElideRight
            }
        }
    }

    // A quiet table, a row apiece: a mark, the words, a word on where it's
    // from, and a word on the right. Each row opens what it's about.
    component Table: Rectangle {
        id: table
        property var rows: []
        implicitHeight: tableColumn.implicitHeight
        radius: theme.radius
        color: ui.panel
        border.color: ui.line
        clip: true
        Column {
            id: tableColumn
            width: parent.width
            topPadding: 4
            bottomPadding: 4
            Repeater {
                model: table.rows
                Rectangle {
                    id: line
                    required property var modelData
                    required property int index
                    width: tableColumn.width
                    height: 38
                    color: lineHover.hovered ? ui.hover : "transparent"
                    Rectangle {
                        visible: line.index > 0
                        x: 16
                        width: parent.width - 32
                        height: 1
                        color: ui.line
                        opacity: 0.5
                    }
                    HoverHandler { id: lineHover; cursorShape: Qt.PointingHandCursor }
                    // A MouseArea, not a TapHandler, so the tick box's own
                    // takes the click and the row doesn't open as well.
                    MouseArea { anchors.fill: parent; onClicked: line.modelData.run() }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 16
                        spacing: 10
                        Glyph {
                            visible: !line.modelData.check
                            name: line.modelData.mark
                            color: line.modelData.tone
                            font.pixelSize: 13
                        }
                        // A row that can be done: ticking it checks it off.
                        Rectangle {
                            objectName: "markDone"
                            visible: !!line.modelData.check
                            width: 16; height: 16
                            radius: Math.min(3, theme.radius)
                            color: tickHover.hovered ? ui.wash(theme.accent, 0.18) : "transparent"
                            border.color: tickHover.hovered ? theme.accent : ui.muted
                            HoverHandler { id: tickHover }
                            ToolTip.visible: tickHover.hovered
                            ToolTip.delay: 500
                            ToolTip.text: qsTr("Mark done")
                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -6
                                cursorShape: Qt.PointingHandCursor
                                onClicked: line.modelData.check()
                            }
                        }
                        Label {
                            text: line.modelData.text
                            color: ui.text
                            font.pixelSize: 12
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                            Layout.maximumWidth: implicitWidth
                        }
                        Label {
                            text: line.modelData.detail
                            color: ui.faint
                            font.pixelSize: 11
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                        Label {
                            text: line.modelData.right
                            color: line.modelData.rightTone
                            font.pixelSize: 11
                        }
                    }
                }
            }
        }
    }
}
