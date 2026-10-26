import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Another app has the mic (Teams, Zoom, a browser tab), and Sidecar isn't
// listening: a call, most likely. A strip across the top offers to listen,
// the same offer the desktop notification makes.
Rectangle {
    id: banner
    readonly property var call: engine.call
    property real dismissed: 0
    readonly property bool wanted: !!call.app && !engine.listening && call.since !== dismissed
    implicitHeight: wanted ? row.implicitHeight + 20 : 0
    visible: implicitHeight > 0
    clip: true
    color: ui.wash(ui.live, 0.12)
    Behavior on implicitHeight { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: ui.alpha(ui.live, 0.35) }

    RowLayout {
        id: row
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 32
        anchors.rightMargin: 20
        spacing: 12
        Rectangle {
            width: 9; height: 9; radius: 4.5
            color: ui.live
            SequentialAnimation on opacity {
                running: banner.visible
                loops: Animation.Infinite
                NumberAnimation { to: 0.3; duration: 800 }
                NumberAnimation { to: 1; duration: 800 }
            }
        }
        Label {
            Layout.fillWidth: true
            elide: Text.ElideRight
            textFormat: Text.StyledText
            text: "<b>" + qsTr("%1 is using your mic").arg(banner.call.app || "") + "</b>"
                  + "<font color='" + ui.muted + "'>  ·  " + qsTr("listen to this call?") + "</font>"
            color: ui.text
            font.pixelSize: 13
        }
        ActionButton { text: qsTr("Not now"); onClicked: banner.dismissed = banner.call.since }
        // A new call is a new meeting, even if an earlier one is paused.
        ActionButton { primary: true; text: qsTr("Listen"); onClicked: engine.startMeeting() }
    }
}
