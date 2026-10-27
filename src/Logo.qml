import QtQuick
import QtQuick.Shapes

// The icon, drawn in the theme's accent: a speech bubble with a sound wave
// in it. While listening, the wave is the call's own sound, stepped with the
// engine's level reports rather than animated every frame; at rest it's still.
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
            // Each bar answers a different slice of the loudest input, so
            // the wave has a shape and not just a height.
            readonly property real loud: {
                if (!root.running) return 0
                let v = 0
                for (const c of engine.channels) if (c.alive) v = Math.max(v, c.level || 0)
                return Math.min(1, Math.sqrt(v) * 4.5)
            }
            readonly property real level: root.running ? Math.max(0.18, Math.min(1, base * 0.5 + loud * (0.6 + 0.4 * Math.sin(index * 1.7 + loud * 9)))) : base
            width: 3.4 * root.size / 64
            radius: width / 2
            height: Math.max(width, level * 16 * root.size / 64)
            x: (20 + index * 6) * root.size / 64 - width / 2
            y: 29 * root.size / 64 - height / 2
            color: theme.accent
        }
    }
}
