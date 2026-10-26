import QtQuick
import QtQuick.Controls

// A menu in the window's colors, the way Tix draws its own: rows with the
// key that does the same on the right, gone the moment it closes so the
// next key press counts.
Menu {
    id: menu
    margins: 8
    padding: 6
    background: Rectangle {
        implicitWidth: 290
        color: ui.raised
        border.color: ui.line
        radius: Math.min(8, theme.radius)
    }
    enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 90 } }
    exit: Transition {}
}
