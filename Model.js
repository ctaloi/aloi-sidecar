// Pure helpers behind Aloi Meetings. Everything here is plain data in, plain
// data out, so Node tests can exercise it without a shell. Times arrive as
// UTC ISO strings from bin/aloi-meetings; "now" is always passed in as
// milliseconds, never read from the clock.

var MINUTE = 60000

function ms(iso) {
  var t = Date.parse(iso)
  return isNaN(t) ? 0 : t
}

// Meetings that can claim the bar: on your calendar as busy, not all-day,
// not cancelled and not declined. Tentative counts; you might go.
function counts(e) {
  if (!e || e.allDay || e.cancelled) return false
  if (e.showAs === "free" || e.showAs === "workingelsewhere") return false
  if (e.response === "declined") return false
  return ms(e.end) > ms(e.start)
}

// The meeting the bar should be about, or null.
//
// While you're in a meeting it stays in the bar ("8m left"), so running late
// doesn't make it vanish. A meeting starting within `imminent` minutes takes
// over from the one you're in, since that's the one you need to leave for.
// With two going at once, the one that started last is the one you're in.
function nextMeeting(events, now, within, imminent) {
  within = within === undefined ? 30 : within
  imminent = imminent === undefined ? 5 : imminent
  var current = null
  var next = null
  for (var i = 0; i < (events || []).length; i++) {
    var e = events[i]
    if (!counts(e)) continue
    var start = ms(e.start)
    var end = ms(e.end)
    if (start <= now && now < end) {
      if (!current || start > ms(current.start)) current = e
    } else if (start > now && start - now <= within * MINUTE) {
      if (!next || start < ms(next.start)) next = e
    }
  }
  if (next && (!current || ms(next.start) - now <= imminent * MINUTE))
    return { event: next, phase: "soon", minutes: Math.ceil((ms(next.start) - now) / MINUTE) }
  if (current) {
    var left = Math.ceil((ms(current.end) - now) / MINUTE)
    var started = Math.floor((now - ms(current.start)) / MINUTE)
    return { event: current, phase: started < 1 ? "starting" : "now", minutes: left }
  }
  return null
}

// "45m", "1h", "1h 20m". Spelled out by the caller's strings, so only the
// numbers are decided here.
function duration(minutes) {
  minutes = Math.max(0, Math.round(minutes))
  if (minutes < 60) return { hours: 0, minutes: minutes }
  return { hours: Math.floor(minutes / 60), minutes: minutes % 60 }
}

// Shorten to `max` characters on a word boundary when one is close, with an
// ellipsis. Titles like "RE: FW: Weekly sync" lose their mail prefixes first.
function shortTitle(title, max) {
  var text = String(title || "").replace(/^\s*((re|fw|fwd|aw|tr)\s*:\s*)+/i, "").trim()
  if (max === undefined || max <= 0 || text.length <= max) return text
  var cut = text.slice(0, max - 1)
  var space = cut.lastIndexOf(" ")
  if (space >= max * 0.6) cut = cut.slice(0, space)
  return cut.replace(/[\s,.;:–—-]+$/, "") + "…"
}

