import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// One bar that says whether Sidecar is listening, the transcript as it's
// said, and the agent beside it. Space listens, / asks, ? shows the keys.
ApplicationWindow {
    id: win
    width: 1280
    height: 820
    minimumWidth: 560
    minimumHeight: 420
    visible: true
    title: engine.listening ? qsTr("Aloi Sidecar · Listening") : qsTr("Aloi Sidecar")
    color: ui.window

    Material.theme: theme.dark ? Material.Dark : Material.Light
    Material.accent: theme.accent
    Material.foreground: ui.text
    Material.background: ui.raised
    Material.roundedScale: theme.radius

    Colors { id: ui }

    readonly property bool typing: activeFocusItem !== null
        && (activeFocusItem instanceof TextInput || (activeFocusItem instanceof TextEdit && !activeFocusItem.readOnly))
    readonly property bool overlayOpen: keys.visible || newMeetingDialog.visible || quitDialog.visible
    readonly property bool idle: !typing && !overlayOpen
    // Side by side when there's room; the agent goes under the transcript in a narrow tile.
    readonly property bool wide: width >= 860

    // "13:58, Mon 26 Oct" from the meeting's file name (2026-10-26_135804).
    function meetingLabel(name) {
        const m = (name || "").match(/^(\d{4})-(\d{2})-(\d{2})_(\d{2})(\d{2})/)
        if (!m) return ""
        const d = new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5])
        return qsTr("Meeting since %1").arg(d.toLocaleString(Qt.locale(), "ddd d MMM, HH:mm"))
    }

    Connections {
        target: instance
        function onOpenRequested(action) {
            win.raise()
            win.requestActivate()
            if (action === "ask") agentPane.input.forceActiveFocus()
            else if (action === "toggle") engine.toggleListening()
        }
    }

    header: Rectangle {
        height: 52
        color: ui.panel
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: ui.line }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 14
            spacing: 14

            // The one thing that must never be in doubt: is it listening?
            Rectangle {
                id: pill
                implicitWidth: pillRow.implicitWidth + 24
                implicitHeight: 30
                radius: Math.min(theme.radius, height / 2)
                color: engine.listening ? ui.alpha(ui.live, pillMouse.containsMouse ? 0.28 : 0.18)
                                        : (pillMouse.containsMouse ? ui.hover : ui.raised)
                border.color: engine.listening ? ui.alpha(ui.live, 0.7) : ui.line
                Row {
                    id: pillRow
                    anchors.centerIn: parent
                    spacing: 8
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 10; height: 10; radius: 5
                        color: engine.listening ? ui.live : !engine.connected ? ui.faint : ui.muted
                        SequentialAnimation on opacity {
                            running: engine.listening
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
                            onRunningChanged: if (!running) parent.opacity = 1
                        }
                    }
                    Text {
                        text: !engine.connected ? qsTr("Engine offline")
                            : engine.listening ? qsTr("Listening") : qsTr("Paused")
                        color: ui.text
                        font.pixelSize: 13
                        font.bold: true
                    }
                    Text {
                        text: "Space"
                        visible: engine.connected
                        color: ui.faint
                        font.pixelSize: 11
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                MouseArea {
                    id: pillMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: engine.toggleListening()
                }
            }

            ColumnLayout {
                spacing: 0
                Layout.fillWidth: true
                Text {
                    Layout.fillWidth: true
                    text: win.meetingLabel(engine.meeting) || qsTr("Aloi Sidecar")
                    color: ui.text
                    font.pixelSize: 13
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    text: engine.error !== "" ? engine.error
                        : qsTr("%n lines", "", transcript.count) + (engine.echoes > 0 ? "  ·  " + qsTr("%n echoes dropped", "", engine.echoes) : "")
                    color: engine.error !== "" ? ui.danger : ui.faint
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }

            // A meter per input: the mic, the laptop's speakers, each display.
            Row {
                spacing: 12
                visible: win.width > 720
                Repeater {
                    model: engine.channels
                    delegate: Column {
                        required property var modelData
                        spacing: 3
                        opacity: modelData.alive ? 1 : 0.35
                        Text {
                            text: modelData.label
                            color: modelData.speaking ? ui.text : ui.faint
                            font.pixelSize: 10
                        }
                        Rectangle {
                            width: 54; height: 4
                            radius: 2
                            color: ui.raised
                            Rectangle {
                                height: parent.height
                                radius: 2
                                width: Math.min(parent.width, Math.sqrt(modelData.level) * parent.width * 3)
                                color: modelData.speaker === "Them" ? ui.them : ui.me
                                Behavior on width { NumberAnimation { duration: 120 } }
                            }
                        }
                    }
                }
            }

            ToolButton {
                text: qsTr("? keys")
                font.pixelSize: 12
                onClicked: keys.open()
            }
        }
    }

    SplitView {
        anchors.fill: parent
        orientation: win.wide ? Qt.Horizontal : Qt.Vertical
        handle: Rectangle {
            implicitWidth: 1
            implicitHeight: 1
            color: SplitHandle.hovered || SplitHandle.pressed ? theme.accent : ui.line
        }

        TranscriptPane {
            id: transcriptPane
            SplitView.fillWidth: true
            SplitView.fillHeight: true
            SplitView.minimumWidth: 280
            SplitView.minimumHeight: 160
        }
        AgentPane {
            id: agentPane
            SplitView.preferredWidth: win.wide ? Math.max(380, win.width * 0.38) : win.width
            SplitView.preferredHeight: win.wide ? win.height : win.height * 0.45
            SplitView.minimumWidth: 300
            SplitView.minimumHeight: 200
        }
    }

    KeysOverlay { id: keys }

    Dialog {
        id: newMeetingDialog
        anchors.centerIn: Overlay.overlay
        modal: true
        title: qsTr("Start a new meeting?")
        width: Math.min(460, win.width - 40)
        Material.roundedScale: theme.radius
        Label {
            width: newMeetingDialog.availableWidth
            wrapMode: Text.Wrap
            text: qsTr("The transcript starts over, and so does the agent. This meeting stays saved in %1.").arg(engine.meetingPath)
        }
        standardButtons: Dialog.Ok | Dialog.Cancel
        onAccepted: engine.newMeeting()
    }

    Dialog {
        id: quitDialog
        anchors.centerIn: Overlay.overlay
        modal: true
        title: qsTr("Stop listening and quit?")
        width: Math.min(460, win.width - 40)
        Material.roundedScale: theme.radius
        Label {
            width: quitDialog.availableWidth
            wrapMode: Text.Wrap
            text: qsTr("The transcript is saved; open Sidecar again to pick it back up.")
        }
        standardButtons: Dialog.Ok | Dialog.Cancel
        onAccepted: Qt.quit()
    }

    Shortcut { sequence: "Space"; context: Qt.ApplicationShortcut; enabled: win.idle && engine.connected; onActivated: engine.toggleListening() }
    Shortcut { sequence: "/"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: agentPane.input.forceActiveFocus() }
    Shortcut { sequence: "?"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: keys.open() }
    Shortcut { sequence: "End"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: transcriptPane.toLive() }
    Shortcut { sequence: "Ctrl+N"; context: Qt.ApplicationShortcut; enabled: !win.overlayOpen; onActivated: newMeetingDialog.open() }
    Shortcut { sequence: "Ctrl+Shift+K"; context: Qt.ApplicationShortcut; enabled: !win.overlayOpen && !agent.running; onActivated: agent.forget() }
    Shortcut { sequence: "Esc"; context: Qt.ApplicationShortcut; enabled: win.idle && agent.running; onActivated: agent.stop() }
    Shortcut { sequence: "Y"; context: Qt.ApplicationShortcut; enabled: win.idle && agent.approvals.length > 0; onActivated: agent.decide(agent.approvals[0].id, "once") }
    Shortcut { sequence: "N"; context: Qt.ApplicationShortcut; enabled: win.idle && agent.approvals.length > 0; onActivated: agent.decide(agent.approvals[0].id, "deny") }
    Shortcut { sequence: "Q"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: engine.listening ? quitDialog.open() : Qt.quit() }
    Repeater {
        model: 4
        delegate: Item {
            required property int index
            Shortcut {
                sequence: String(index + 1)
                context: Qt.ApplicationShortcut
                enabled: win.idle && !agent.running
                onActivated: agentPane.ask(agentPane.chips[index])
            }
        }
    }
}
