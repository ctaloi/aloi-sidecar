import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "sidecar.js" as Sidecar

// Send to Notion: a new page in My Meetings, or, if something else already
// filed this meeting that day, filling in that page instead. Chris picks;
// nothing is merged by guessing. Enter makes a new page, 1–9 fill one in.
Rectangle {
    id: root
    color: Qt.rgba(0, 0, 0, 0.55)
    visible: false
    opacity: visible ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 110 } }

    property var meeting: ({})
    property string title: ""

    function open(m, title) {
        meeting = m
        root.title = title || m.title
        engine.findNotionPages(m.id)
        visible = true
        box.forceActiveFocus()
    }
    function close() { visible = false }
    function send(target) {
        engine.sendToNotion(meeting.id, target || "")
        visible = false
    }

    MouseArea { anchors.fill: parent; onClicked: root.close() }

    Rectangle {
        id: box
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 560)
        height: Math.min(parent.height - 48, content.implicitHeight + 48)
        radius: theme.radius
        color: ui.raised
        border.color: ui.line
        focus: true
        scale: root.visible ? 1 : 0.97
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Keys.onEscapePressed: root.close()
        Keys.onReturnPressed: root.send("")
        Keys.onEnterPressed: root.send("")
        Keys.onPressed: event => {
            const n = parseInt(event.text)
            if (n >= 1 && n <= engine.candidates.length) {
                root.send(engine.candidates[n - 1].id)
                event.accepted = true
            }
        }

        MouseArea { anchors.fill: parent }

        ColumnLayout {
            id: content
            anchors.fill: parent
            anchors.margins: 24
            spacing: 14

            ColumnLayout {
                spacing: 4
                Label {
                    Layout.fillWidth: true
                    text: qsTr("Send to Notion")
                    color: ui.text
                    font.pixelSize: 16
                    font.bold: true
                }
                Label {
                    Layout.fillWidth: true
                    text: qsTr("“%1” goes to your private My Meetings database.").arg(root.title)
                    color: ui.muted
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }
            }

            // The usual choice: a page of its own.
            Choice {
                Layout.fillWidth: true
                primary: true
                keys: "enter"
                heading: qsTr("New page")
                detail: qsTr("Summary, follow-ups as to-dos, decisions, questions, and the transcript folded away")
                onPicked: root.send("")
            }

            Label {
                Layout.topMargin: 4
                text: qsTr("OR FILL IN A PAGE FROM THAT DAY")
                color: ui.muted
                font.pixelSize: 10
                font.letterSpacing: 1.4
                visible: engine.candidatesLoading || engine.candidates.length > 0
            }
            Label {
                visible: engine.candidatesLoading
                text: qsTr("Looking in Notion…")
                color: ui.faint
                font.pixelSize: 12
            }
            Label {
                Layout.fillWidth: true
                visible: engine.candidatesError !== ""
                text: engine.candidatesError
                color: ui.danger
                font.pixelSize: 12
                wrapMode: Text.Wrap
            }
            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: Math.min(pages.implicitHeight, 300)
                visible: engine.candidates.length > 0
                clip: true
                ColumnLayout {
                    id: pages
                    width: parent.width
                    spacing: 6
                    Repeater {
                        model: engine.candidates
                        delegate: Choice {
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true
                            keys: index < 9 ? String(index + 1) : ""
                            heading: modelData.title
                            detail: (modelData.summary || qsTr("No summary"))
                            meta: Sidecar.clock(Date.parse(modelData.created) / 1000)
                            onPicked: root.send(modelData.id)
                        }
                    }
                }
            }
            Label {
                Layout.fillWidth: true
                visible: engine.candidates.length > 0
                text: qsTr("Filling in keeps what's on the page; Sidecar's notes go under their own heading, and only empty fields are set.")
                color: ui.faint
                font.pixelSize: 11
                wrapMode: Text.Wrap
            }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                ActionButton { text: qsTr("Cancel"); keys: "esc"; onClicked: root.close() }
            }
        }
    }

    component Choice: Rectangle {
        id: choice
        property string heading
        property string detail
        property string meta
        property string keys
        property bool primary: false
        signal picked()
        implicitHeight: choiceRow.implicitHeight + 20
        radius: Math.min(6, theme.radius)
        color: hover.hovered ? ui.hover : primary ? ui.alpha(theme.accent, 0.08) : "transparent"
        border.color: primary ? ui.alpha(theme.accent, 0.55) : ui.line
        RowLayout {
            id: choiceRow
            anchors.fill: parent
            anchors.margins: 10
            anchors.leftMargin: 14
            spacing: 12
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 3
                RowLayout {
                    spacing: 8
                    Label {
                        Layout.fillWidth: true
                        text: choice.heading
                        color: ui.text
                        font.pixelSize: 13
                        font.bold: true
                        elide: Text.ElideRight
                    }
                    Label { visible: choice.meta !== ""; text: choice.meta; color: ui.faint; font.pixelSize: 11 }
                }
                Label {
                    Layout.fillWidth: true
                    text: choice.detail
                    color: ui.muted
                    font.pixelSize: 11
                    elide: Text.ElideRight
                    maximumLineCount: 2
                    wrapMode: Text.Wrap
                }
            }
            KeyCap { visible: choice.keys !== ""; text: choice.keys; tone: choice.primary ? theme.accent : ui.faint }
        }
        HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: choice.picked() }
    }
}
