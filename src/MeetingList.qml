import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "sidecar.js" as Sidecar

// Every meeting, newest first: the one going on now at the top, then
// today, yesterday, this week and earlier. Each row says what it was, when,
// and how long; the one on screen has the accent edge.
Rectangle {
    id: pane
    color: ui.window

    property string filter: ""
    property double now: Date.now()

    readonly property var groups: [
        ["now", qsTr("Now")], ["wrap", qsTr("Needs wrap-up")], ["today", qsTr("Today")], ["yesterday", qsTr("Yesterday")],
        ["week", qsTr("This week")], ["earlier", qsTr("Earlier")]
    ]
    // Two letters or more also search what was said, in every meeting; until
    // the engine answers, titles alone are matched.
    readonly property string query: filter.trim()
    readonly property bool found: query.length >= 2 && engine.searched === query
    onQueryChanged: searchTimer.restart()
    Timer { id: searchTimer; interval: 160; onTriggered: engine.search(pane.query) }
    function openFirst() {
        const r = rows.find(r => !r.header)
        if (r) win.openFrom(r.m.id, r.hits && r.hits.length ? r.hits[0].at : -1)
    }

    // Headers and rows in one list, so each group can carry its count.
    readonly property var rows: {
        if (found) {
            const out = []
            for (const r of engine.searchResults) {
                const m = engine.meetings.find(x => x.id === r.id)
                if (m) out.push({ header: false, m: m, hits: r.hits, more: r.count - r.hits.length })
            }
            if (out.length) out.unshift({ header: true, label: qsTr("Found in"), count: out.length })
            return out
        }
        const f = filter.trim().toLowerCase()
        const shown = engine.meetings.filter(m => f === "" || (m.title || "").toLowerCase().indexOf(f) >= 0)
        const out = []
        for (const [key, label] of groups) {
            const inGroup = shown.filter(m => place(m) === key)
            if (inGroup.length === 0) continue
            out.push({ header: true, label: label, count: inGroup.length })
            for (const m of inGroup) out.push({ header: false, m: m })
        }
        return out
    }
    // Recent meetings still to wrap up get a group of their own, under Now.
    function place(m) { return m.state !== "ended" ? "now" : Sidecar.needsWrapup(m, now) ? "wrap" : Sidecar.group(m, now) }
    // The meeting ids in screen order, for j / k.
    readonly property var order: rows.filter(r => !r.header).map(r => r.m.id)
    function step(delta) {
        const i = order.indexOf(engine.selected)
        const next = order[Math.max(0, Math.min(order.length - 1, (i < 0 ? 0 : i + delta)))]
        if (next) engine.select(next)
    }

    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: ui.line }

    ListView {
        id: list
        anchors.fill: parent
        anchors.rightMargin: 1
        clip: true
        model: pane.rows
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        topMargin: 6
        bottomMargin: 12

        delegate: Item {
            id: row
            required property var modelData
            required property int index
            readonly property bool header: modelData.header
            readonly property var m: modelData.m || ({})
            readonly property bool current: !header && m.id === engine.selected
            readonly property bool live: !header && m.state !== "ended"
            readonly property var hits: modelData.hits || []
            width: list.width
            height: header ? 40 : 58 + (hits.length ? hits.length * 20 + 4 + (modelData.more > 0 ? 18 : 0) : 0)

            // A group: its name in small capitals and how many are in it.
            RowLayout {
                visible: row.header
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                anchors.topMargin: 12
                Label {
                    Layout.fillWidth: true
                    text: (row.modelData.label || "").toUpperCase()
                    color: ui.muted
                    font.pixelSize: 11
                    font.letterSpacing: 1.6
                }
                Label {
                    text: row.modelData.count || ""
                    color: ui.faint
                    font.pixelSize: 11
                }
            }

            Rectangle {
                visible: !row.header
                anchors.fill: parent
                color: row.current ? ui.hover : hover.hovered ? ui.alpha(ui.hover, 0.55) : "transparent"
                Rectangle {
                    visible: row.current
                    width: 3
                    height: parent.height
                    color: theme.accent
                }
                HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: engine.select(row.m.id) }
                TapHandler {
                    acceptedButtons: Qt.RightButton
                    // The row comes on screen first, so the menu's keys act on it too.
                    onTapped: (point) => { engine.select(row.m.id); menu.show(row.m, row, point.position.x, point.position.y) }
                }

                ColumnLayout {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.leftMargin: 16
                    anchors.rightMargin: 14
                    anchors.topMargin: 10
                    spacing: 4
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Rectangle {
                            visible: row.live
                            width: 7; height: 7; radius: 3.5
                            color: row.m.state === "live" ? ui.live : ui.muted
                        }
                        Label {
                            Layout.fillWidth: true
                            text: row.m.title || ""
                            color: ui.text
                            font.pixelSize: 13
                            font.bold: row.live || row.current
                            elide: Text.ElideRight
                        }
                        Label {
                            text: Sidecar.length(row.m, pane.now)
                            color: row.live ? ui.live : ui.faint
                            font.pixelSize: 11
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        Label {
                            Layout.fillWidth: true
                            text: {
                                const g = Sidecar.group(row.m, pane.now)
                                const day = g === "week" || g === "earlier" || (pane.place(row.m) === "wrap" && g !== "today")
                                            ? Sidecar.dayLabel(row.m) + "  ·  " : ""
                                // Who it was with says more than how many lines it ran to.
                                const people = row.m.people || []
                                const with_ = people.length === 1 ? qsTr("with %1").arg(people[0])
                                            : people.length > 1 ? qsTr("with %1 +%2").arg(people[0]).arg(people.length - 1)
                                            : qsTr("%n lines", "", row.m.lines || 0)
                                return day + Sidecar.span(row.m) + "  ·  " + with_
                            }
                            color: ui.faint
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                        // Where it is after the call, in a word.
                        Label {
                            readonly property string stage: Sidecar.stage(row.m)
                            readonly property var look: ({
                                drafting: [qsTr("drafting…"), theme.accent],
                                ready: [qsTr("ready"), theme.accent],
                                draftFailed: [qsTr("draft failed"), ui.danger],
                                sending: [qsTr("sending…"), theme.accent],
                                sendFailed: [qsTr("send failed"), ui.danger],
                                sent: [qsTr("✓ Notion"), ui.them],
                                skipped: [qsTr("no wrap-up"), ui.faint]
                            })
                            visible: row.m.state === "paused" || !!look[stage]
                            text: row.m.state === "paused" ? qsTr("paused") : look[stage] ? look[stage][0] : ""
                            color: row.m.state === "paused" ? ui.muted : look[stage] ? look[stage][1] : ui.faint
                            font.pixelSize: 11
                        }
                    }
                    // Where the words were said; each opens the transcript there.
                    Item { Layout.preferredHeight: 2; visible: row.hits.length > 0 }
                    Repeater {
                        model: row.hits
                        delegate: Label {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredHeight: 20
                            verticalAlignment: Text.AlignVCenter
                            textFormat: Text.StyledText
                            elide: Text.ElideRight
                            text: "<font color='" + ui.faint + "'>" + modelData.time.slice(0, 5) + "</font>  "
                                  + pane.highlight(pane.around(modelData.text))
                            color: hitHover.hovered ? ui.text : ui.muted
                            font.pixelSize: 11
                            HoverHandler { id: hitHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: win.openFrom(row.m.id, modelData.at) }
                        }
                    }
                    Label {
                        visible: row.modelData.more > 0
                        text: qsTr("+%n more", "", row.modelData.more || 0)
                        color: ui.faint
                        font.pixelSize: 10
                    }
                }
            }
        }
    }

    // A long line cut to the part around the first word searched for.
    function around(text) {
        const w = query.toLowerCase().split(/\s+/)[0] || ""
        const i = text.toLowerCase().indexOf(w)
        return i > 30 ? "…" + text.slice(i - 24) : text
    }
    // The words searched for, in the accent; everything else escaped.
    function highlight(text) {
        const esc = t => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        const words = query.toLowerCase().split(/\s+/).filter(w => w)
        let out = "", i = 0
        const lower = text.toLowerCase()
        while (i < text.length) {
            let hit = null
            for (const w of words) if (lower.startsWith(w, i) && (!hit || w.length > hit.length)) hit = w
            if (hit) { out += "<font color='" + theme.accent + "'>" + esc(text.substr(i, hit.length)) + "</font>"; i += hit.length }
            else { out += esc(text[i]); i++ }
        }
        return out
    }

    MeetingMenu { id: menu }

    // Nothing yet, or nothing matching the search.
    Column {
        anchors.centerIn: parent
        width: parent.width - 48
        spacing: 6
        visible: pane.rows.length === 0
        Label {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: pane.filter !== "" ? qsTr("Nothing said or titled “%1”.").arg(pane.query) : qsTr("No meetings yet.")
            color: ui.muted
            font.pixelSize: 13
        }
        Label {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            visible: pane.filter === ""
            text: qsTr("Space starts one when your call does.")
            color: ui.faint
            font.pixelSize: 12
        }
    }
}
