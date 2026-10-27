import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

import "Model.js" as Model
import "Registry.js" as Registry

// A quiet calendar icon in the bar that becomes your next meeting's title
// once it's within half an hour, and stays while the meeting runs. Like
// Omarchy's own panels, the widget itself is the Panel. Click for today's
// meetings; right-click to join the one in the bar.
Panel {
  id: root
  moduleName: "aloi.meetings"

  property var service: null
  readonly property string phase: service ? service.phase : "starting"
  readonly property var match: service ? service.match : null
  readonly property int maxTitle: Number(setting("maxTitleLength", 28))
  readonly property bool showWhenIdle: String(setting("showWhenIdle", true)) !== "false"

  // Soon enough to get up for: the last five minutes, and the first one in.
  readonly property bool urgent: match !== null && (match.phase === "starting" || (match.phase === "soon" && match.minutes <= 5))
  readonly property bool joinable: match !== null && (match.event.joinUrl || "") !== ""
  // Aloi Sidecar listening to a call: the bar says so, in red, with how long.
  readonly property var sidecar: service ? service.sidecar : ({})
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

  function titleOf(event) {
    var title = event.subject || (event.private ? t("event.private") : t("event.untitled"))
    return Model.shortTitle(title, root.maxTitle)
  }

  readonly property string label: {
    if (listening) {
      var minutes = Math.max(0, Math.floor(((service ? service.now : Date.now()) - sidecar.started) / 60000))
      return t("bar.listening", { title: Model.shortTitle(sidecar.title || t("event.untitled"), root.maxTitle), time: span(minutes) })
    }
    if (!match) return ""
    var title = titleOf(match.event)
    if (match.phase === "soon") return t("bar.in", { title: title, time: span(match.minutes) })
    if (match.phase === "starting") return t("bar.starting", { title: title })
    return t("bar.left", { title: title, time: span(match.minutes) })
  }

  readonly property string tooltip: {
    if (listening) return t("bar.tooltipListening")
    if (phase === "signedOut") return t("bar.tooltipSignedOut")
    if (phase === "signingIn") return t("bar.tooltipSigningIn")
    if (!match) return t("bar.tooltip")
    var e = match.event
    return (e.subject || t("event.untitled")) + (joinable ? "\n" + t("bar.tooltipJoin") : "")
  }

  function bindService() {
    if (root.service) return
    var host = bar && bar.shell ? bar.shell : null
    var s = host && typeof host.serviceFor === "function" ? host.serviceFor("aloi.meetings") : null
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

  function quickAction() {
    if (root.service && root.joinable) root.service.joinCurrent()
    else root.toggle()
  }

  visible: root.label !== "" || root.showWhenIdle || root.opened
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  Behavior on implicitWidth {
    NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.listening ? "●  " + root.label : root.label !== "" ? "󰃭  " + root.label : "󰃭"
    active: root.urgent || root.listening
    activeColor: root.listening ? Commons.Color.urgent : Commons.Color.accent
    dimmed: root.phase === "signedOut" || root.phase === "consent" || root.phase === "keyring"
    tooltipText: root.tooltip
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.quickAction()
      else if (mouseButton === Qt.MiddleButton) { if (root.service) root.service.refresh() }
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
    contentWidth: popup.fittedContentWidth(Style.space(400))
    contentHeight: popup.fittedContentHeight(content.implicitHeight, Style.space(640))

    MeetingsContent {
      id: content
      anchors.fill: parent
      host: root
      service: root.service
    }
  }

  IpcHandler {
    target: "aloi.meetings"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { if (root.service) root.service.refresh() }
    function join(): string { return root.service && root.service.joinCurrent() ? "joining" : "nothing to join" }
    function signIn(): void { if (root.service) root.service.signIn() }
    function status(): string {
      if (!root.service) return "starting"
      return root.phase + (root.label !== "" ? " " + root.label : "")
    }
  }
}
