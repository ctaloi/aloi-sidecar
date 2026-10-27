import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// The one bar: the app, whether it's listening (the thing that must never
// be in doubt), what each input hears, search, and the way into the keys.
Rectangle {
    id: bar
    implicitHeight: 52
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
            implicitHeight: 34
            radius: Math.min(4, theme.radius)
            color: engine.listening ? ui.alpha(ui.live, pillHover.hovered ? 0.26 : 0.16)
                                    : (pillHover.hovered ? ui.hover : "transparent")
            border.color: engine.listening ? ui.alpha(ui.live, 0.7) : ui.line
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
                    color: ui.text
                    font.pixelSize: 13
                    font.bold: engine.listening
                }
                KeyCap { text: "space"; visible: engine.connected; anchors.verticalCenter: parent.verticalCenter }
            }
            HoverHandler { id: pillHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: engine.toggleListening() }
        }

        // A meter per input while listening: the mic, the laptop, each display.
        Row {
            spacing: 14
            visible: engine.listening && bar.width > 1000
            Repeater {
                model: engine.channels
                delegate: Column {
                    required property var modelData
                    spacing: 4
                    opacity: modelData.alive ? 1 : 0.35
                    Label {
                        text: modelData.label
                        color: modelData.speaking ? ui.text : ui.faint
                        font.pixelSize: 10
                    }
                    Rectangle {
                        width: 52; height: 3
                        radius: 1.5
                        color: ui.raised
                        Rectangle {
                            height: parent.height
                            radius: 1.5
                            width: Math.min(parent.width, Math.sqrt(modelData.level) * parent.width * 3)
                            color: modelData.speaker === "Them" ? ui.them : ui.me
                            Behavior on width { NumberAnimation { duration: 120 } }
                        }
                    }
                }
            }
        }

        Item { Layout.fillWidth: true }

        // The engine: green when connected, red when it isn't.
        Rectangle {
            width: 8; height: 8; radius: 4
            color: engine.connected ? ui.them : ui.danger
            ToolTip.visible: dotHover.hovered
            ToolTip.text: engine.connected ? qsTr("The engine is running") : (engine.error || qsTr("The engine isn't running"))
            HoverHandler { id: dotHover }
        }

        // Search the meetings by title.
        Rectangle {
            implicitWidth: Math.min(260, bar.width * 0.2)
            implicitHeight: 34
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
                    Layout.fillWidth: true
                    color: ui.text
                    font.pixelSize: 12
                    clip: true
                    selectByMouse: true
                    Keys.onEscapePressed: { text = ""; focus = false }
                    Label {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: field.text === ""
                        text: qsTr("Search meetings")
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
                    text: qsTr("Offer to listen when an app uses the mic")
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

        Row {
            spacing: 6
            KeyCap { text: "?"; anchors.verticalCenter: parent.verticalCenter }
            Label { text: qsTr("keys"); color: ui.muted; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: keys.open() }
        }
    }
}
