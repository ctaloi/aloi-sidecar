import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// The one bar: the app, whether it's listening (the thing that must never
// be in doubt) and what each input hears, search, settings, and the keys.
Rectangle {
    id: bar
    implicitHeight: 46
    color: ui.window

    property alias search: field
    signal toggleList()

    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: ui.line }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 14
        spacing: 18

        // The mark: the logo, whose wave moves while listening, and the name
        // in the Omarchy way.
        Row {
            spacing: 10
            Logo { size: 26; anchors.verticalCenter: parent.verticalCenter; running: engine.listening }
            Label {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.StyledText
                text: "<font color='" + ui.faint + "'>aloi</font> sidecar"
                color: ui.text
                font.pixelSize: 15
                font.bold: true
            }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: bar.toggleList() }
        }

        // Meetings, or every follow-up across them.
        UnderlineTabs {
            Layout.fillHeight: true
            visible: bar.width > 900
            tabs: [
                { label: qsTr("Meetings"), current: win.view === "meetings", keys: "F", run: () => win.view = "meetings" },
                { label: qsTr("Follow-ups"), count: engine.followupsOpen, current: win.view === "followups", keys: "F", run: () => win.view = "followups" }
            ]
        }

        // Listening, paused or offline, and the switch for it.
        Rectangle {
            id: pill
            implicitWidth: pillRow.implicitWidth + 22
            implicitHeight: 30
            radius: Math.min(4, theme.radius)
            color: engine.listening ? ui.alpha(ui.live, pillHover.hovered ? 0.26 : 0.16)
                                    : (pillHover.hovered ? ui.hover : "transparent")
            border.color: engine.listening ? ui.alpha(ui.live, 0.7) : !engine.connected ? ui.alpha(ui.danger, 0.6) : ui.line
            Row {
                id: pillRow
                anchors.centerIn: parent
                spacing: 9
                Rectangle {
                    id: dot
                    anchors.verticalCenter: parent.verticalCenter
                    width: 9; height: 9; radius: 4.5
                    color: engine.listening ? ui.live : engine.connected ? ui.muted : ui.faint
                    SequentialAnimation on opacity {
                        running: engine.listening
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.3; duration: 900; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
                    }
                    Connections {
                        target: engine
                        function onStateChanged() { if (!engine.listening) dot.opacity = 1 }
                    }
                }
                Label {
                    anchors.verticalCenter: parent.verticalCenter
                    text: !engine.connected ? qsTr("Engine offline")
                        : engine.listening ? qsTr("Listening")
                        : engine.current !== "" ? qsTr("Paused") : qsTr("Not listening")
                    color: engine.connected ? ui.text : ui.danger
                    font.pixelSize: 13
                    font.bold: engine.listening
                }
                // What each input hears, as a thin bar apiece: the mic, the
                // laptop, each display. The tooltip names them.
                Row {
                    visible: engine.listening
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 3
                    Repeater {
                        model: engine.channels
                        delegate: Rectangle {
                            required property var modelData
                            width: 3; height: 14
                            radius: 1
                            color: ui.alpha(ui.text, 0.12)
                            opacity: modelData.alive ? 1 : 0.35
                            Rectangle {
                                anchors.bottom: parent.bottom
                                width: parent.width
                                radius: 1
                                height: Math.max(2, Math.min(parent.height, Math.sqrt(modelData.level) * parent.height * 3))
                                color: modelData.speaker === "Them" ? ui.them : ui.me
                                Behavior on height { NumberAnimation { duration: 120 } }
                            }
                        }
                    }
                }
                KeyCap { text: "space"; visible: engine.connected; anchors.verticalCenter: parent.verticalCenter }
            }
            HoverHandler { id: pillHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: engine.toggleListening() }
            ToolTip.visible: pillHover.hovered
            ToolTip.delay: 500
            ToolTip.text: !engine.connected ? (engine.error || qsTr("The engine isn't running"))
                : engine.listening ? engine.channels.map(c => c.label + (c.alive ? "" : " " + qsTr("(gone)"))).join(" · ")
                : qsTr("Space listens")
        }

        Item { Layout.fillWidth: true }

        // Search the meetings by title.
        Rectangle {
            implicitWidth: Math.min(260, bar.width * 0.2)
            implicitHeight: 30
            radius: Math.min(4, theme.radius)
            color: "transparent"
            border.color: field.activeFocus ? theme.accent : ui.line
            visible: bar.width > 820
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 8
                spacing: 8
                Label { text: "⌕"; color: ui.faint; font.pixelSize: 14 }
                TextInput {
                    id: field
                    objectName: "search"
                    Layout.fillWidth: true
                    color: ui.text
                    font.pixelSize: 12
                    clip: true
                    selectByMouse: true
                    Keys.onEscapePressed: { text = ""; focus = false }
                    Label {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: field.text === ""
                        text: qsTr("Search what was said")
                        color: ui.faint
                        font.pixelSize: 12
                    }
                }
                KeyCap { text: "ctrl+F"; visible: !field.activeFocus }
            }
        }

        // Sidecar's own settings, few on purpose.
        ActionButton {
            id: settingsButton
            menu: true
            implicitHeight: 30
            tip: qsTr("Settings")
            onClicked: settingsMenu.popup(settingsButton, settingsButton.width - 300, settingsButton.height + 6)
            SideMenu {
                id: settingsMenu
                MenuRow {
                    text: qsTr("Record calls by itself when an app uses the mic")
                    setting: true
                    on: engine.settings.watch_calls !== false
                    onTriggered: engine.setSetting("watch_calls", !(engine.settings.watch_calls !== false))
                }
                MenuRow {
                    text: qsTr("Offer to listen before calendar meetings")
                    setting: true
                    on: engine.settings.calendar_offers !== false
                    onTriggered: engine.setSetting("calendar_offers", !(engine.settings.calendar_offers !== false))
                }
                MenuRow {
                    text: qsTr("Live takeaways during calls (Haiku)")
                    setting: true
                    on: engine.settings.live_takeaways !== false
                    onTriggered: engine.setSetting("live_takeaways", !(engine.settings.live_takeaways !== false))
                }
                MenuRow {
                    text: qsTr("End after a long silence")
                    setting: true
                    on: engine.settings.stop_on_silence !== false
                    onTriggered: engine.setSetting("stop_on_silence", !(engine.settings.stop_on_silence !== false))
                }
                MenuLine {}
                MenuRow { text: qsTr("Show the meetings folder"); onTriggered: Qt.openUrlExternally("file://" + engine.meetingFolder("")) }
                MenuRow { text: qsTr("Show the trash folder"); onTriggered: Qt.openUrlExternally("file://" + engine.meetingFolder("").replace(/meetings\/$/, "trash")) }
            }
        }

        KeyCap {
            text: "?"
            tone: keysHover.hovered ? ui.text : ui.faint
            implicitWidth: 22; implicitHeight: 22
            HoverHandler { id: keysHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: keys.open() }
            ToolTip.visible: keysHover.hovered
            ToolTip.delay: 400
            ToolTip.text: qsTr("Every key")
        }
    }
}
