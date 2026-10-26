import QtQuick
import QtQuick.Shapes

// The icon, drawn in the theme's accent: a speech bubble with a sound wave
// in it. While listening, the wave moves; at rest it's still.
Item {
    id: root
    property int size: 26
    property bool running: false
    width: size
    height: size
    layer.enabled: true
    layer.samples: 4

    Rectangle {
        anchors.fill: parent
        radius: Math.max(4, theme.radius * 2) * root.size / 64
        color: theme.accent
    }
    Shape {
        anchors.fill: parent
        scale: root.size / 64
        transformOrigin: Item.TopLeft
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            fillColor: ui.window
            strokeColor: "transparent"
            PathSvg { path: "M12 15h40a4 4 0 0 1 4 4v20a4 4 0 0 1-4 4H28l-9 8v-8h-7a4 4 0 0 1-4-4V19a4 4 0 0 1 4-4z" }
        }
    }
    Repeater {
        model: 5
        delegate: Rectangle {
            required property int index
            readonly property real base: [0.25, 0.6, 0.9, 0.55, 0.3][index]
            property real level: base
            width: 3.4 * root.size / 64
            radius: width / 2
            height: Math.max(width, level * 16 * root.size / 64)
            x: (20 + index * 6) * root.size / 64 - width / 2
            y: 29 * root.size / 64 - height / 2
            color: theme.accent
            SequentialAnimation on level {
                running: root.running
                loops: Animation.Infinite
                NumberAnimation { to: 1 - base * 0.6; duration: 420 + index * 90; easing.type: Easing.InOutSine }
                NumberAnimation { to: base; duration: 420 + index * 90; easing.type: Easing.InOutSine }
            }
        }
    }
}
