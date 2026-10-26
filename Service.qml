import QtQuick
import Quickshell
import Quickshell.Io

import "Model.js" as Model
import "Registry.js" as Registry

// One per shell, so every bar shows the same day. It asks bin/aloi-meetings
// for today's meetings every few minutes, keeps the last good copy when the
// network drops, and turns the list into the one meeting the bar is about.
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

  // Set by the bar widget: its shell.json settings, and whether a panel is open.
  property var settings: ({})
  property bool panelOpen: false

  readonly property string helper: String(Qt.resolvedUrl("bin/aloi-meetings")).replace(/^file:\/\//, "")

  // "starting", "signedOut", "signingIn", "ready", "offline", "consent",
  // "keyring" or "error". Offline and error keep showing the last good day.
  property string phase: "starting"
  property string errorDetail: ""
  property string account: ""
  property var events: []
  property string day: ""
  property real fetchedAt: 0
  property bool fetching: false
  property int failures: 0
  property bool zoomInstalled: false

  // Minute-precise "now", so countdowns change exactly on the minute.
  property real now: Date.now()

  readonly property int within: Number(settings.withinMinutes || 30)
  readonly property var match: Model.nextMeeting(events, now, within, 5)
  readonly property var rows: Model.timeline(events, now)
  readonly property bool hasData: fetchedAt > 0
  readonly property bool stale: hasData && (phase === "offline" || phase === "error")

  // ---------- Actions ----------

  function refresh() {
    if (root.fetching || root.phase === "signingIn") return
    root.fetching = true
    run(fetchProcess, ["today"])
  }

  function signIn() {
    if (signInProcess.running) return
    root.phase = "signingIn"
    root.errorDetail = ""
    run(signInProcess, ["login"])
  }

  function cancelSignIn() {
    if (signInProcess.running) signInProcess.signal(15)
  }

  function signOut() {
    cancelSignIn()
    run(signOutProcess, ["logout"])
  }

  function join(event) {
    if (!event) return false
    var command = Model.joinCommand(event.joinUrl, root.zoomInstalled && root.settings.zoomApp !== false)
    if (command.length === 0) return false
    Quickshell.execDetached(command)
    return true
  }

  function joinCurrent() {
    return root.match ? join(root.match.event) : false
  }

  function openInOutlook(event) {
    if (!event || !/^https:\/\//.test(event.webLink || "")) return
    Quickshell.execDetached(["omarchy-launch-webapp", event.webLink])
  }

  // ---------- Talking to the helper ----------

  function run(process, args) {
    process.command = [root.helper].concat(args)
    if ("out" in process) process.out = ""
    process.running = true
  }

  function parse(text) {
    try { return JSON.parse(String(text).trim()) } catch (e) { return null }
  }

  function failed(reply) {
    var kind = reply && reply.error ? reply.error : "other"
    root.errorDetail = reply && reply.detail ? String(reply.detail) : ""
    root.phase = Model.errorState(kind)
    if (root.phase === "signedOut") {
      root.events = []
      root.fetchedAt = 0
    }
    root.failures = root.failures + 1
  }

  Process {
    id: fetchProcess
    property string out: ""
    stdout: StdioCollector { onStreamFinished: fetchProcess.out = text }
    onExited: function(code) {
      root.fetching = false
      var reply = root.parse(fetchProcess.out)
      if (code === 0 && reply && reply.events) {
        root.events = reply.events
        root.day = reply.day
        root.fetchedAt = Date.now()
        root.failures = 0
        root.errorDetail = ""
        root.phase = "ready"
      } else {
        root.failed(reply)
      }
      root.scheduleRefresh()
    }
  }

  Process {
    id: signInProcess
    property string out: ""
    stdout: StdioCollector { onStreamFinished: signInProcess.out = text }
    onExited: function(code) {
      var reply = root.parse(signInProcess.out)
      if (code === 0 && reply && reply.signedIn) {
        root.account = reply.account || ""
        root.phase = "starting"
        root.failures = 0
        root.refresh()
      } else if (reply && reply.error) {
        root.failed(reply)
      } else {
        // Cancelled from the panel.
        root.phase = "signedOut"
        root.errorDetail = ""
      }
    }
  }

  Process {
    id: signOutProcess
    onExited: {
      root.events = []
      root.fetchedAt = 0
      root.account = ""
      root.phase = "signedOut"
      root.errorDetail = ""
    }
  }

  Process {
    id: statusProcess
    property string out: ""
    command: [root.helper, "status"]
    stdout: StdioCollector { onStreamFinished: statusProcess.out = text }
    onExited: function(code) {
      var reply = root.parse(statusProcess.out)
      if (code === 0 && reply) {
        root.account = reply.account || ""
        if (reply.signedIn) root.refresh()
        else root.phase = "signedOut"
      } else {
        root.failed(reply)
      }
    }
  }

  // Is the Zoom app there to take zoommtg:// links?
  Process {
    id: zoomProcess
    command: ["xdg-mime", "query", "default", "x-scheme-handler/zoommtg"]
    stdout: StdioCollector { onStreamFinished: root.zoomInstalled = String(text).trim() !== "" }
  }

  // ---------- Keeping it current ----------

  function scheduleRefresh() {
    var next = root.match && root.match.phase === "soon" ? root.match.minutes : null
    refreshTimer.interval = Model.refreshDelay(root.phase, root.failures, next)
    refreshTimer.restart()
  }

  Timer {
    id: refreshTimer
    repeat: false
    onTriggered: if (root.phase !== "signedOut" && root.phase !== "signingIn" && root.phase !== "consent") root.refresh()
  }

  // Ticks on each wall-clock minute. A long gap between ticks means the
  // laptop slept, so the calendar may have moved on: fetch straight away.
  // A new day starts a new list.
  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      var previous = root.now
      root.now = clock.date.getTime()
      var slept = root.now - previous > 3 * 60000
      var newDay = root.day !== "" && Model.dayKey(root.now) !== root.day
      if ((slept || newDay) && (root.phase === "ready" || root.phase === "offline" || root.phase === "error"))
        root.refresh()
    }
  }

  // Opening the panel on old data is a good moment to check again.
  onPanelOpenChanged: {
    if (panelOpen && root.hasData && Date.now() - root.fetchedAt > 60000) root.refresh()
  }

  Component.onCompleted: {
    Registry.set(root)
    zoomProcess.running = true
    statusProcess.running = true
  }
  Component.onDestruction: {
    cancelSignIn()
    Registry.clear(root)
  }
}
