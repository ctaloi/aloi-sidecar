import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

import "Model.js" as Model

// The dot's panel: Sidecar the recorder, nothing else. What it's listening
// to and for how long, with Stop and Open; or Listen, which names the call
// from the calendar on its own; and the calls still to wrap up. The day's
// meetings are in the clock (Aloi Calendar).
Item {
  id: root
  property var host: null
  property var service: null
  property alias keyCatcher: keyCatcher

  readonly property var bar: host ? host.bar : null
  function close() { if (host) host.close() }
  function switchPanel(direction) { return host ? host.switchPanel(direction) : false }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var sc: service ? service.sidecar : ({ connected: false })
  readonly property bool connected: sc.connected === true
  readonly property bool listening: connected && !!sc.listening
  readonly property real now: service ? service.now : Date.now()

  implicitHeight: column.implicitHeight

  function t(key, values) { return host ? host.t(key, values) : key }
  function reset() { Qt.callLater(function() { if (host && host.opened) keyCatcher.forceActiveFocus() }) }

  PanelKeyCatcher {
    id: keyCatcher
    anchors.fill: parent
    onCloseRequested: root.close()
    onTabRequested: function(direction) { root.switchPanel(direction) }
    onActivateRequested: { if (root.service) root.service.toggleListening() }
    onTextKey: function(text) {
      if ((text === "o" || text === "O") && root.service) { root.service.openSidecar(); root.close() }
    }

    Column {
      id: column
      width: parent.width
      spacing: Style.space(12)

      // ---------- The dot, big, and what it means ----------
      Item {
        width: parent.width
        implicitHeight: Math.max(bigDot.height, labels.implicitHeight, actions.implicitHeight)

        Rectangle {
          id: bigDot
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(18)
          height: width
          radius: width / 2
          color: root.listening ? Color.urgent : "transparent"
          border.width: root.listening ? 0 : Style.space(2)
          border.color: root.dim
          SequentialAnimation on opacity {
            running: root.listening && host !== null && host.opened
            loops: Animation.Infinite
            onRunningChanged: if (!running) bigDot.opacity = 1
            NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
          }
        }

        Column {
          id: labels
          anchors.left: bigDot.right
          anchors.leftMargin: Style.space(14)
          anchors.right: actions.left
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.listening ? (root.sc.title || root.t("event.untitled")) : root.t("panel.title")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: (!root.connected ? root.t("panel.offline")
                  : root.listening ? root.t("panel.listening", { time: host ? host.span(Math.max(0, Math.floor((root.now - root.sc.started) / 60000))) : "" })
                  : root.t("panel.idle")).toUpperCase()
            color: root.listening ? Color.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            elide: Text.ElideRight
          }
        }

        Row {
          id: actions
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)
          Button {
            visible: root.connected
            text: root.listening ? root.t("panel.stop") : root.t("panel.listen")
            tooltipText: root.listening ? "" : root.t("panel.listenTooltip")
            fontSize: Style.font.bodySmall
            foreground: root.listening ? Color.urgent : root.foreground
            fontFamily: root.fontFamily
            bordered: true
            onClicked: { if (root.service) root.service.toggleListening(); if (!root.listening) root.close() }
          }
          Button {
            text: root.t("panel.open")
            fontSize: Style.font.bodySmall
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            onClicked: { if (root.service) root.service.openSidecar(); root.close() }
          }
        }
      }

      // ---------- Calls still to wrap up ----------
      Text {
        visible: root.connected && (root.sc.toWrapUp || 0) > 0
        textFormat: Text.PlainText
        text: root.sc.toWrapUp === 1 ? root.t("panel.wrapUpOne") : root.t("panel.wrapUp", { count: root.sc.toWrapUp })
        color: wrapUpMouse.containsMouse ? Color.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.underline: wrapUpMouse.containsMouse
        MouseArea {
          id: wrapUpMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: { if (root.service) root.service.openSidecar(); root.close() }
        }
      }
    }
  }
}
