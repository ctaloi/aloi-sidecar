import QtQuick

// Where a meeting is after the call, as a chip: drafting, ready to check,
// sending, in Notion, set aside.
Chip {
    id: chip
    property string stage
    property var m: ({})
    readonly property var look: ({
        drafting: [qsTr("Drafting wrap-up…"), theme.accent, "◌", false],
        ready: [m.edited ? qsTr("Wrap-up edited") : qsTr("Wrap-up ready"), theme.accent, "●", true],
        draftFailed: [qsTr("Wrap-up failed"), ui.danger, "!", false],
        sending: [qsTr("Sending to Notion…"), theme.accent, "↑", false],
        sendFailed: [qsTr("Notion send failed"), ui.danger, "!", true],
        sent: [qsTr("In Notion"), ui.them, "✓", true],
        skipped: [qsTr("No wrap-up needed"), ui.faint, "–", false],
        none: [qsTr("Needs wrap-up"), ui.muted, "○", false]
    })
    visible: !!look[stage] && !(stage === "none" && !(m.lines > 0))
    text: look[stage] ? look[stage][0] : ""
    tone: look[stage] ? look[stage][1] : ui.muted
    glyph: look[stage] ? look[stage][2] : ""
    filled: look[stage] ? look[stage][3] : false
}
