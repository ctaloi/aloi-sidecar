import QtQuick

// Who's talking, over the last stretch of the call: the other side rises
// above the line in their color, you dip below it in yours, scrolling left
// as it goes. A glance says whether the call is flowing, one-sided or quiet.
Item {
    id: trace
    implicitWidth: 260
    implicitHeight: 30
    property bool running: engine.listening && visible
    readonly property int samples: Math.max(10, Math.floor(width / 4))
    property var me: []
    property var them: []

    function level(speaker) {
        let v = 0
        for (const c of engine.channels)
            if (c.alive && (speaker === "Them") === (c.speaker === "Them")) v = Math.max(v, c.level || 0)
        // Speech levels are small and bunched near zero; a square root spreads them out.
        return Math.min(1, Math.sqrt(v) * 4.5)
    }

    Timer {
        interval: 120
        repeat: true
        running: trace.running
        onTriggered: {
            const n = trace.samples
            trace.me = trace.me.concat([trace.level("Me")]).slice(-n)
            trace.them = trace.them.concat([trace.level("Them")]).slice(-n)
            canvas.requestPaint()
        }
    }
    onRunningChanged: if (!running) { me = []; them = []; canvas.requestPaint() }

    // Which side is which, quietly, at the left.
    Text { x: 0; y: 0; text: qsTr("them"); color: ui.alpha(ui.them, 0.7); font.pixelSize: 9 }
    Text { x: 0; anchors.bottom: parent.bottom; text: qsTr("you"); color: ui.alpha(ui.me, 0.7); font.pixelSize: 9 }

    Canvas {
        id: canvas
        anchors.fill: parent
        anchors.leftMargin: 34
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            const mid = height / 2, n = trace.samples, step = width / n
            ctx.fillStyle = ui.alpha(ui.text, 0.08)
            ctx.fillRect(0, mid, width, 1)
            const draw = (values, color, up) => {
                ctx.fillStyle = color
                const offset = n - values.length
                for (let i = 0; i < values.length; i++) {
                    const h = Math.max(1, values[i] * (mid - 1))
                    // Older samples fade toward the left edge.
                    ctx.globalAlpha = 0.25 + 0.75 * ((i + offset) / n)
                    ctx.fillRect((i + offset) * step, up ? mid - h : mid + 1, Math.max(1, step - 1), h)
                }
                ctx.globalAlpha = 1
            }
            draw(trace.them, ui.them, true)
            draw(trace.me, ui.me, false)
        }
    }
}
