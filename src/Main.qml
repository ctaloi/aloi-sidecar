import QtQuick
import QtCore
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import "sidecar.js" as Sidecar

// The Aloi bar, with whether Sidecar is listening; every meeting on the
// left; and in the middle Home (what's on and what's waiting on you), or
// the meeting on screen, as it's said or what it came to, with the agent
// asked about it and no other. Space listens, > asks, / searches, ; runs
// any command, ? lists the keys, right-click does the rest.
ApplicationWindow {
    id: win
    width: 1440
    height: 900
    // Rolled up to the bar, the window lets the compositor make it that
    // small; Qt hands Hyprland its minimum size, and Hyprland keeps to it.
    minimumWidth: shaded ? 320 : 720
    minimumHeight: shaded ? miniBar.implicitHeight : 480
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
    readonly property bool overlayOpen: palette.visible || confirm.visible || sendSheet.visible || emailSheet.visible
    readonly property bool idle: !typing && !overlayOpen
    readonly property var shown: engine.selectedMeeting
    readonly property string stage: Sidecar.stage(shown)
    // Meetings waiting on a wrap-up, oldest first: the Meetings count and Home's cards.
    readonly property var waiting: engine.meetings.filter(m => Sidecar.needsWrapup(m, Date.now()))
                                        .sort((a, b) => a.started - b.started)
    // Home, a meeting, or every follow-up across them (g h, g m, g f).
    property string view: "home"
    function goHome() { setShaded(false); view = "home" }
    function showScope(key) { setShaded(false); view = key }
    function showKeys() { palette.open(true) }
    function focusSearch() { if (listFits) listHidden = false; topBar.focusSearch() }
    function openSelected() { if (engine.selected !== "") openFrom(engine.selected, -1) }
    // Esc: out of the search, then stop the agent, then back home.
    function back() {
        if (topBar.search.text !== "") { topBar.search.text = ""; return }
        if (agent.running) { agent.stop(); return }
        if (view !== "home") goHome()
    }
    function askAgent() { showAgent(); meetingPane.agentPane.input.forceActiveFocus() }
    function quit() {
        if (!engine.listening) { Qt.quit(); return }
        confirm.ask({
            title: qsTr("Stop listening and quit?"),
            detail: qsTr("The meeting is paused, not ended: open Sidecar again and Space carries on with it."),
            confirm: qsTr("Quit"),
            run: () => Qt.quit()
        })
    }
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
    // Rolled up to its bar like a classic Mac OS window shade (B, or ▴),
    // pinned over every workspace, still listening.
    property bool shaded: false
    function setShaded(on) {
        if (on === shaded) return
        if (on) {
            listDrawer.close()
            if (activeFocusItem) activeFocusItem.focus = false
            shaded = true
            // Qt commits the smaller minimum size with the next frame; only
            // then will Hyprland shrink the window that far.
            shadeLater.restart()
        } else {
            shade.unshade()
        }
    }
    Timer { id: shadeLater; interval: 60; onTriggered: shade.shade(560, miniBar.implicitHeight) }
    Connections {
        target: shade
        // The full window comes back once Hyprland has given it its size.
        function onDone(on) { if (!on) win.shaded = false }
    }
    // Anything that needs the window, a question or a confirm, rolls it down.
    onOverlayOpenChanged: if (overlayOpen) setShaded(false); else keyRoot.forceActiveFocus()
    // Out of an overlay or a box, the keys come back: nothing else holding
    // the keyboard, it's the window's, so ; > ? still reach their commands.
    onActiveFocusItemChanged: if (activeFocusItem === null || activeFocusItem === contentItem) Qt.callLater(() => {
        if (activeFocusItem === null || activeFocusItem === contentItem) keyRoot.forceActiveFocus()
    })

    // The meeting's tabs: the agent, the transcript, the notes.
    function showAgent() { setShaded(false); view = "meetings"; meetingPane.tab = "agent" }
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
            win.setShaded(false)
            win.raise()
            win.requestActivate()
            if (action === "ask") { win.showAgent(); meetingPane.agentPane.input.forceActiveFocus() }
            else if (action === "toggle") engine.toggleListening()
        }
    }
    Connections {
        target: engine
        function onCopied(what) { toast.show(what) }
        function onChoosePage(id) { win.act("send", engine.meetingById(id)) }
    }
    // Enter in the search box opens the first meeting found, at the line.
    Connections {
        target: topBar.search
        function onAccepted() { win.view = "meetings"; meetingList.openFirst() }
    }

    // Every command, once: the keys, the ; palette and the ? list all come
    // from here, as in every Aloi app. seqs are Qt's spelling of the keys (a
    // capital is Shift+, a chord is "G,H"); enabled() says when it makes
    // sense, and the palette lists only those. always runs while typing too.
    // Nothing here may read live state outside enabled() and run(): the list
    // would be rebuilt, and every Shortcut with it, each time it changed.
    readonly property bool hasMeeting: shown.id !== undefined
    readonly property bool over: hasMeeting && shown.state === "ended"
    readonly property bool onAir: engine.current !== ""
    readonly property bool hasNotes: over && (stage === "ready" || stage === "sendFailed" || stage === "sent" || (stage === "skipped" && shown.wrapup === "ready"))
    readonly property var actions: [
        { id: "listen", show: "space", seqs: ["Space"], group: qsTr("Listening"), enabled: () => engine.connected,
          label: qsTr("Listen / pause"),
          run: () => engine.toggleListening() },
        { id: "end", show: "e", seqs: ["E"], group: qsTr("Listening"), label: qsTr("End the meeting that's on"),
          enabled: () => onAir, run: () => act("end", engine.meetingById(engine.current)) },
        { id: "mark", show: "m", seqs: ["M"], group: qsTr("Listening"), label: qsTr("Mark this moment"),
          enabled: () => onAir, run: markNow },
        { id: "new", show: "ctrl+n", seqs: ["Ctrl+N"], always: true, group: qsTr("Listening"), label: qsTr("Start a new meeting"),
          run: newMeeting },

        { id: "note", show: "n", seqs: ["N"], group: qsTr("Meeting"), label: qsTr("Note: a line of your own"),
          enabled: () => hasMeeting && agent.approvals.length === 0, run: () => meetingPane.note() },
        { id: "rename", show: "r", seqs: ["R"], group: qsTr("Meeting"), label: qsTr("Rename"),
          enabled: () => hasMeeting, run: () => meetingPane.rename() },
        { id: "tab", show: "t", seqs: ["T"], group: qsTr("Meeting"), label: qsTr("Agent / transcript / notes"),
          enabled: () => hasMeeting, run: () => { view = "meetings"; meetingPane.toggleTab() } },
        { id: "live", show: "end", seqs: ["End"], group: qsTr("Meeting"), label: qsTr("The transcript, at the newest line"),
          enabled: () => hasMeeting, run: () => { view = "meetings"; meetingPane.tab = "transcript"; meetingPane.transcriptPane.toLive() } },
        { id: "continue", show: "", seqs: [], group: qsTr("Meeting"), label: qsTr("Continue this meeting"),
          enabled: () => over && !onAir, run: () => act("listen", shown) },
        { id: "files", show: "", seqs: [], group: qsTr("Meeting"), label: qsTr("Show its files"),
          enabled: () => hasMeeting, run: () => act("files", shown) },
        { id: "merge", show: "", seqs: [], group: qsTr("Meeting"), label: qsTr("Merge with another meeting"),
          enabled: () => over, run: () => act("merge", shown) },
        { id: "more", show: ".", seqs: [".", "Menu", "Shift+F10"], group: qsTr("Meeting"), label: qsTr("Its menu (the ⋯ by its title)"),
          enabled: () => hasMeeting, run: () => { view = "meetings"; meetingPane.openMenu() } },
        { id: "delete", show: "del", seqs: ["Del"], group: qsTr("Meeting"), label: qsTr("Delete the meeting"), danger: true,
          enabled: () => over, run: () => act("delete", shown) },
        { id: "draft", show: "d", seqs: ["D"], group: qsTr("Wrap-up"), label: qsTr("Draft the wrap-up (again)"),
          enabled: () => over && (shown.lines || 0) > 0 && stage !== "drafting", run: () => act("draft", shown) },
        { id: "finish", show: "a", seqs: ["A"], group: qsTr("Wrap-up"), label: qsTr("Do it all: Notion and the email draft"),
          enabled: () => over && shown.wrapup === "ready" && stage !== "sent" && stage !== "sending", run: () => act("finish", shown) },
        { id: "send", show: "s", seqs: ["S"], group: qsTr("Wrap-up"), label: qsTr("Send to Notion"),
          enabled: () => hasNotes && stage !== "sent" && stage !== "sending", run: () => act("send", shown) },
        { id: "email", show: "w", seqs: ["W"], group: qsTr("Wrap-up"), label: qsTr("Write the follow-up email"),
          enabled: () => over && shown.wrapup === "ready", run: () => act("email", shown) },
        { id: "notion", show: "o", seqs: ["O"], group: qsTr("Wrap-up"), label: qsTr("Open in Notion"),
          enabled: () => stage === "sent", run: () => act("notion", shown) },
        { id: "copyNotes", show: "c", seqs: ["C"], group: qsTr("Wrap-up"), label: qsTr("Copy the wrap-up as Markdown"),
          enabled: () => hasNotes, run: () => act("copyNotes", shown) },
        { id: "copyTranscript", show: "C", seqs: ["Shift+C"], group: qsTr("Wrap-up"), label: qsTr("Copy the transcript"),
          enabled: () => (shown.lines || 0) > 0, run: () => act("copyTranscript", shown) },
        { id: "skip", show: "x", seqs: ["X"], group: qsTr("Wrap-up"), label: qsTr("No wrap-up needed / needed after all"),
          enabled: () => over && stage !== "sent", run: () => act("skip", shown) },
        { id: "revert", show: "", seqs: [], group: qsTr("Wrap-up"), label: qsTr("Go back to Opus's draft"),
          enabled: () => over && !!shown.edited && stage !== "sent", run: () => act("revert", shown) },
        { id: "ask", show: ">", seqs: [">"], group: qsTr("Agent"), label: qsTr("Ask the agent about this meeting"),
          enabled: () => hasMeeting, run: askAgent },
        { id: "wide", show: "", seqs: [], group: qsTr("Agent"), label: qsTr("Ask across all meetings"),
          run: () => { agent.wide = true; askAgent() } },
        { id: "allow", show: "y", seqs: ["Y"], group: qsTr("Agent"), label: qsTr("Allow what the agent asks to run"),
          enabled: () => agent.approvals.length > 0, run: () => agent.decide(agent.approvals[0].id, "once") },
        { id: "deny", show: "n", seqs: ["N"], group: qsTr("Agent"), label: qsTr("Deny what the agent asks to run"),
          enabled: () => agent.approvals.length > 0, run: () => agent.decide(agent.approvals[0].id, "deny") },
        { id: "forget", show: "ctrl+shift+k", seqs: ["Ctrl+Shift+K"], always: true, group: qsTr("Agent"), label: qsTr("New chat with the agent"),
          enabled: () => !agent.running, run: () => agent.forget() },

        { id: "down", show: "j", seqs: ["J"], group: qsTr("Move"), label: qsTr("Next meeting"), run: () => meetingList.step(1) },
        { id: "up", show: "k", seqs: ["K"], group: qsTr("Move"), label: qsTr("Previous meeting"), run: () => meetingList.step(-1) },
        { id: "list", show: "\\", seqs: ["\\"], group: qsTr("Move"), label: qsTr("Show / hide the meetings"), run: toggleList },
        { id: "back", show: "esc", seqs: [], group: qsTr("Move"), label: qsTr("Back: clear the search, stop the agent, go home"), run: back },

        { id: "home", show: "g h", seqs: ["G,H"], group: qsTr("Go to"), label: qsTr("Home"), run: goHome },
        { id: "meetings", show: "g m", seqs: ["G,M"], group: qsTr("Go to"), label: qsTr("The meeting on screen"), run: openSelected },
        { id: "current", show: "g n", seqs: ["G,N"], group: qsTr("Go to"), label: qsTr("The meeting that's on now"),
          enabled: () => onAir, run: () => openFrom(engine.current, -1) },
        { id: "followups", show: "g f", seqs: ["G,F"], group: qsTr("Go to"), label: qsTr("Follow-ups"), run: () => showScope("followups") },

        { id: "search", show: "/", seqs: ["/"], group: qsTr("Find"), label: qsTr("Search what was said, in every meeting"), run: focusSearch },
        { id: "palette", show: ";", seqs: [";"], group: qsTr("Find"), label: qsTr("Commands"), run: () => palette.open(false) },

        { id: "shade", show: "b", seqs: ["B"], group: qsTr("App"), label: qsTr("Roll up to a small bar"), run: () => setShaded(!shaded) },
        { id: "help", show: "?", seqs: ["?"], group: qsTr("App"), label: qsTr("Keys"), run: showKeys },
        { id: "quit", show: "q", seqs: ["Q"], group: qsTr("App"), label: qsTr("Quit"), run: quit }
    ]
    function action(id) { return actions.find(a => a.id === id) }
    // What the palette adds when typed for: the settings, and every meeting
    // (the six newest show before anything is typed).
    function paletteMore() {
        const out = []
        const st = engine.settings
        const flip = (key, label) => out.push({ group: qsTr("Settings"), show: "",
            label: (st[key] !== false ? qsTr("Turn off: %1") : qsTr("Turn on: %1")).arg(label),
            run: () => engine.setSetting(key, !(st[key] !== false)) })
        flip("watch_calls", qsTr("record calls by itself"))
        flip("calendar_offers", qsTr("offers before calendar meetings"))
        flip("live_takeaways", qsTr("live takeaways"))
        flip("stop_on_silence", qsTr("end after a long silence"))
        out.push({ group: qsTr("Settings"), show: "",
                   label: st.speaker_names === true ? qsTr("Turn off: tell their voices apart") : qsTr("Turn on: tell their voices apart"),
                   run: () => engine.setSetting("speaker_names", st.speaker_names !== true) })
        engine.meetings.slice().sort((a, b) => (b.started || 0) - (a.started || 0))
            .forEach((x, i) => out.push({ group: qsTr("Meetings"), show: "", label: x.title || qsTr("Untitled"),
                                          detail: Sidecar.dayLabel(x) + "  ·  " + Sidecar.span(x), quiet: i >= 6,
                                          run: () => openFrom(x.id, -1) }))
        return out
    }

    header: Item {
        implicitHeight: win.shaded ? miniBar.implicitHeight : topBar.implicitHeight
        TopBar {
            id: topBar
            anchors.fill: parent
            visible: !win.shaded
            onToggleList: win.toggleList()
            onShade: win.setShaded(true)
            onLeave: keyRoot.forceActiveFocus()
            onMoveRequested: delta => meetingList.step(delta)
        }
        MiniBar {
            id: miniBar
            anchors.fill: parent
            visible: win.shaded
            now: win.now
            onUnshade: win.setShaded(false)
        }
    }

    Item {
        id: keyRoot
        objectName: "keyRoot"
        anchors.fill: parent
        visible: !win.shaded
        focus: true

        // Symbols typed with Shift (> ? ;) arrive as Shift plus the symbol,
        // and whether a Shortcut matches that depends on the keyboard
        // layout. A key no Shortcut took lands here: run the command by the
        // character typed.
        Keys.onPressed: event => {
            if (win.typing || win.overlayOpen) return
            if (event.text.length !== 1) return
            const a = win.actions.find(x => x.show === event.text && !/[a-z0-9]/i.test(x.show))
            if (a && (!a.enabled || a.enabled())) { a.run(); event.accepted = true }
        }

        SplitView {
            anchors.fill: parent
            orientation: Qt.Horizontal
            handle: Rectangle {
                implicitWidth: 1
                color: SplitHandle.hovered || SplitHandle.pressed ? theme.accent : ui.line
            }

            MeetingList {
                id: meetingList
                visible: win.listShown && win.view !== "followups"
                SplitView.preferredWidth: 380
                SplitView.minimumWidth: 280
                filter: topBar.search.text
                now: win.now
            }

            // Home, the meeting on screen, or the follow-ups.
            Item {
                SplitView.fillWidth: true
                SplitView.minimumWidth: 360
                visible: win.view === "followups" || !(win.searching && !win.listFits)
                clip: true
                Home {
                    id: home
                    objectName: "home"
                    anchors.fill: parent
                    visible: win.view === "home"
                    now: win.now
                }
                FollowupsPane {
                    anchors.fill: parent
                    visible: win.view === "followups"
                    now: win.now
                    onOpenMeeting: (id, at) => win.openFrom(id, at)
                }
                // The call: what meeting it is and its switches, then its tabs.
                ColumnLayout {
                    id: center
                    anchors.fill: parent
                    visible: win.view === "meetings"
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
        interactive: !win.listFits && !win.shaded
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

    Toast {
        id: toast
        visible: opacity > 0 && !win.shaded
        // Rolled up, the bar says it instead.
        onShown: message => { miniBar.notice = message; noticeClear.restart() }
    }
    Timer { id: noticeClear; interval: 1800; onTriggered: miniBar.notice = "" }
    // Over the whole window, the bar too, as in every Aloi app.
    SendSheet { id: sendSheet; objectName: "sendSheet"; parent: Overlay.overlay; anchors.fill: parent; z: 40 }
    EmailSheet { id: emailSheet; objectName: "emailSheet"; parent: Overlay.overlay; anchors.fill: parent; z: 41 }
    CommandPalette { id: palette; objectName: "palette"; parent: Overlay.overlay; anchors.fill: parent; z: 44; actions: win.actions; more: win.paletteMore }
    ConfirmOverlay { id: confirm; parent: Overlay.overlay; anchors.fill: parent; z: 45 }

    // The single keys stay out of the way while you type or an overlay is up.
    Repeater {
        model: win.actions.filter(a => a.seqs.length > 0)
        Item {
            required property var modelData
            Shortcut {
                sequences: modelData.seqs
                context: Qt.ApplicationShortcut
                enabled: (modelData.always ? !win.overlayOpen : win.idle) && (!modelData.enabled || modelData.enabled())
                onActivated: modelData.run()
            }
        }
    }
    Shortcut { sequence: "Ctrl+K"; context: Qt.ApplicationShortcut; enabled: !win.overlayOpen; onActivated: win.focusSearch() }
    Shortcut { sequence: "Esc"; context: Qt.ApplicationShortcut; enabled: win.idle; onActivated: win.back() }
    // 1 to 4 ask the agent's suggestions.
    Repeater {
        model: 4
        delegate: Item {
            required property int index
            Shortcut {
                sequence: String(index + 1)
                context: Qt.ApplicationShortcut
                enabled: win.idle && !agent.running && win.hasMeeting
                onActivated: { win.showAgent(); meetingPane.agentPane.ask(meetingPane.agentPane.chips[index]) }
            }
        }
    }
}