// The lowercase host of an https link, or "".
function host(url) {
  var m = /^https:\/\/([^\/?#:@]+)(:\d+)?([\/?#]|$)/i.exec(String(url || ""))
  return m ? m[1].toLowerCase() : ""
}

function onDomain(h, domain) {
  return h === domain || h.slice(-(domain.length + 1)) === "." + domain
}

// Which service a join link belongs to, judged by its host.
function provider(url) {
  var h = host(url)
  if (!h) return ""
  if (h === "teams.microsoft.com" || h === "teams.live.com" || h === "teams.cloud.microsoft") return "teams"
  if (onDomain(h, "zoom.us")) return "zoom"
  if (h === "meet.google.com") return "meet"
  if (onDomain(h, "webex.com")) return "webex"
  if (h === "meet.goto.com" || onDomain(h, "gotomeeting.com")) return "goto"
  return "web"
}

// A Zoom meeting link as a zoommtg:// link, so it opens straight in the Zoom
// app instead of a browser tab that then asks to open Zoom. Personal-room
// links (/my/name) have no meeting number and stay as they are.
function zoomAppUrl(url) {
  var m = /^https:\/\/([a-z0-9.-]+)\/(j|w|s)\/(\d+)(\?[^#]*)?/i.exec(String(url || ""))
  if (!m || !onDomain(m[1].toLowerCase(), "zoom.us")) return ""
  var params = ["action=join", "confno=" + m[3]]
  var query = m[4] ? m[4].slice(1).split("&") : []
  for (var i = 0; i < query.length; i++) {
    var pair = query[i].split("=")
    if (pair[0] === "pwd" && pair[1]) params.push("pwd=" + pair[1])
  }
  return "zoommtg://" + m[1] + "/join?" + params.join("&")
}

// The command that joins a meeting. Teams and Meet open as web app windows,
// the way Omarchy runs them; Zoom goes to the Zoom app when it's installed.
function joinCommand(url, zoomApp) {
  if (host(url) === "") return []
  var kind = provider(url)
  if (kind === "zoom" && zoomApp) {
    var app = zoomAppUrl(url)
    if (app) return ["xdg-open", app]
  }
  if (kind === "teams" || kind === "meet") return ["omarchy-launch-webapp", url]
  return ["xdg-open", url]
}

// Today's list for the panel, in start order: each meeting with where it
// stands right now. "next" marks the first one still to come.
function timeline(events, now) {
  var rows = []
  var sawNext = false
  var list = (events || []).filter(function(e) { return e && !e.cancelled })
  list.sort(function(a, b) {
    if (a.allDay !== b.allDay) return a.allDay ? -1 : 1
    return ms(a.start) - ms(b.start) || ms(a.end) - ms(b.end)
  })
  for (var i = 0; i < list.length; i++) {
    var e = list[i]
    var start = ms(e.start)
    var end = ms(e.end)
    var state
    if (e.allDay) state = "allday"
    else if (end <= now) state = "past"
    else if (start <= now) state = "now"
    else if (!sawNext && counts(e)) { state = "next"; sawNext = true }
    else state = "later"
    rows.push({
      event: e,
      state: state,
      quiet: !counts(e) && !e.allDay,
      joinable: e.joinUrl !== "" && e.joinUrl !== undefined && state !== "past" && state !== "allday",
      provider: provider(e.joinUrl)
    })
  }
  return rows
}

// The local calendar day of an instant, for noticing midnight.
function dayKey(now) {
  var d = new Date(now)
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
}

function pad(n) { return n < 10 ? "0" + n : String(n) }

// How long until the next calendar fetch. Calm when things are fine; sooner
// when a meeting is about to start (so a last-minute move shows up), and a
// patient backoff when offline.
function refreshDelay(state, failures, minutesToNext) {
  if (state === "offline" || state === "error" || state === "keyring")
    return Math.min(15, Math.pow(2, Math.max(0, Math.min(failures || 1, 4)) - 1)) * MINUTE
  if (minutesToNext !== null && minutesToNext !== undefined && minutesToNext >= 0 && minutesToNext <= 15)
    return 2 * MINUTE
  return 5 * MINUTE
}

// The helper's error kind as the state the panel shows.
function errorState(kind) {
  switch (kind) {
    case "signin": return "signedOut"
    case "consent": return "consent"
    case "offline": return "offline"
    case "keyring": return "keyring"
  }
  return "error"
}

if (typeof module !== "undefined") {
  module.exports = {
    counts: counts,
    nextMeeting: nextMeeting,
    duration: duration,
    shortTitle: shortTitle,
    host: host,
    provider: provider,
    zoomAppUrl: zoomAppUrl,
    joinCommand: joinCommand,
    timeline: timeline,
    dayKey: dayKey,
    refreshDelay: refreshDelay,
    errorState: errorState
  }
}
