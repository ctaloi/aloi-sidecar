import QtQuick

// The window's colors, from the Omarchy theme so Sidecar matches the
// desktop (and switches with it). Theme falls back to a dark palette.
QtObject {
    readonly property color window: theme.background
    readonly property color panel: theme.panel
    readonly property color raised: theme.raised
    readonly property color hover: theme.selection
    readonly property color line: theme.line
    readonly property color text: theme.foreground
    readonly property color muted: theme.muted
    readonly property color faint: theme.faint
    readonly property color danger: theme.danger
    // Chris speaks in the accent; everyone else in one calm green that
    // stays the same in every theme, so the two sides never blur.
    readonly property color me: theme.accent
    readonly property color them: theme.dark ? "#6fcf97" : "#1f7a4a"
    readonly property color live: theme.dark ? "#ff6b6b" : "#c9302c"

    function alpha(c, a) { const k = Qt.color(c); return Qt.rgba(k.r, k.g, k.b, a) }
    function wash(c, a) { return Qt.tint(panel, alpha(c, a === undefined ? 0.08 : a)) }
}
