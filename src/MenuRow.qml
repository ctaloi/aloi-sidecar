import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// One row of a SideMenu: what it does, and its key. A row that isn't
// visible takes no room, so a menu can list everything and show what fits.
MenuItem {
    id: item
    property string keys
    property bool danger: false
    // A setting: a tick shows when it's on. (Not MenuItem's checkable,
    // which would flip itself and stop following the engine.)
    property bool setting: false
    property bool on: false
    implicitHeight: visible ? 34 : 0
    height: implicitHeight
    leftPadding: 12
    rightPadding: 12
    contentItem: RowLayout {
        spacing: 24
        Text {
            visible: item.setting
            text: item.on ? "✓" : ""
            color: theme.accent
            font.pixelSize: 12
            Layout.preferredWidth: 10
        }
        Text {
            text: item.text
            color: !item.enabled ? ui.faint : item.danger ? ui.danger : ui.text
            font.pixelSize: 12
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
        Text {
            visible: item.keys !== ""
            text: item.keys
            color: item.enabled ? theme.accent : ui.faint
            font.pixelSize: 11
        }
    }
    indicator: null
    background: Rectangle {
        radius: Math.min(4, theme.radius)
        color: item.highlighted ? ui.hover : "transparent"
    }
}
