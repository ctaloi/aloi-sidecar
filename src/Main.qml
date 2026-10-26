import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// One bar that says whether Sidecar is listening; every meeting on the
// left; the meeting on screen in the middle, as it's said or as it was;
// and the agent on the right, asked about that meeting and no other.
// Space listens, / asks, ? shows the keys.
ApplicationWindow {
    id: win
    width: 1440
    height: 900
    minimumWidth: 720
    minimumHeight: 480
    visible: true
    title: {
        const t = engine.selectedMeeting.title
        return (engine.listening ? "● " : "") + "Aloi Sidecar" + (t ? " · " + t : "")
    }
    color: ui.window

    Material.theme: theme.dark ? Material.Dark : Material.Light
    Material.accent: theme.accent
    Material.foreground: ui.text
    Material.background: ui.raised
    Material.roundedScale: theme.radius

    Colors { id: ui }

    // The clock the live timer and lengths read.
    property double now: Date.now()
    Timer { interval: 1000; repeat: true; running: true; onTriggered: win.now = Date.now() }

    readonly property bool typing: activeFocusItem !== null
        && (activeFocusItem instanceof TextInput || (activeFocusItem instanceof TextEdit && !activeFocusItem.readOnly))
    readonly property bool overlayOpen: keys.visible || newMeetingDialog.visible || quitDialog.visible || meetingPane.dialogOpen
    readonly property bool idle: !typing && !overlayOpen
    // The list folds away by hand (\), or by itself when there isn't room for three columns.
    property bool listHidden: false
    readonly property bool listShown: !listHidden && width >= 1100

    function newMeeting() {
        if (engine.current !== "") newMeetingDialog.open()
        else engine.startMeeting()
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

    header: TopBar {
        id: topBar
        onToggleList: win.listHidden = !win.listHidden
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        MeetingList {
            id: meetingList
            visible: win.listShown
            Layout.preferredWidth: 320
            Layout.fillHeight: true
            filter: topBar.search.text
            now: win.now
        }
        MeetingPane {
            id: meetingPane
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumWidth: 300
            now: win.now
        }
        AgentPane {
            id: agentPane
            // A third of a wide window; in a narrow tile it shares the room.
            Layout.preferredWidth: win.width < 960 ? win.width * 0.44 : Math.max(360, Math.min(440, win.width * 0.3))
            Layout.fillHeight: true
        }
    }

    KeysOverlay { id: keys }

    Dialog {
        id: newMeetingDialog
        anchors.centerIn: Overlay.overlay
        modal: true
        title: qsTr("End “%1” and start a new meeting?").arg(engine.meetingById(engine.current).title || "")
        width: Math.min(460, win.width - 40)
        Material.roundedScale: theme.radius
        Label {
            width: newMeetingDialog.availableWidth
            wrapMode: Text.Wrap
            text: qsTr("The current meeting is kept as it is, and the new one starts listening.")
        }
        standardButtons: Dialog.Ok | Dialog.Cancel
        onAccepted: engine.startMeeting()
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
            text: qsTr("The meeting is paused, not ended: open Sidecar again and Space carries on with it.")
        }
        standardButtons: Dialog.Ok | Dialog.Cancel
        onAccepted: Qt.quit()
    }

    Shortcut { sequence: "Space"; context: Qt.ApplicationShortcut; enabled: win.idle && engine.connected; onActivated: engine.toggleListening() }
    Shortcut { sequence: "/"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: agentPane.input.forceActiveFocus() }
    Shortcut { sequence: "Ctrl+F"; context: Qt.ApplicationShortcut; enabled: !win.overlayOpen; onActivated: { win.listHidden = false; topBar.search.forceActiveFocus() } }
    Shortcut { sequence: "?"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: keys.open() }
    Shortcut { sequence: "End"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: meetingPane.transcriptPane.toLive() }
    Shortcut { sequence: "J"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: meetingList.step(1) }
    Shortcut { sequence: "K"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: meetingList.step(-1) }
    Shortcut { sequence: "G"; context: Qt.ApplicationShortcut; enabled: win.idle && engine.current !== ""; onActivated: engine.select(engine.current) }
    Shortcut { sequence: "\\"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: win.listHidden = !win.listHidden }
    Shortcut { sequence: "R"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: meetingPane.rename() }
    Shortcut { sequence: "E"; context: Qt.ApplicationShortcut; enabled: win.idle && engine.current !== ""; onActivated: { engine.select(engine.current); meetingPane.confirmEnd() } }
    Shortcut { sequence: "Ctrl+N"; context: Qt.ApplicationShortcut; enabled: !win.overlayOpen; onActivated: win.newMeeting() }
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
