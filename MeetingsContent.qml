import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

import "Model.js" as Model

// Today's meetings, in the language of Omarchy's Bluetooth panel: a hero with
// the day and what's next, then one row per meeting with a Join button. Past
// meetings fade; the one you're in is the current row.
Item {
  id: root

  // The bar widget (a Panel) that hosts this content, and the shared service.
  property var host: null
  property var service: null
  property alias keyCatcher: keyCatcher

  readonly property var bar: host ? host.bar : null
  readonly property bool opened: host ? host.opened === true : false
  function setting(name, fallback) { return host ? host.setting(name, fallback) : fallback }
  function close() { if (host) host.close() }
  function switchPanel(direction) { return host ? host.switchPanel(direction) : false }

  implicitHeight: column.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Style.hoverFillFor(foreground, Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(foreground, Color.accent)

  readonly property string phase: service ? service.phase : "starting"
  readonly property real now: service ? service.now : Date.now()
  readonly property var rows: service ? service.rows : []
  readonly property var allDay: rows.filter(function(r) { return r.state === "allday" })
  readonly property var timed: rows.filter(function(r) { return r.state !== "allday" })
  readonly property var match: service ? service.match : null
  readonly property bool signedIn: phase === "ready" || phase === "offline" || phase === "error" || (phase === "starting" && service && service.hasData)
  readonly property string timeFormat: String(setting("timeFormat", "h:mm AP"))
  property int cursorIndex: -1

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function t(key, values) {
    var text = strings.t(key)
    for (var name in values) text = text.split("{" + name + "}").join(String(values[name]))
    return text
  }

  function span(minutes) { return host ? host.span(minutes) : String(minutes) }

  function clock(iso) {
    var d = new Date(iso)
    return isNaN(d.getTime()) ? "" : Qt.formatTime(d, root.timeFormat)
  }

  function titleOf(event) {
    return event.subject || (event.private ? t("event.private") : t("event.untitled"))
  }

  readonly property var providerNames: ({
    teams: "Teams", zoom: "Zoom", meet: "Google Meet", webex: "Webex", goto: "GoTo", web: t("join.browser")
  })

  // What's next, as the hero's caption.
  readonly property string heroStatus: {
    switch (phase) {
      case "signedOut": return t("status.signedOut")
      case "signingIn": return t("status.signingIn")
      case "consent": return t("status.consent")
      case "keyring": return t("status.keyring")
    }
    if (!service || !service.hasData) return t("status.loading")
    if (match) {
      var title = Model.shortTitle(titleOf(match.event), 40)
      if (match.phase === "soon") return t("status.next", { title: title, time: span(match.minutes) })
      if (match.phase === "starting") return t("status.startingNow", { title: title })
      return t("status.inMeeting", { title: title, time: span(match.minutes) })
    }
    var upcoming = timed.filter(function(r) { return r.state === "next" || r.state === "later" })
    var next = timed.filter(function(r) { return r.state === "next" })[0]
    if (next) return t("status.laterAt", { time: clock(next.event.start), count: upcoming.length })
    return timed.length === 0 ? t("status.free") : t("status.done")
  }

  function activate(row) {
    if (!row || !root.service) return
    if (row.joinable) root.service.join(row.event)
    else root.service.openInOutlook(row.event)
    root.close()
  }

  function moveCursor(dy) {
    var count = root.timed.length
    if (count === 0) return
    if (root.cursorIndex < 0) {
      // Start on the meeting that matters now, not the top of the day.
      var start = 0
      for (var i = 0; i < count; i++) if (root.timed[i].state === "now" || root.timed[i].state === "next") { start = i; break }
      root.cursorIndex = start
      return
    }
    root.cursorIndex = Math.max(0, Math.min(count - 1, root.cursorIndex + dy))
  }

  // Called by the host each time the panel opens. The list starts scrolled
  // to what's current, so a busy morning doesn't hide the afternoon.
  function reset() {
    root.cursorIndex = -1
    Qt.callLater(function() {
      scroller.contentY = 0
      for (var i = 0; i < meetingRepeater.count; i++) {
        var item = meetingRepeater.itemAt(i)
        var r = root.timed[i]
        if (item && r && (r.state === "now" || r.state === "next")) {
          var y = item.mapToItem(column, 0, 0).y - Style.space(80)
          scroller.contentY = Math.max(0, Math.min(Math.max(0, scroller.contentHeight - scroller.height), y))
          break
        }
      }
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  PanelKeyCatcher {
    id: keyCatcher
    anchors.fill: parent
    onCloseRequested: root.close()
    onTabRequested: function(direction) { root.switchPanel(direction) }
    onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
    onActivateRequested: {
      if (root.cursorIndex >= 0) root.activate(root.timed[root.cursorIndex])
      else if (root.match && root.service && root.service.joinCurrent()) root.close()
    }
    onTextKey: function(text) {
      if ((text === "r" || text === "R") && root.service) root.service.refresh()
      else if ((text === "o" || text === "O") && root.cursorIndex >= 0 && root.service) {
        root.service.openInOutlook(root.timed[root.cursorIndex].event)
        root.close()
      }
    }

    Flickable {
      id: scroller
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickDeceleration: 1800
      maximumFlickVelocity: 5000

      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      // Touchpad scrolling follows the fingers 1:1, then glides on release.
      // Hyprland sends no momentum events, so the glide comes from the
      // recent scroll velocity once events stop.
      WheelHandler {
        id: wheel
        target: null
        property real velocity: 0
        property real lastTime: 0
        onWheel: function(event) {
          var touchpad = event.pixelDelta.y !== 0
          var dy = touchpad ? event.pixelDelta.y : event.angleDelta.y / 120 * Style.space(48)
          var now = Date.now()
          var dt = Math.max(4, now - lastTime)
          lastTime = now
          scroller.cancelFlick()
          scroller.contentY = Math.max(0, Math.min(Math.max(0, scroller.contentHeight - scroller.height), scroller.contentY - dy))
          velocity = touchpad ? (dt > 100 ? 0 : velocity * 0.5) + (dy / dt * 1000) * 0.5 : 0
          glideTimer.restart()
          event.accepted = true
        }
      }

      Timer {
        id: glideTimer
        interval: 50
        onTriggered: {
          if (Math.abs(wheel.velocity) > 150) scroller.flick(0, wheel.velocity)
          wheel.velocity = 0
        }
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroActions.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "󰃭"
            color: root.match ? Color.accent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            opacity: root.match ? 1.0 : 0.5
            Behavior on opacity { NumberAnimation { duration: Style.duration(200) } }
            Behavior on color { ColorAnimation { duration: Style.duration(200) } }
          }

          Row {
            id: heroActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            PanelActionButton {
              id: refreshButton
              anchors.verticalCenter: parent.verticalCenter
              visible: root.signedIn
              iconText: "󰑐"
              tooltipText: root.t("hero.refresh")
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.subtitle * 1.5
              onClicked: if (root.service) root.service.refresh()

              RotationAnimation on rotation {
                running: root.service !== null && root.service.fetching
                loops: Animation.Infinite
                from: 0
                to: 360
                duration: Style.duration(900)
                onStopped: refreshButton.rotation = 0
              }
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.rightMargin: heroActions.width + Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: Qt.formatDate(new Date(root.now), "dddd, MMMM d")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.heroStatus.toUpperCase()
              color: root.match && root.host && root.host.urgent ? Color.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
            }
          }
        }

        // ---------- Signed out, signing in, or something to fix ----------
        Column {
          visible: root.phase === "signedOut" || root.phase === "signingIn" || root.phase === "consent" || root.phase === "keyring"
          width: parent.width
          spacing: Style.space(10)

          PanelSeparator { foreground: root.foreground }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.phase === "signingIn" ? root.t("signin.waiting")
              : root.phase === "consent" ? root.t("signin.consent")
              : root.phase === "keyring" ? root.t("signin.keyring")
              : root.t("signin.body")
            color: root.phase === "consent" || root.phase === "keyring" ? Color.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: text !== "" && root.phase !== "signingIn" && root.phase !== "signedOut"
            width: parent.width
            textFormat: Text.PlainText
            text: root.service ? root.service.errorDetail : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.phase === "signedOut" && root.service !== null && root.service.errorDetail !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.t("signin.expired")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Button {
            text: root.phase === "signingIn" ? root.t("signin.cancel") : root.t("signin.button")
            fontSize: Style.font.bodySmall
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            onClicked: {
              if (!root.service) return
              if (root.phase === "signingIn") root.service.cancelSignIn()
              else root.service.signIn()
            }
          }
        }

        // ---------- All-day events: one quiet line ----------
        Text {
          visible: root.allDay.length > 0 && root.signedIn
          width: parent.width
          textFormat: Text.PlainText
          text: root.t("allDay", { titles: root.allDay.map(function(r) { return root.titleOf(r.event) }).join(" · ") })
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        // ---------- Today's meetings ----------
        PanelSeparator { visible: root.signedIn; foreground: root.foreground }

        Column {
          visible: root.signedIn && root.timed.length > 0
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            id: meetingRepeater
            model: root.timed
            delegate: Item {
              required property var modelData
              required property int index
              width: parent.width
              height: meetingRow.implicitHeight
              MeetingRow { id: meetingRow; width: parent.width; entry: modelData; order: index }
            }
          }
        }

        Text {
          visible: root.signedIn && root.service !== null && root.service.hasData && root.timed.length === 0
          width: parent.width
          textFormat: Text.PlainText
          text: root.t("empty")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // ---------- Footer: freshness and the account ----------
        PanelSeparator { visible: root.signedIn; foreground: root.foreground }

        Item {
          visible: root.signedIn
          width: parent.width
          implicitHeight: Math.max(freshness.implicitHeight, signOutButton.implicitHeight)

          Text {
            id: freshness
            anchors.left: parent.left
            anchors.right: signOutButton.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: {
              if (!root.service || !root.service.hasData) return ""
              var at = Qt.formatTime(new Date(root.service.fetchedAt), root.timeFormat)
              if (root.phase === "offline") return root.t("footer.offline", { time: at })
              if (root.phase === "error") return root.t("footer.error", { time: at })
              return root.service.account !== "" ? root.service.account : root.t("footer.updated", { time: at })
            }
            color: root.phase === "offline" || root.phase === "error" ? Color.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Button {
            id: signOutButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.t("footer.signOut")
            fontSize: Style.font.caption
            foreground: root.dim
            fontFamily: root.fontFamily
            onClicked: if (root.service) root.service.signOut()
          }
        }
      }
    }
  }

  // One meeting: its time, its title and who or where, and a Join button
  // while it can still be joined.
  component MeetingRow: CursorSurface {
    id: row
    required property var entry
    required property int order

    readonly property var event: entry.event
    readonly property bool past: entry.state === "past"
    readonly property bool live: entry.state === "now"
    readonly property bool next: entry.state === "next"
    readonly property color titleColor: past || entry.quiet ? root.dim : root.foreground

    readonly property string caption: {
      var parts = []
      var m = root.match
      if (m && m.event === row.event) {
        if (m.phase === "soon") parts.push(root.t("row.in", { time: root.span(m.minutes) }))
        else if (m.phase === "starting") parts.push(root.t("row.startingNow"))
        else parts.push(root.t("row.left", { time: root.span(m.minutes) }))
      } else if (live) {
        parts.push(root.t("row.left", { time: root.span(Math.ceil((Date.parse(row.event.end) - root.now) / 60000)) }))
      }
      if (row.event.response === "declined") parts.push(root.t("row.declined"))
      else if (row.event.response === "tentativelyaccepted" || row.event.showAs === "tentative") parts.push(root.t("row.tentative"))
      else if (row.event.response === "notresponded" || row.event.response === "none" && !row.event.isOrganizer) parts.push(root.t("row.notResponded"))
      if (row.event.showAs === "free" && row.event.response !== "declined") parts.push(root.t("row.free"))
      if (row.event.organizer !== "" && !row.event.isOrganizer) parts.push(row.event.organizer)
      if (row.event.location !== "") parts.push(row.event.location)
      return parts.join(" · ")
    }

    hasCursor: root.cursorIndex === order
    current: live
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX
    opacity: past ? 0.55 : 1.0

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.cursorIndex = row.order
      onClicked: {
        if (root.service) root.service.openInOutlook(row.event)
        root.close()
      }
    }

    PanelToolTip {
      visible: rowMouse.containsMouse && !joinButton.containsMouse
      text: root.t("row.openTooltip")
      fontFamily: root.fontFamily
    }

    Item {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(times.implicitHeight, info.implicitHeight, joinButton.implicitHeight)

      Column {
        id: times
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(64)
        spacing: Style.space(1)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.clock(row.event.start)
          color: row.next || row.live ? Color.accent : row.titleColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: row.next || row.live
          font.features: { "tnum": 1 }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.clock(row.event.end)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.features: { "tnum": 1 }
        }
      }

      Column {
        id: info
        anchors.left: times.right
        anchors.leftMargin: Style.space(8)
        anchors.right: joinButton.visible ? joinButton.left : parent.right
        anchors.rightMargin: joinButton.visible ? Style.space(8) : 0
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.titleOf(row.event)
          color: row.titleColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.strikeout: row.event.response === "declined"
          elide: Text.ElideRight
        }

        Text {
          visible: text !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: row.caption
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Button {
        id: joinButton
        readonly property bool containsMouse: hot
        property bool hot: false
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: row.entry.joinable
        text: root.t("join.button")
        tooltipText: root.t("join.tooltip", { app: root.providerNames[row.entry.provider] || root.t("join.browser") })
        fontSize: Style.font.bodySmall
        foreground: row.live || row.next ? Color.accent : root.foreground
        fontFamily: root.fontFamily
        bordered: true
        active: row.live || (row.next && root.match !== null && root.match.event === row.event)
        onHovered: function(on) { hot = on }
        onClicked: {
          if (root.service && root.service.join(row.event)) root.close()
        }
      }
    }
  }
}
