import QtQuick
import QtCore
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import "sidecar.js" as Sidecar

// One bar that says whether Sidecar is listening; every meeting on the
// left; the meeting on screen in the middle, as it's said or what it came
// to; and the agent on the right, asked about that meeting and no other.
// Space listens, / asks, ? shows the keys, right-click does the rest.
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
    readonly property bool overlayOpen: keys.visible || palette.visible || confirm.visible || sendSheet.visible || emailSheet.visible
    readonly property bool idle: !typing && !overlayOpen
    readonly property var shown: engine.selectedMeeting
    readonly property string stage: Sidecar.stage(shown)
    // Meetings, or every follow-up across them (F).
    property string view: "meetings"
    function openFrom(id, at) {
        view = "meetings"
        if (width < 1100) topBar.search.text = ""  // the results stood in for the meeting; it's back
        engine.select(id)
        if (at >= 0) meetingPane.showLineWhenLoaded(at)
    }
    // The list folds away by hand (\), or by itself when there isn't room
    // for it; then the same button and key slide it in as a drawer.
    property bool listHidden: false
    readonly property bool listFits: width >= 1100
    function toggleList() {
        if (listFits) listHidden = !listHidden
        else if (listDrawer.opened) listDrawer.close()
        else listDrawer.open()
    }
    // Searching shows the list at any width; in a narrow window the results
    // take the meeting's place until one is picked.
    readonly property bool searching: topBar.search.text.trim().length >= 2
    readonly property bool listShown: !listHidden && (width >= 1100 || searching)
    // The meeting's tabs: the agent, the transcript, the notes.
    function showAgent() { view = "meetings"; meetingPane.tab = "agent" }
    // Something waiting for an Allow can't wait behind another tab.
    Connections {
        target: agent
        function onApprovalsChanged() { if (agent.approvals.length > 0) win.showAgent() }
    }

    // M: flag the moment in the meeting that's on.
    function markNow() {
        if (engine.current === "") return
        engine.mark(engine.current)
        toast.show(qsTr("Marked. It's highlighted in the wrap-up."))
    }

    function newMeeting() {
        if (engine.current === "") { engine.startMeeting(); return }
        confirm.ask({
            title: qsTr("End “%1” and start a new meeting?").arg(engine.meetingById(engine.current).title || ""),
            detail: qsTr("The current meeting ends and its wrap-up is drafted; the new one starts listening."),
            confirm: qsTr("Start a new one"),
            run: () => engine.startMeeting()
        })
    }

    // Everything that can be done with a meeting, from its menu, its
    // buttons or the keys, in one place.
    function act(what, m) {
        if (!m || !m.id) return
        const id = m.id
        switch (what) {
        case "listen":
            if (id === engine.current) engine.toggleListening()
            else if (engine.current === "") engine.resume(id)
            else confirm.ask({
                title: qsTr("Carry on with “%1”?").arg(m.title),
                detail: qsTr("“%1” is on now. It ends, and listening carries on in this meeting instead.").arg(engine.meetingById(engine.current).title || ""),
                confirm: qsTr("Carry on with this one"),
                run: () => engine.resume(id)
            })
            break
        case "end":
            engine.select(id)
            confirm.ask({
                title: qsTr("End “%1”?").arg(m.title),
                detail: qsTr("Listening stops and Opus drafts the wrap-up. Space after this starts a new meeting."),
                confirm: qsTr("End meeting"),
                run: () => engine.endMeeting()
            })
            break
        case "rename":
            engine.select(id)
            Qt.callLater(meetingPane.rename)
            break
        case "draft":
            if (m.wrapup === "drafting" || !(m.lines > 0)) return
            if (m.edited || m.wrapup === "ready")
                confirm.ask({
                    title: qsTr("Draft the wrap-up again?"),
                    detail: m.edited ? qsTr("Opus reads the meeting afresh. The edits you made to this wrap-up are replaced.")
                                     : qsTr("Opus reads the meeting afresh and the current draft is replaced."),
                    confirm: qsTr("Draft again"),
                    danger: !!m.edited,
                    run: () => engine.draftWrapup(id, true)
                })
            else
                engine.draftWrapup(id, false)
            engine.select(id)
            break
        case "send": {
            const s = Sidecar.stage(m)
            if (s === "sent" || s === "sending" || s === "on") return
            if (s === "sendFailed") { engine.sendToNotion(id); return }  // carries on with the same page
            if (!m.wrapup || m.wrapup !== "ready") {
                engine.select(id)
                toast.show(qsTr("Draft the wrap-up first (D)"))
                return
            }
            const notes = id === engine.selected && engine.wrapup ? (engine.wrapup.edited || engine.wrapup.draft || {}) : {}
            sendSheet.open(m, notes.title || m.title)
            break
        }
        case "revert":
            confirm.ask({
                title: qsTr("Go back to Opus's draft?"),
                detail: qsTr("The edits you made to this wrap-up are dropped."),
                confirm: qsTr("Use the draft"),
                danger: true,
                run: () => { if (id === engine.selected) meetingPane.revertNotes(); else engine.saveWrapup(id, {}) }
            })
            break
        case "email":
            if (!m.wrapup || m.wrapup !== "ready") { engine.select(id); toast.show(qsTr("Draft the wrap-up first (D)")); return }
            engine.select(id)
            Qt.callLater(() => emailSheet.open(m))
            break
        case "notion":
            if (m.notion && m.notion.url) Qt.openUrlExternally(m.notion.url)
            break
        case "copyNotes":
            engine.copyWrapup(id)
            break
        case "copyTranscript":
            engine.copyTranscript(id)
            break
        case "finish":
            engine.finish(id)
            toast.show(qsTr("Filing it in Notion and putting the email in your Outlook Drafts…"))
            break
        case "merge": {
            // The other half of the same call: nearest in time first.
            const others = engine.meetings
                .filter(o => o.id !== id && o.id !== engine.current)
                .sort((a, b) => Math.abs(a.started - m.started) - Math.abs(b.started - m.started))
                .map(o => ({
                    label: o.title || qsTr("Untitled"),
                    detail: Sidecar.dayLabel(o) + "  ·  " + Sidecar.span(o) + "  ·  " + qsTr("%n lines", "", o.lines || 0),
                    run: () => {
                        const first = o.started < m.started ? o : m
                        const second = first === o ? m : o
                        confirm.ask({
                            title: qsTr("Merge “%1” and “%2”?").arg(m.title).arg(o.title),
                            detail: qsTr("“%1”, the earlier, keeps its title and gets both transcripts in time order. “%2” goes to the trash folder. The wrap-up is drafted again over the whole call; your edits stay.").arg(first.title).arg(second.title),
                            confirm: qsTr("Merge"),
                            run: () => engine.merge(m.id, o.id)
                        })
                    }
                }))
            palette.choose(qsTr("Merge “%1” with…").arg(m.title), others)
            break
        }
        case "skip":
            engine.setSkipped(id, !m.skipped)
            toast.show(m.skipped ? qsTr("Back in Needs wrap-up") : qsTr("Marked as needing no wrap-up"))
            break
        case "files":
            Qt.openUrlExternally("file://" + engine.meetingFolder(id))
            break
        case "delete":
            if (id === engine.current) return
            confirm.ask({
                title: qsTr("Delete “%1”?").arg(m.title),
                detail: qsTr("Its transcript and wrap-up move to Sidecar's trash folder (~/.local/share/aloi-sidecar/trash). Anything already in Notion stays there."),
                confirm: qsTr("Delete"),
                danger: true,
                run: () => engine.remove(id)
            })
            break
        }
    }

    Connections {
        target: instance
        function onOpenRequested(action) {
            win.raise()
            win.requestActivate()
            if (action === "ask") { win.showAgent(); meetingPane.agentPane.input.forceActiveFocus() }
            else if (action === "toggle") engine.toggleListening()
        }
    }
    Connections {
        target: engine
        function onCopied(what) { toast.show(what) }
    }
    // Enter in the search box opens the first meeting found, at the line.
    Connections {
        target: topBar.search
        function onAccepted() { win.view = "meetings"; meetingList.openFirst() }
    }

    header: TopBar {
        id: topBar
        onToggleList: win.toggleList()
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        FollowupsPane {
            visible: win.view === "followups"
            Layout.fillWidth: true
            Layout.fillHeight: true
            now: win.now
            onOpenMeeting: (id, at) => win.openFrom(id, at)
        }
        MeetingList {
            id: meetingList
            visible: win.listShown && win.view === "meetings"
            Layout.preferredWidth: 300
            Layout.fillWidth: !center.visible
            Layout.fillHeight: true
            filter: topBar.search.text
            now: win.now
        }
        // The call: what meeting it is and its switches, then its tabs.
        ColumnLayout {
            id: center
            visible: win.view === "meetings" && !(win.searching && win.width < 1100)
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumWidth: 360
            spacing: 0
            CallBanner { Layout.fillWidth: true }
            MeetingHeader { id: meetingHeader; Layout.fillWidth: true; now: win.now }
            MeetingPane {
                id: meetingPane
                objectName: "meetingPane"
                Layout.fillWidth: true
                Layout.fillHeight: true
                now: win.now
            }
        }
    }

    Drawer {
        id: listDrawer
        objectName: "listDrawer"
        edge: Qt.LeftEdge
        y: topBar.height
        width: Math.min(340, win.width * 0.85)
        height: win.height - topBar.height
        modal: true
        interactive: !win.listFits
        padding: 0
        background: Rectangle { color: ui.window }
        Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.45) }
        MeetingList {
            anchors.fill: parent
            filter: topBar.search.text
            now: win.now
        }
        // Picking a meeting is what it was opened for.
        Connections {
            target: engine
            function onSelectedChanged() { if (listDrawer.opened) listDrawer.close() }
        }
    }

    KeysOverlay { id: keys; objectName: "keys" }
    CommandPalette { id: palette; objectName: "palette" }
    Toast { id: toast }
    SendSheet { id: sendSheet; objectName: "sendSheet"; anchors.fill: parent; z: 40 }
    EmailSheet { id: emailSheet; objectName: "emailSheet"; anchors.fill: parent; z: 41 }
    ConfirmOverlay { id: confirm; anchors.fill: parent; z: 45 }

    Shortcut { sequence: "Space"; context: Qt.ApplicationShortcut; enabled: win.idle && engine.connected; onActivated: engine.toggleListening() }
    Shortcut { sequence: "/"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: { win.showAgent(); meetingPane.agentPane.input.forceActiveFocus() } }
    Shortcut { sequence: "Ctrl+F"; context: Qt.ApplicationShortcut; enabled: !win.overlayOpen; onActivated: { win.listHidden = false; topBar.search.forceActiveFocus() } }
    Shortcut { sequences: ["Ctrl+K", "Ctrl+P"]; context: Qt.ApplicationShortcut; enabled: !win.overlayOpen; onActivated: palette.show() }
    Shortcut { sequence: "?"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: keys.open() }
    Shortcut { sequence: "End"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: { win.view = "meetings"; meetingPane.tab = "transcript"; meetingPane.transcriptPane.toLive() } }
    Shortcut { sequence: "J"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: meetingList.step(1) }
    Shortcut { sequence: "K"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: meetingList.step(-1) }
    Shortcut { sequence: "G"; context: Qt.ApplicationShortcut; enabled: win.idle && engine.current !== ""; onActivated: engine.select(engine.current) }
    Shortcut { sequence: "\\"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: win.toggleList() }
    Shortcut { sequence: "R"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: meetingPane.rename() }
    Shortcut { sequence: "E"; context: Qt.ApplicationShortcut; enabled: win.idle && engine.current !== ""; onActivated: win.act("end", engine.meetingById(engine.current)) }
    Shortcut { sequence: "F"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: win.view = win.view === "followups" ? "meetings" : "followups" }
    Shortcut { sequence: "T"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: { win.view = "meetings"; meetingPane.toggleTab() } }
    Shortcut { sequence: "D"; context: Qt.ApplicationShortcut; enabled: win.idle && win.shown.state === "ended"; onActivated: win.act("draft", win.shown) }
    Shortcut { sequence: "S"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: win.act("send", win.shown) }
    Shortcut { sequence: "A"; context: Qt.ApplicationShortcut; enabled: win.idle && win.shown.state === "ended" && win.shown.wrapup === "ready" && win.stage !== "sent"; onActivated: win.act("finish", win.shown) }
    Shortcut { sequence: "W"; context: Qt.ApplicationShortcut; enabled: win.idle && win.shown.state === "ended"; onActivated: win.act("email", win.shown) }
    Shortcut { sequence: "O"; context: Qt.ApplicationShortcut; enabled: win.idle && win.stage === "sent"; onActivated: win.act("notion", win.shown) }
    Shortcut { sequence: "C"; context: Qt.ApplicationShortcut; enabled: win.idle && win.shown.state === "ended"; onActivated: win.act("copyNotes", win.shown) }
    Shortcut { sequence: "Shift+C"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: win.act("copyTranscript", win.shown) }
    Shortcut { sequence: "X"; context: Qt.ApplicationShortcut; enabled: win.idle && win.shown.state === "ended" && win.stage !== "sent"; onActivated: win.act("skip", win.shown) }
    Shortcut { sequence: "Del"; context: Qt.ApplicationShortcut; enabled: win.idle && win.shown.state === "ended"; onActivated: win.act("delete", win.shown) }
    Shortcut { sequences: ["Menu", "Shift+F10"]; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: meetingPane.openMenu() }
    Shortcut { sequence: "Ctrl+N"; context: Qt.ApplicationShortcut; enabled: !win.overlayOpen; onActivated: win.newMeeting() }
    Shortcut { sequence: "Ctrl+Shift+K"; context: Qt.ApplicationShortcut; enabled: !win.overlayOpen && !agent.running; onActivated: agent.forget() }
    Shortcut { sequence: "Esc"; context: Qt.ApplicationShortcut; enabled: win.idle && agent.running; onActivated: agent.stop() }
    Shortcut { sequence: "Y"; context: Qt.ApplicationShortcut; enabled: win.idle && agent.approvals.length > 0; onActivated: agent.decide(agent.approvals[0].id, "once") }
    Shortcut { sequence: "N"; context: Qt.ApplicationShortcut; enabled: win.idle && agent.approvals.length > 0; onActivated: agent.decide(agent.approvals[0].id, "deny") }
    Shortcut { sequence: "N"; context: Qt.ApplicationShortcut; enabled: win.idle && agent.approvals.length === 0 && win.shown.id !== undefined; onActivated: meetingPane.note() }
    Shortcut { sequence: "M"; context: Qt.ApplicationShortcut; enabled: win.idle && engine.current !== ""; onActivated: win.markNow() }
    Shortcut {
        sequence: "Q"
        context: Qt.ApplicationShortcut
        enabled: win.idle
        onActivated: {
            if (!engine.listening) { Qt.quit(); return }
            confirm.ask({
                title: qsTr("Stop listening and quit?"),
                detail: qsTr("The meeting is paused, not ended: open Sidecar again and Space carries on with it."),
                confirm: qsTr("Quit"),
                run: () => Qt.quit()
            })
        }
    }
    Repeater {
        model: 4
        delegate: Item {
            required property int index
            Shortcut {
                sequence: String(index + 1)
                context: Qt.ApplicationShortcut
                enabled: win.idle && !agent.running
                onActivated: { win.showAgent(); meetingPane.agentPane.ask(meetingPane.agentPane.chips[index]) }
            }
        }
    }
}
