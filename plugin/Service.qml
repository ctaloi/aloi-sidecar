import QtQuick
import Quickshell
import Quickshell.Io

import "Registry.js" as Registry

// One per shell, so every bar shows the same dot. It asks Sidecar's engine
// (on this machine) whether it's listening, and starts or stops it. Which
// meeting a call is, Sidecar's engine reads from Aloi Calendar itself.
Item {
  id: root
  width: 0
  height: 0
  visible: false

  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var barWidgetRegistry: null
  property string omarchyPath: ""

  // Set by the bar widget: its shell.json settings, and whether the panel is open.
  property var settings: ({})
  property bool panelOpen: false

  // A clock for "listening for 12m", a minute at a time.
  property real now: Date.now()
  Timer { interval: 30000; running: true; repeat: true; onTriggered: root.now = Date.now() }

  readonly property string sidecarUrl: "http://127.0.0.1:8777"
  // {connected, listening, title, started, toWrapUp}
  property var sidecar: ({ connected: false })

  function parse(text) {
    try { return JSON.parse(text) } catch (e) { return null }
  }

  function pollSidecar() {
    var request = new XMLHttpRequest()
    request.onreadystatechange = function() {
      if (request.readyState !== XMLHttpRequest.DONE) return
      var reply = request.status === 200 ? root.parse(request.responseText) : null
      if (!reply) { if (root.sidecar.connected !== false) root.sidecar = { connected: false }; return }
      var m = reply.meeting || {}
      root.sidecar = {
        connected: true,
        listening: !!reply.listening,
        title: m.title || "",
        started: Number(m.started || 0) * 1000,
        toWrapUp: Number(reply.to_wrap_up || 0)
      }
      root.now = Date.now()
    }
    request.open("GET", root.sidecarUrl + "/status")
    request.send()
  }

  function sidecarPost(path, body) {
    var request = new XMLHttpRequest()
    request.onreadystatechange = function() {
      if (request.readyState === XMLHttpRequest.DONE) root.pollSidecar()
    }
    request.open("POST", root.sidecarUrl + path)
    request.setRequestHeader("Content-Type", "application/json")
    request.send(JSON.stringify(body || {}))
  }

  // Sidecar's window, without starting to listen (it's already listening, or
  // there's a wrap-up to look at).
  function openSidecar() { Quickshell.execDetached(["aloi-sidecar", "--no-listen"]) }

  // Listen now: Sidecar names the meeting from the calendar (the one on, or
  // about to start), or from the call's window.
  function listen() {
    root.sidecarPost("/meeting/start", {})
    root.openSidecar()
  }

  function stopListening() { root.sidecarPost("/listen", { on: false }) }

  function toggleListening() {
    if (!root.sidecar.connected) root.openSidecar()
    else if (root.sidecar.listening) root.stopListening()
    else root.listen()
  }

  Timer {
    interval: root.sidecar.listening || root.panelOpen ? 4000 : 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollSidecar()
  }

  Component.onCompleted: Registry.set(root)
  Component.onDestruction: Registry.clear(root)
}
