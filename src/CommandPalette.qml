import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import "sidecar.js" as Sidecar

// Ctrl+K: everything Sidecar does, and every meeting, a few letters away.
// Actions come first and only the ones that make sense right now; meetings
// follow, newest first. Up and down pick, Enter runs, Esc closes.
Popup {
    id: popup
    modal: true
    focus: true
    // Up where the eye is, not dead centre.
    x: Math.round((win.width - width) / 2)
    y: Math.min(90, Math.round((win.height - height) / 2))
    Material.roundedScale: theme.radius
    width: Math.min(win.width - 48, 620)
    height: Math.min(win.height - 120, 460)
    padding: 0
    background: Rectangle {
        color: ui.raised
        border.color: ui.line
        radius: theme.radius
    }
    Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.55) }

    property var entries: []
    property int picked: 0
    readonly property var shown: {
        const q = field.text.trim().toLowerCase()
        if (q === "") return entries.filter(e => e.group !== "meeting" || e.recent)
        return entries.map(e => ({ e: e, s: score(e.label + " " + (e.detail || ""), q) }))
                      .filter(x => x.s > 0)
                      .sort((a, b) => b.s - a.s)
                      .slice(0, 40)
                      .map(x => x.e)
    }
    onShownChanged: picked = 0

    // Letters in order, with more for a run of them, for the start of a
    // word, and for an action over a meeting.
    function score(text, q) {
        const t = text.toLowerCase()
        if (t.indexOf(q) >= 0) return 100 - t.indexOf(q) + (t.startsWith(q) ? 50 : 0)
        let s = 0, at = 0, run = 0
        for (const ch of q) {
            const i = t.indexOf(ch, at)
            if (i < 0) return 0
            run = i === at ? run + 1 : 0
            s += 1 + run * 2 + (i === 0 || t[i - 1] === " " ? 3 : 0)
            at = i + 1
        }
        return s
    }

    function show() {
        build()
        field.text = ""
        open()
        field.forceActiveFocus()
    }

    function run(e) {
        if (!e || e.enabled === false) return
        close()
        Qt.callLater(e.run)
    }

    function build() {
        const out = []
        const add = (group, label, keys, run, extra) => out.push(Object.assign({ group: group, label: label, keys: keys || "", run: run }, extra || {}))
        const m = win.shown
        const has = m && m.id !== undefined
        const current = has && m.id === engine.current
        const stage = Sidecar.stage(m)
        const notes = stage === "ready" || stage === "sendFailed" || stage === "sent" || (stage === "skipped" && m.wrapup === "ready")

        // The meeting that's on gets its own group: End and Mark act on it,
        // whichever meeting is on screen.
        const on = engine.current !== "" ? engine.meetingById(engine.current) : null
        const live = on && win.shown.id === on.id ? "action" : "live"  // one group when it's the one on screen
        if (engine.connected)
            add(on ? live : "app", engine.listening ? qsTr("Pause listening") : engine.current !== "" ? qsTr("Resume listening") : qsTr("Start listening"),
                "space", () => engine.toggleListening())
        if (engine.current !== "") {
            add(live, qsTr("End the meeting"), "E", () => win.act("end", on))
            add(live, qsTr("Mark this moment"), "M", () => win.markNow())
        }
        if (has) {
            add("action", qsTr("Note"), "N", () => meetingPane.note())
            add("action", qsTr("Rename"), "R", () => meetingPane.rename())
            if (!current && (m.lines || 0) > 0 && stage !== "drafting")
                add("action", m.wrapup ? qsTr("Draft the wrap-up again") : qsTr("Draft the wrap-up"), "D", () => win.act("draft", m))
            if (!current && notes && stage !== "sent" && stage !== "sending")
                add("action", qsTr("Send to Notion"), "S", () => win.act("send", m))
            if (stage === "sent")
                add("action", qsTr("Open in Notion"), "O", () => win.act("notion", m))
            if (!current && m.wrapup === "ready")
                add("action", qsTr("Write the follow-up email"), "W", () => win.act("email", m))
            if (!current && notes)
                add("action", qsTr("Copy the wrap-up as Markdown"), "C", () => win.act("copyNotes", m))
            if ((m.lines || 0) > 0)
                add("action", qsTr("Copy the transcript"), "shift+C", () => win.act("copyTranscript", m))
            if (!current && stage !== "sent")
                add("action", m.skipped ? qsTr("Needs a wrap-up after all") : qsTr("No wrap-up needed"), "X", () => win.act("skip", m))
            if (!current && m.edited && stage !== "sent")
                add("action", qsTr("Go back to Opus's draft"), "", () => win.act("revert", m))
            if (!current && engine.current === "")
                add("action", qsTr("Continue this meeting"), "", () => win.act("listen", m))
            add("action", qsTr("Show its files"), "", () => win.act("files", m))
            if (!current)
                add("action", qsTr("Delete the meeting"), "del", () => win.act("delete", m), { danger: true })
        }

        add("app", win.view === "followups" ? qsTr("Go to meetings") : qsTr("Go to follow-ups"), "F",
            () => win.view = win.view === "followups" ? "meetings" : "followups")
        if (engine.current !== "") add("app", qsTr("Go to the meeting that's on"), "G", () => win.openFrom(engine.current, -1))
        add("app", qsTr("Start a new meeting"), "ctrl+N", () => win.newMeeting())
        add("app", qsTr("Ask the agent"), "/", () => { win.showAgent(); agentPane.input.forceActiveFocus() })
        add("app", qsTr("Ask across all meetings"), "ctrl+A", () => { win.showAgent(); agent.wide = true; agentPane.input.forceActiveFocus() })
        add("app", win.panelShown ? qsTr("Fold away the transcript and notes") : qsTr("Show the transcript and notes"), "]", () => win.togglePanel())
        add("app", win.listHidden ? qsTr("Show the meeting list") : qsTr("Hide the meeting list"), "\\", () => win.listHidden = !win.listHidden)
        add("app", qsTr("New chat with the agent"), "ctrl+shift+K", () => agent.forget())
        add("app", qsTr("Search what was said, in every meeting"), "ctrl+F", () => { win.listHidden = false; topBar.search.forceActiveFocus() })
        add("app", qsTr("Every key"), "?", () => keys.open())

        const s = engine.settings
        const flip = (key, onText, offText) => add("setting", s[key] !== false ? offText : onText, "",
                                                   () => engine.setSetting(key, !(s[key] !== false)))
        flip("watch_calls", qsTr("Turn on: record calls by itself"), qsTr("Turn off: record calls by itself"))
        flip("calendar_offers", qsTr("Turn on: offers before calendar meetings"), qsTr("Turn off: offers before calendar meetings"))
        flip("live_takeaways", qsTr("Turn on: live takeaways"), qsTr("Turn off: live takeaways"))
        flip("stop_on_silence", qsTr("Turn on: end after a long silence"), qsTr("Turn off: end after a long silence"))

        const meetings = engine.meetings.slice().sort((a, b) => (b.started || 0) - (a.started || 0))
        meetings.forEach((x, i) => add("meeting", x.title || qsTr("Untitled"), "", () => win.openFrom(x.id, -1),
                                       { detail: Sidecar.dayLabel(x) + "  ·  " + Sidecar.span(x), recent: i < 6, id: x.id }))
        entries = out
    }

    contentItem: ColumnLayout {
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 18
            Layout.rightMargin: 14
            Layout.preferredHeight: 52
            spacing: 10
            Label { text: "›"; color: theme.accent; font.pixelSize: 18; font.bold: true }
            TextInput {
                id: field
                Layout.fillWidth: true
                color: ui.text
                font.pixelSize: 15
                clip: true
                selectByMouse: true
                selectionColor: ui.alpha(theme.accent, 0.4)
                Label {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: field.text === ""
                    text: qsTr("Do something, or go to a meeting…")
                    color: ui.faint
                    font.pixelSize: 15
                }
                Keys.onDownPressed: popup.picked = Math.min(popup.shown.length - 1, popup.picked + 1)
                Keys.onUpPressed: popup.picked = Math.max(0, popup.picked - 1)
                Keys.onTabPressed: popup.picked = Math.min(popup.shown.length - 1, popup.picked + 1)
                Keys.onEscapePressed: popup.close()
                onAccepted: popup.run(popup.shown[popup.picked])
            }
            KeyCap { text: "esc" }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: ui.line }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            topMargin: 0
            bottomMargin: 6
            model: popup.shown
            currentIndex: popup.picked
            highlightMoveDuration: 0
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

            // A group's name above its first row.
            delegate: Column {
                id: row
                required property var modelData
                required property int index
                readonly property bool first: index === 0 || popup.shown[index - 1].group !== modelData.group
                width: list.width
                Label {
                    visible: row.first
                    width: parent.width
                    leftPadding: 18
                    topPadding: row.index === 0 ? 6 : 12
                    bottomPadding: 4
                    text: ({ live: qsTr("On now"), action: qsTr("On screen"), app: qsTr("Sidecar"), setting: qsTr("Settings"), meeting: qsTr("Meetings") })[row.modelData.group].toUpperCase()
                          + (row.modelData.group === "action" && win.shown.title ? "   " + win.shown.title
                             : row.modelData.group === "live" && engine.current !== "" ? "   " + (engine.meetingById(engine.current).title || "") : "")
                    elide: Text.ElideRight
                    color: ui.faint
                    font.pixelSize: 10
                    font.letterSpacing: 1.4
                    font.bold: true
                }
            Rectangle {
                width: parent.width
                height: 34
                color: row.index === popup.picked ? ui.alpha(theme.accent, 0.14) : rowHover.hovered ? ui.hover : "transparent"
                Rectangle { visible: row.index === popup.picked; width: 2; height: parent.height; color: theme.accent }
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 18
                    anchors.rightMargin: 16
                    spacing: 10
                    Label {
                        text: row.modelData.label
                        color: row.modelData.danger ? ui.danger : ui.text
                        font.pixelSize: 13
                        elide: Text.ElideRight
                        Layout.preferredWidth: implicitWidth
                        Layout.minimumWidth: Math.min(implicitWidth, 120)
                    }
                    Label {
                        Layout.fillWidth: true
                        Layout.preferredWidth: 0
                        text: row.modelData.detail || ""
                        color: ui.faint
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                    KeyCap { visible: row.modelData.keys !== ""; text: row.modelData.keys }
                }
                HoverHandler { id: rowHover }
                TapHandler { onTapped: popup.run(row.modelData) }
            }
            }

            Label {
                anchors.centerIn: parent
                visible: popup.shown.length === 0
                text: qsTr("Nothing matches “%1”").arg(field.text)
                color: ui.faint
                font.pixelSize: 13
            }
        }
    }
}
