import QtQuick
import QtQuick.Controls

// Quiet tabs with an underline that slides to the current one, as in Tix.
// Each tab is { label, count, current, keys, dot, run }: a count shows
// beside the label, a dot says something there wants a look, and the keys
// show on hover.
Item {
    id: root
    property var tabs: []

    implicitHeight: 42
    implicitWidth: row.implicitWidth + 20

    Row {
        id: row
        x: 10
        height: parent.height
        spacing: 2
        Repeater {
            model: root.tabs
            Item {
                id: tab
                required property var modelData
                readonly property bool current: !!modelData.current
                width: tabLabel.implicitWidth + 16
                height: row.height
                Row {
                    id: tabLabel
                    anchors.centerIn: parent
                    spacing: 6
                    Label {
                        anchors.verticalCenter: parent.verticalCenter
                        text: tab.modelData.label
                        color: tab.current || tabHover.hovered ? ui.text : ui.faint
                        font.pixelSize: 13
                        font.bold: tab.current
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }
                    Label {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: (tab.modelData.count || 0) > 0
                        text: Number(tab.modelData.count || 0).toLocaleString(Qt.locale(), 'f', 0)
                        color: ui.faint
                        font.pixelSize: 11
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !!tab.modelData.dot
                        width: 6; height: 6; radius: 3
                        color: theme.accent
                    }
                }
                HoverHandler { id: tabHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: tab.modelData.run() }
                ToolTip.visible: tabHover.hovered && !!tab.modelData.keys
                ToolTip.delay: 600
                ToolTip.text: tab.modelData.keys || ""
            }
        }
    }
    // The current tab's underline slides to it.
    Rectangle {
        readonly property Item target: {
            for (let i = 0; i < row.children.length; ++i)
                if (row.children[i].current) return row.children[i]
            return null
        }
        visible: target !== null
        x: target ? row.x + target.x + 8 : 0
        width: target ? target.width - 16 : 0
        anchors.bottom: parent.bottom
        height: 2
        radius: 1
        color: theme.accent
        Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    }
}
