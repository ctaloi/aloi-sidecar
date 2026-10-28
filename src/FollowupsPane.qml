import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "sidecar.js" as Sidecar

// Everything Chris said he'd do, from every meeting's wrap-up, the newest
// meeting first. Ticking one off ticks it off in the wrap-up and, for
// meetings in Notion, on the page too; × removes it altogether, there too.
// Ticks and deletions made in Notion come back when this opens.
Rectangle {
    id: root
    color: ui.window

    property double now: Date.now()
    property bool showDone: false
    readonly property var all: engine.followups
    readonly property var shown: all.filter(f => showDone ? f.done : !f.done)
    readonly property int doneCount: all.filter(f => f.done).length
    // Grouped by meeting, newest first.
    readonly property var groups: {
        const out = []
        for (const f of shown) {
            if (!out.length || out[out.length - 1].meeting !== f.meeting)
                out.push({ meeting: f.meeting, title: f.title, started: f.started, items: [] })
            out[out.length - 1].items.push(f)
        }
        return out
    }
    signal openMeeting(string id, int at)

    function remove(f) {
        if (!f.inNotion) { engine.removeFollowup(f.meeting, f.index); return }
        confirm.ask({
            title: qsTr("Remove “%1”?").arg(f.text),
            detail: qsTr("It comes out of the wrap-up and its to-do comes off the Notion page (Notion keeps it in its trash)."),
            confirm: qsTr("Remove"),
            danger: true,
            run: () => engine.removeFollowup(f.meeting, f.index)
        })
    }

    onVisibleChanged: if (visible) { engine.fetchFollowups(); engine.syncFollowups() }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 28
            Layout.rightMargin: 20
            Layout.topMargin: 14
            spacing: 6
            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                Label {
                    text: qsTr("Follow-ups")
                    color: ui.text
                    font.pixelSize: 26
                    font.bold: true
                }
                Item { Layout.fillWidth: true }
                KeyButton {
                    implicitHeight: 30
                    text: engine.syncing ? qsTr("Checking Notion") : qsTr("Check Notion")
                    busy: engine.syncing
                    enabled: !engine.syncing
                    tip: qsTr("Bring back anything ticked off on the Notion pages")
                    onClicked: engine.syncFollowups()
                }
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: ui.faint
                font.pixelSize: 12
                text: {
                    const open = root.all.length - root.doneCount
                    const meetings = new Set(root.all.filter(f => !f.done).map(f => f.meeting)).size
                    return open === 0 ? qsTr("Nothing open. Ticks sync with Notion.")
                                      : qsTr("%n open", "", open) + " " + qsTr("from %n meetings", "", meetings) + " · " + qsTr("ticks sync with Notion")
                }
            }
            UnderlineTabs {
                Layout.leftMargin: -10
                Layout.topMargin: 6
                tabs: [
                    { label: qsTr("Open"), count: root.all.length - root.doneCount, current: !root.showDone, run: () => root.showDone = false },
                    { label: qsTr("Done"), count: root.doneCount, current: root.showDone, run: () => root.showDone = true }
                ]
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: ui.line }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            topMargin: 10
            bottomMargin: 24
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            model: root.groups
            spacing: 6

            delegate: Column {
                id: group
                required property var modelData
                width: list.width
                bottomPadding: 10

                // The meeting the follow-ups came from; click to open it.
                Item {
                    width: parent.width
                    height: 40
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 32
                        anchors.rightMargin: 32
                        anchors.topMargin: 12
                        spacing: 10
                        Label {
                            text: group.modelData.title
                            color: titleHover.hovered ? theme.accent : ui.muted
                            font.pixelSize: 12
                            font.bold: true
                            elide: Text.ElideRight
                            Layout.maximumWidth: parent.width * 0.6
                            HoverHandler { id: titleHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: root.openMeeting(group.modelData.meeting, -1) }
                        }
                        Label {
                            text: Sidecar.when(group.modelData.started, root.now)
                            color: ui.faint
                            font.pixelSize: 11
                        }
                        Rectangle { Layout.fillWidth: true; height: 1; color: ui.line; Layout.alignment: Qt.AlignVCenter }
                    }
                }

                Repeater {
                    model: group.modelData.items
                    delegate: Rectangle {
                        id: row
                        required property var modelData
                        width: group.width - 40
                        x: 20
                        height: rowLayout.implicitHeight + 14
                        radius: Math.min(4, theme.radius)
                        color: rowHover.hovered ? ui.alpha(ui.hover, 0.5) : "transparent"
                        HoverHandler { id: rowHover }

                        RowLayout {
                            id: rowLayout
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            spacing: 12
                            Rectangle {
                                Layout.alignment: Qt.AlignTop
                                Layout.topMargin: 2
                                width: 16; height: 16
                                radius: Math.min(3, theme.radius)
                                color: row.modelData.done ? theme.accent : "transparent"
                                border.color: row.modelData.done ? theme.accent : ui.muted
                                Text { anchors.centerIn: parent; visible: row.modelData.done; text: "✓"; color: theme.accentForeground; font.pixelSize: 11; font.bold: true }
                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -6
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: engine.setFollowupDone(row.modelData.meeting, row.modelData.index, !row.modelData.done)
                                }
                            }
                            Label {
                                Layout.fillWidth: true
                                text: row.modelData.text
                                color: row.modelData.done ? ui.faint : ui.text
                                font.pixelSize: 14
                                font.strikeout: row.modelData.done
                                wrapMode: Text.Wrap
                            }
                            Label {
                                Layout.alignment: Qt.AlignTop
                                visible: row.modelData.due !== ""
                                text: row.modelData.due
                                color: theme.accent
                                font.pixelSize: 11
                            }
                            Label {
                                Layout.alignment: Qt.AlignTop
                                visible: !!row.modelData.syncError
                                text: "!"
                                color: ui.danger
                                font.pixelSize: 13
                                font.bold: true
                                HoverHandler { id: errHover }
                                ToolTip.visible: errHover.hovered
                                ToolTip.text: qsTr("Couldn't tick it in Notion: %1").arg(row.modelData.syncError || "")
                            }
                            // Same width with or without the tag, so dues line up.
                            Item {
                                Layout.alignment: Qt.AlignTop
                                implicitWidth: notionTag.implicitWidth
                                implicitHeight: notionTag.implicitHeight
                                Chip {
                                    id: notionTag
                                    visible: row.modelData.inNotion
                                    text: qsTr("Notion")
                                    tone: ui.faint
                                    implicitHeight: 18
                                    HoverHandler { id: notionHover }
                                    ToolTip.visible: notionHover.hovered
                                    ToolTip.delay: 400
                                    ToolTip.text: qsTr("A to-do on the meeting's Notion page; ticks sync")
                                }
                            }
                            // Gone, not done.
                            Glyph {
                                Layout.alignment: Qt.AlignTop
                                name: "close"
                                opacity: rowHover.hovered ? 1 : 0
                                color: removeHover.hovered ? ui.danger : ui.faint
                                font.pixelSize: 14
                                HoverHandler { id: removeHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: root.remove(row.modelData) }
                                ToolTip.visible: removeHover.hovered
                                ToolTip.delay: 400
                                ToolTip.text: row.modelData.inNotion ? qsTr("Remove it, here and on the Notion page") : qsTr("Remove it")
                            }
                            Label {
                                Layout.alignment: Qt.AlignTop
                                text: "↗"
                                color: jumpHover.hovered ? theme.accent : ui.faint
                                font.pixelSize: 12
                                HoverHandler { id: jumpHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: root.openMeeting(row.modelData.meeting, row.modelData.at) }
                                ToolTip.visible: jumpHover.hovered
                                ToolTip.delay: 400
                                ToolTip.text: qsTr("Open the meeting where it was said")
                            }
                        }
                    }
                }
            }
        }
    }

    Column {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: 60
        width: Math.min(parent.width - 64, 420)
        spacing: 8
        visible: root.shown.length === 0
        Label {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: root.showDone ? qsTr("Nothing ticked off yet.") : qsTr("Nothing to follow up.")
            color: ui.muted
            font.pixelSize: 15
        }
        Label {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            visible: !root.showDone
            text: qsTr("When a meeting ends, what you committed to shows up here.")
            color: ui.faint
            font.pixelSize: 12
        }
    }
}
