import QtQuick

// Where a meeting is after the call, as a chip: drafting, ready to check,
// sending, in Notion, set aside.
Chip {
    id: chip
    property string stage
    property var m: ({})
    readonly property var look: ({
        drafting: [qsTr("Drafting wrap-up…"), theme.accent, "clock", false],
        ready: [m.edited ? qsTr("Wrap-up edited") : qsTr("Wrap-up ready"), theme.accent, "draft", true],
        draftFailed: [qsTr("Wrap-up failed"), ui.danger, "alert", false],
        sending: [qsTr("Sending to Notion…"), theme.accent, "send", false],
        sendFailed: [qsTr("Notion send failed"), ui.danger, "alert", true],
        sent: [qsTr("In Notion"), ui.them, "check", true],
        skipped: [qsTr("No wrap-up needed"), ui.faint, "close", false],
        none: [qsTr("Needs wrap-up"), ui.muted, "notes", false]
    })
    visible: !!look[stage] && !(stage === "none" && !(m.lines > 0))
    text: look[stage] ? look[stage][0] : ""
    tone: look[stage] ? look[stage][1] : ui.muted
    glyph: look[stage] ? look[stage][2] : ""
    strong: look[stage] ? look[stage][3] : false
}
