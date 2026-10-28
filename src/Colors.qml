import QtQuick

// The window's colors: Aloi's own, from the Omarchy theme so Sidecar matches
// the desktop (and switches with it), and what they mean in Sidecar.
BaseColors {
    // Chris speaks in the accent; everyone else in one calm green that
    // stays the same in every theme, so the two sides never blur.
    readonly property color me: theme.accent
    readonly property color them: theme.dark ? "#6fcf97" : "#1f7a4a"
    readonly property color live: theme.dark ? "#ff6b6b" : "#c9302c"
}
