import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "sidecar.js" as Sidecar

// The window rolled up to its bar (B, or ▴ in the top bar): whether
// it's listening and for how long, and the words going by, pinned on every
// workspace. B or ▾ rolls it back down.
Rectangle {
    id: bar
    implicitHeight: 40
    color: ui.window

    property double now: Date.now()
    // A word that something happened (the toast's), in place of the words.
    property string notice: ""
    signal unshade()

    readonly property var on: engine.current !== "" ? engine.meetingById(engine.current) : null
    // What's being said: the words still coming, else the meeting's last
    // line while it's on screen, else which meeting it is.
    readonly property var line: {
        const live = engine.interims
        if (engine.listening && live.length > 0) {
            const l = live[live.length - 1]
            return { speaker: l.speaker, who: l.speaker === "Them" ? qsTr("Them") : qsTr("Me"), text: l.text }
        }
        if (on && engine.selected === engine.current && transcript.last.text) return transcript.last
        return null
    }

    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: ui.line }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 8
        spacing: 12

        Logo { size: 22; running: engine.listening }

        // Listening, paused or offline, and the switch for it, with the
        // time it's been on.
        Rectangle {
            implicitWidth: pillRow.implicitWidth + 18
            implicitHeight: 26
            radius: Math.min(4, theme.radius)
            color: engine.listening ? ui.alpha(ui.live, pillHover.hovered ? 0.26 : 0.16)
                                    : (pillHover.hovered ? ui.hover : "transparent")
            border.color: engine.listening ? ui.alpha(ui.live, 0.7) : !engine.connected ? ui.alpha(ui.danger, 0.6) : ui.line
            Row {
                id: pillRow
                anchors.centerIn: parent
                spacing: 7
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 8; height: 8; radius: 4
                    color: engine.listening ? ui.live : engine.connected ? ui.muted : ui.faint
                }
                Label {
                    anchors.verticalCenter: parent.verticalCenter
                    text: !engine.connected ? qsTr("Offline")
                        : engine.listening && bar.on ? Sidecar.elapsed(bar.on, bar.now)
                        : bar.on ? qsTr("Paused") : qsTr("Not listening")
                    color: engine.connected ? ui.text : ui.danger
                    font.pixelSize: 12
                    font.bold: engine.listening
                    font.features: { "tnum": 1 }
                }
                Row {
                    visible: engine.listening
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Repeater {
                        model: engine.channels
                        delegate: Rectangle {
                            required property var modelData
                            width: 3; height: 12
                            radius: 1
                            color: ui.alpha(ui.text, 0.12)
                            opacity: modelData.alive ? 1 : 0.35
                            Rectangle {
                                anchors.bottom: parent.bottom
                                width: parent.width
                                radius: 1
                                height: Math.max(2, Math.min(parent.height, Math.sqrt(modelData.level) * parent.height * 3))
                                color: modelData.speaker === "Them" ? ui.them : ui.me
                            }
                        }
                    }
                }
            }
            HoverHandler { id: pillHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: engine.toggleListening() }
            ToolTip.visible: pillHover.hovered
            ToolTip.delay: 500
            ToolTip.text: engine.listening ? qsTr("Pause (Space)") : qsTr("Listen (Space)")
        }

        // The words going by, newest at the end: who, then what.
        RowLayout {
            Layout.fillWidth: true
            spacing: 7
            clip: true
            Label {
                visible: bar.notice === "" && bar.line !== null
                text: bar.line ? bar.line.who : ""
                color: bar.line && bar.line.speaker === "Them" ? ui.them : ui.me
                font.pixelSize: 12
                font.bold: true
            }
            Label {
                Layout.fillWidth: true
                text: bar.notice !== "" ? "✓ " + bar.notice
                    : bar.line ? bar.line.text
                    : bar.on ? bar.on.title || ""
                    : engine.selectedMeeting.title || ""
                color: bar.notice !== "" || bar.line ? ui.text : ui.muted
                font.pixelSize: 12
                // The end of what's said is the newest part of it.
                elide: bar.line && bar.notice === "" ? Text.ElideLeft : Text.ElideRight
                maximumLineCount: 1
            }
        }

        ActionButton {
            implicitHeight: 26
            text: "▾"
            tip: qsTr("Roll back down (B)")
            onClicked: bar.unshade()
        }
    }
}
