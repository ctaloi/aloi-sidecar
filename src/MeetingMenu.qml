import QtQuick
import QtQuick.Controls
import "sidecar.js" as Sidecar

// Everything that can be done with one meeting, from a right-click on it in
// the list or the ⋯ beside its title. Each row names its key, and only the
// rows that make sense for where the meeting is show up.
SideMenu {
    id: menu
    property var m: ({})
    readonly property string stage: Sidecar.stage(m)
    readonly property bool isCurrent: !!m.id && m.id === engine.current
    readonly property bool shown: !!m.id && m.id === engine.selected
    readonly property bool hasNotes: stage === "ready" || stage === "sendFailed" || stage === "sent" || stage === "sending"
                                     || (stage === "skipped" && m.wrapup === "ready")

    function show(meeting, item, x, y) {
        m = meeting
        if (item) popup(item, x, y)
        else popup()
    }

    MenuRow { text: qsTr("Open"); visible: !menu.shown; onTriggered: engine.select(menu.m.id) }
    MenuRow {
        text: engine.listening && menu.isCurrent ? qsTr("Pause listening") : menu.isCurrent ? qsTr("Resume listening") : qsTr("Continue this meeting")
        keys: menu.isCurrent ? "space" : ""
        onTriggered: win.act("listen", menu.m)
    }
    MenuRow { text: qsTr("End meeting…"); keys: "e"; visible: menu.isCurrent; onTriggered: win.act("end", menu.m) }
    MenuRow { text: qsTr("Rename…"); keys: "r"; onTriggered: win.act("rename", menu.m) }
    MenuLine {}
    MenuRow {
        text: menu.stage === "drafting" ? qsTr("Drafting the wrap-up…")
            : (menu.m.wrapup ? qsTr("Draft the wrap-up again…") : qsTr("Draft the wrap-up"))
        keys: "d"
        visible: !menu.isCurrent
        enabled: menu.stage !== "drafting" && (menu.m.lines || 0) > 0
        onTriggered: win.act("draft", menu.m)
    }
    MenuRow {
        text: qsTr("Do it all: Notion and the email draft")
        keys: "a"
        visible: menu.stage !== "sent" && !menu.isCurrent
        enabled: menu.m.wrapup === "ready" && menu.stage !== "sending"
        onTriggered: win.act("finish", menu.m)
    }
    MenuRow {
        text: menu.stage === "sendFailed" ? qsTr("Try sending to Notion again") : qsTr("Send to Notion…")
        keys: "s"
        visible: menu.stage !== "sent" && !menu.isCurrent
        enabled: menu.hasNotes && menu.stage !== "sending"
        onTriggered: win.act("send", menu.m)
    }
    MenuRow {
        text: qsTr("Write the follow-up email…")
        keys: "w"
        visible: !menu.isCurrent
        enabled: menu.m.wrapup === "ready"
        onTriggered: win.act("email", menu.m)
    }
    MenuRow { text: qsTr("Open in Notion"); keys: "o"; visible: menu.stage === "sent"; onTriggered: win.act("notion", menu.m) }
    MenuRow {
        text: qsTr("Go back to Opus's draft…")
        visible: !!menu.m.edited && menu.stage !== "sent"
        onTriggered: win.act("revert", menu.m)
    }
    MenuRow { text: qsTr("Copy the wrap-up as Markdown"); keys: "c"; enabled: menu.hasNotes; visible: !menu.isCurrent; onTriggered: win.act("copyNotes", menu.m) }
    MenuRow { text: qsTr("Copy the transcript"); keys: "C"; enabled: (menu.m.lines || 0) > 0; onTriggered: win.act("copyTranscript", menu.m) }
    MenuLine {}
    MenuRow {
        text: menu.m.skipped ? qsTr("Needs a wrap-up after all") : qsTr("No wrap-up needed")
        keys: "x"
        visible: !menu.isCurrent && menu.stage !== "sent"
        onTriggered: win.act("skip", menu.m)
    }
    MenuRow {
        text: qsTr("Merge with another meeting…")
        visible: !menu.isCurrent
        onTriggered: win.act("merge", menu.m)
    }
    MenuRow { text: qsTr("Show its files"); visible: !!menu.m.id; onTriggered: win.act("files", menu.m) }
    MenuRow {
        text: qsTr("Delete meeting…")
        keys: "del"
        danger: true
        enabled: !menu.isCurrent
        onTriggered: win.act("delete", menu.m)
    }
}
