import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

import "Model.js" as Model
import "Registry.js" as Registry

// A recording dot: a quiet ring while Sidecar isn't listening, solid red
// (breathing) while it is. The calendar itself lives in the clock now (Aloi
// Calendar); this is only whether Sidecar is listening. Like Omarchy's own
// panels, the widget itself is the Panel: click for the meeting on now or
// next (join, listen) and Sidecar's controls; right-click joins the meeting
// that's on.
Panel {
  id: root
  moduleName: "aloi.sidecar"

  property var service: null
  readonly property int maxTitle: Number(setting("maxTitleLength", 28))
  readonly property var sidecar: service ? service.sidecar : ({ connected: false })
  readonly property bool listening: !!sidecar.listening

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function t(key, values) {
    var text = strings.t(key)
    for (var name in values) text = text.split("{" + name + "}").join(String(values[name]))
    return text
  }

  function span(minutes) {
    var d = Model.duration(minutes)
    if (d.hours === 0) return t("time.minutes", { m: d.minutes })
    if (d.minutes === 0) return t("time.hours", { h: d.hours })
    return t("time.hoursMinutes", { h: d.hours, m: d.minutes })
  }

  // What the dot means, said on hover.
  readonly property string tooltip: {
    if (sidecar.connected === false) return t("bar.tooltipOffline")
    if (!listening) return t("bar.tooltip")
    var minutes = Math.max(0, Math.floor(((service ? service.now : Date.now()) - sidecar.started) / 60000))
    return t("bar.listening", { title: Model.shortTitle(sidecar.title || t("event.untitled"), root.maxTitle), time: span(minutes) })
  }

  function bindService() {
    if (root.service) return
    var host = bar && bar.shell ? bar.shell : null
    var s = host && typeof host.serviceFor === "function" ? host.serviceFor("aloi.sidecar") : null
    root.service = s || Registry.get()
  }

  Timer {
    interval: 250
    repeat: true
    running: !root.service
    triggeredOnStart: true
    onTriggered: root.bindService()
  }

  // Settings live on the bar entry; the shared service runs with them.
  Binding {
    target: root.service
    property: "settings"
    value: root.settings
    when: root.service !== null
  }

  Binding {
    target: root.service
    property: "panelOpen"
    value: root.opened
    when: root.service !== null
  }

  function open() {
    content.reset()
    root.controller.show()
  }

  function close() { root.controller.hide() }
  function toggle() { if (root.opened) root.close(); else root.open() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    fixedWidth: Style.space(26)
    dimmed: root.sidecar.connected === false
    tooltipText: root.tooltip

    // The dot: a ring when idle, solid red while listening. Steady, never
    // pulsing: a pulse redraws every bar on every monitor for the whole call.
    Rectangle {
      anchors.centerIn: parent
      width: Style.space(9)
      height: width
      radius: width / 2
      color: root.listening ? Commons.Color.urgent : "transparent"
      border.width: root.listening ? 0 : Math.max(1, Style.space(1.5))
      border.color: Qt.darker(button.foreground, 1.35)
    }
    // Left: the panel. Right: listen, or stop, right away.
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) { if (root.service) root.service.toggleListening() }
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: content.keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(380))
    contentHeight: popup.fittedContentHeight(content.implicitHeight, Style.space(240))

    RecorderContent {
      id: content
      anchors.fill: parent
      host: root
      service: root.service
    }
  }

  IpcHandler {
    target: "aloi.sidecar"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function listen(): void { if (root.service && !root.listening) root.service.toggleListening() }
    function stop(): void { if (root.service && root.listening) root.service.stopListening() }
    function status(): string {
      if (!root.service) return "starting"
      var sc = root.service.sidecar || {}
      return sc.connected ? (sc.listening ? "listening: " + sc.title : "idle") + ", " + sc.toWrapUp + " to wrap up" : "sidecar offline"
    }
  }
}
