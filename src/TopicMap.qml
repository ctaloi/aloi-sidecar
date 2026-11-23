import QtQuick
import QtQuick.Controls
import "topicmap.js" as Placing

// The topics as a map: a dot apiece, as big as the meetings it came up in
// and lit if it came up this week, with a line between two that come up
// together. Pointing at one shows what it's tied to; a click opens it.
Item {
    id: map

    // [{name, count, recent, ...}], most-discussed first; a small map shows fewer.
    property var all: []
    readonly property var topics: all.slice(0, Math.max(6, Math.floor(width * height / 11000)))
    property var links: []    // [{a, b, n}]
    property string pinned: ""
    property string hovered: ""
    readonly property string active: hovered !== "" ? hovered : pinned
    // Pointed at (empty: a click on nothing lets go), and clicked to open.
    signal pointed(string name)
    signal opened(string name)

    readonly property int most: topics.reduce((a, t) => Math.max(a, t.count), 1)
    readonly property int mostLinked: links.reduce((a, l) => Math.max(a, l.n), 1)
    // Who each topic is tied to: {name: {other: true}}.
    readonly property var ties: {
        const out = {}
        for (const l of links) {
            (out[l.a] = out[l.a] || {})[l.b] = true;
            (out[l.b] = out[l.b] || {})[l.a] = true
        }
        return out
    }
    function near(name) { return active === "" || name === active || !!(ties[active] && ties[active][name]) }
    function radius(t) { return 6 + 16 * Math.sqrt(t.count / most) }

    readonly property int nameWidth: 116
    FontMetrics { id: metrics; font.pixelSize: 11 }
    property var spots: ({})
    function place() {
        if (width < 80 || height < 80) return
        spots = Placing.layout(topics.map(t => {
            const wide = metrics.advanceWidth(t.name)
            return { name: t.name, r: radius(t), lw: Math.min(wide, nameWidth) + 2, lh: wide > nameWidth ? 28 : 14 }
        }), links, width, height)
        lines.requestPaint()
    }
    onTopicsChanged: place()
    onLinksChanged: place()
    // Not on every pixel of a resize.
    onWidthChanged: settle.restart()
    onHeightChanged: settle.restart()
    Timer { id: settle; interval: 60; onTriggered: map.place() }
    onActiveChanged: lines.requestPaint()

    // A click on nothing lets go of the pinned topic.
    MouseArea { anchors.fill: parent; onClicked: map.pointed("") }

    Canvas {
        id: lines
        anchors.fill: parent
        readonly property color quiet: ui.muted
        readonly property color lit: theme.accent
        onQuietChanged: requestPaint()
        onLitChanged: requestPaint()
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            ctx.lineCap = "round"
            for (const l of map.links) {
                const a = map.spots[l.a], b = map.spots[l.b]
                if (!a || !b) continue
                const weight = l.n / map.mostLinked
                const mine = map.active !== "" && (l.a === map.active || l.b === map.active)
                ctx.strokeStyle = mine ? ui.alpha(lit, 0.85)
                                : ui.alpha(quiet, map.active !== "" ? 0.10 : 0.16 + 0.30 * weight)
                ctx.lineWidth = 1 + 2.5 * weight
                ctx.beginPath()
                ctx.moveTo(a.x, a.y)
                ctx.lineTo(b.x, b.y)
                ctx.stroke()
            }
        }
    }

    Repeater {
        model: map.topics
        Item {
            id: node
            required property var modelData
            readonly property string name: modelData.name
            readonly property var spot: map.spots[name] || null
            readonly property real r: map.radius(modelData)
            readonly property bool on: map.active === name
            // Lit by how much of it was this week; grey if none was.
            readonly property real heat: modelData.recent > 0 ? 0.35 + 0.65 * modelData.recent / modelData.count : 0
            visible: spot !== null
            x: spot ? spot.x : 0
            y: spot ? spot.y : 0
            opacity: map.near(name) ? 1 : 0.25
            Behavior on opacity { NumberAnimation { duration: 140 } }

            Rectangle {
                x: -node.r - 4; y: -node.r - 4
                width: 2 * node.r + 8; height: width; radius: width / 2
                visible: node.on || map.pinned === node.name
                color: "transparent"
                border.color: theme.accent
                border.width: map.pinned === node.name ? 2 : 1
            }
            Rectangle {
                x: -node.r; y: -node.r
                width: 2 * node.r; height: width; radius: node.r
                color: node.heat > 0 ? Qt.tint(ui.panel, ui.alpha(theme.accent, 0.20 + 0.75 * node.heat))
                                     : Qt.tint(ui.panel, ui.alpha(ui.muted, 0.30))
                border.color: node.heat > 0 ? theme.accent : ui.alpha(ui.muted, 0.7)
                Label {
                    anchors.centerIn: parent
                    visible: node.r >= 11
                    text: node.modelData.count
                    color: node.heat > 0.55 ? theme.background : ui.text
                    font.pixelSize: 10
                    font.bold: true
                }
            }
            // Behind the name, so a line passing under it doesn't strike it through.
            Rectangle {
                x: nameLabel.x - 3; y: nameLabel.y
                width: nameLabel.width + 6; height: nameLabel.height
                radius: 3
                color: ui.alpha(ui.panel, 0.82)
            }
            Label {
                id: nameLabel
                x: -width / 2
                y: node.r + 5
                width: Math.min(metrics.advanceWidth(node.name), map.nameWidth) + 2
                text: node.name
                color: node.on ? theme.accent : node.heat > 0 ? ui.text : ui.muted
                font.pixelSize: 11
                font.bold: node.on
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }
            MouseArea {
                x: -Math.max(node.r, nameLabel.width / 2) - 3
                y: -node.r - 3
                width: 2 * Math.max(node.r, nameLabel.width / 2) + 6
                height: node.r + 3 + node.r + 5 + nameLabel.height
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: { map.hovered = node.name; map.pointed(node.name) }
                onExited: if (map.hovered === node.name) map.hovered = ""
                onClicked: map.opened(node.name)
            }
        }
    }
}
