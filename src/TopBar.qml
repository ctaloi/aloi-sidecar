import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "sidecar.js" as Sidecar

// The Aloi bar: the app, the switch between Home, the meetings and the
// follow-ups (each with what's waiting on you), whether it's listening and
// what each input hears (the thing that must never be in doubt), whether
// the engine is there, search, settings, the roll-up, and the keys.
Rectangle {
    id: bar
    implicitHeight: 52
    color: ui.window

    property alias search: field
    signal toggleList()
    // Roll the window up to a small bar of its own (B).
    signal shade()
    signal leave()
    signal moveRequested(int delta)
    function focusSearch() { field.forceActiveFocus(); field.selectAll() }

    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: ui.line }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 14
        spacing: 18

        // A narrow window keeps the meetings in a drawer: this opens it.
        KeyButton {
            visible: !win.listFits
            glyph: "menu"
            tip: qsTr("Meetings")
            keys: "\\"
            onClicked: bar.toggleList()
        }

        // The mark: the logo, whose wave moves while listening, and the name
        // in the Omarchy way. It goes home.
        AppMark { name: "sidecar"; running: engine.listening; onTapped: win.goHome() }

        // Home, the meeting on screen, or the follow-ups. Meetings counts
        // the wrap-ups waiting on you; Follow-ups what you said you'd do.
        ScopeSwitch {
            // Short of room, the list's drawer and g h / g m / g f stand in.
            visible: bar.width >= 1100
            hint: ""
            scopes: [
                { key: "home", label: qsTr("Home"), glyph: "home", keys: "g h", current: win.view === "home" || win.view === "topic",
                  tip: qsTr("What's on, and what's waiting on you") },
                { key: "meetings", label: qsTr("Meetings"), glyph: "meetings", keys: "g m", current: win.view === "meetings",
                  count: win.waiting.length,
                  tip: win.waiting.length > 0 ? qsTr("%n waiting on a wrap-up", "", win.waiting.length) : qsTr("Every meeting is wrapped up") },
                { key: "followups", label: qsTr("Follow-ups"), glyph: "followups", keys: "g f", current: win.view === "followups",
                  count: engine.followupsOpen,
                  tip: engine.followupsOpen > 0 ? qsTr("%n you said you'd do", "", engine.followupsOpen) : qsTr("Nothing you said you'd do is open") }
            ]
            onPicked: key => key === "meetings" ? win.openSelected() : win.showScope(key)
        }

        // Listening, paused or offline, and the switch for it.
        Rectangle {
            id: pill
            implicitWidth: pillRow.implicitWidth + 22
            implicitHeight: 34
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
                }
                Label {
                    anchors.verticalCenter: parent.verticalCenter
                    text: !engine.connected ? qsTr("Can't listen")
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
                            }
                        }
                    }
                }
                KeyCap { text: "space"; visible: engine.connected && bar.width > 760; anchors.verticalCenter: parent.verticalCenter }
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

        // Is the engine there? A dot; words only when it isn't.
        StatusDot {
            busy: engine.connected && engine.loading
            trouble: !engine.connected
            text: engine.connected ? "" : qsTr("Engine offline")
            tip: engine.connected ? qsTr("The engine is listening for you  ·  127.0.0.1:8777")
                : (engine.error || qsTr("The engine isn't running")) + "  ·  systemctl --user start aloi-sidecar-engine"
        }

        // What was said, in every meeting: the list narrows as you type.
        BarSearch {
            id: field
            objectName: "search"
            visible: bar.width > 720 || activeFocus || text !== ""
            placeholderText: qsTr("Search transcripts")
            Keys.onDownPressed: bar.moveRequested(1)
            Keys.onUpPressed: bar.moveRequested(-1)
            Keys.onEscapePressed: {
                if (text !== "") text = ""
                bar.leave()
            }
        }

        // Sidecar's own settings, few on purpose.
        KeyButton {
            id: settingsButton
            glyph: "more"
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
                    text: qsTr("Live takeaways during calls (Haiku)")
                    setting: true
                    on: engine.settings.live_takeaways !== false
                    onTriggered: engine.setSetting("live_takeaways", !(engine.settings.live_takeaways !== false))
                }
                MenuRow {
                    text: qsTr("Tell their voices apart, and name them")
                    setting: true
                    on: engine.settings.speaker_names === true
                    onTriggered: engine.setSetting("speaker_names", engine.settings.speaker_names !== true)
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

        KeyButton {
            glyph: "rollup"
            tip: qsTr("Roll up to a small bar on every workspace")
            keys: "b"
            onClicked: bar.shade()
        }

        KeysButton { onClicked: win.showKeys() }
    }
}
