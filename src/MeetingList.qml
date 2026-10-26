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
        ["now", qsTr("Now")], ["today", qsTr("Today")], ["yesterday", qsTr("Yesterday")],
        ["week", qsTr("This week")], ["earlier", qsTr("Earlier")]
    ]
    // Headers and rows in one list, so each group can carry its count.
    readonly property var rows: {
        const f = filter.trim().toLowerCase()
        const shown = engine.meetings.filter(m => f === "" || (m.title || "").toLowerCase().indexOf(f) >= 0)
        const out = []
        for (const [key, label] of groups) {
            const inGroup = shown.filter(m => Sidecar.group(m, now) === key)
            if (inGroup.length === 0) continue
            out.push({ header: true, label: label, count: inGroup.length })
            for (const m of inGroup) out.push({ header: false, m: m })
        }
        return out
    }
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
            width: list.width
            height: header ? 40 : 58

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

                ColumnLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 16
                    anchors.rightMargin: 14
                    anchors.topMargin: 10
                    anchors.bottomMargin: 10
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
                                const day = g === "week" || g === "earlier" ? Sidecar.dayLabel(row.m) + "  ·  " : ""
                                return day + Sidecar.span(row.m) + "  ·  " + qsTr("%n lines", "", row.m.lines || 0)
                            }
                            color: ui.faint
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                        Label {
                            visible: !!row.m.notion
                            text: qsTr("in Notion")
                            color: ui.them
                            font.pixelSize: 11
                        }
                        Label {
                            visible: row.m.state === "paused"
                            text: qsTr("paused")
                            color: ui.muted
                            font.pixelSize: 11
                        }
                    }
                }
            }
        }
    }

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
            text: pane.filter !== "" ? qsTr("No meeting called that.") : qsTr("No meetings yet.")
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
