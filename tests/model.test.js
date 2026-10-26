const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

const at = iso => Date.parse(iso)
const meeting = (subject, start, end, extra) => Object.assign({
  subject, start, end, allDay: false, cancelled: false, showAs: "busy", response: "accepted",
  joinUrl: "", provider: "", location: "", organizer: ""
}, extra || {})

const standup = meeting("Standup", "2026-10-26T13:30:00Z", "2026-10-26T13:45:00Z", {
  joinUrl: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0"
})
const review = meeting("Design review", "2026-10-26T14:00:00Z", "2026-10-26T15:00:00Z", {
  joinUrl: "https://vaspian.zoom.us/j/81234567890?pwd=AbC123.1"
})

test("counts skips all-day, cancelled, declined and free time", () => {
  assert.equal(Model.counts(standup), true)
  assert.equal(Model.counts(meeting("Holiday", "2026-10-26T00:00:00Z", "2026-10-27T00:00:00Z", { allDay: true })), false)
  assert.equal(Model.counts(meeting("Moved", standup.start, standup.end, { cancelled: true })), false)
  assert.equal(Model.counts(meeting("Nope", standup.start, standup.end, { response: "declined" })), false)
  assert.equal(Model.counts(meeting("Lunch", standup.start, standup.end, { showAs: "free" })), false)
  assert.equal(Model.counts(meeting("Maybe", standup.start, standup.end, { response: "tentativelyaccepted" })), true)
  assert.equal(Model.counts(meeting("Zero", standup.start, standup.start)), false)
})

test("nothing within 30 minutes means nothing in the bar", () => {
  assert.equal(Model.nextMeeting([standup, review], at("2026-10-26T12:59:00Z")), null)
  assert.equal(Model.nextMeeting([], at("2026-10-26T12:59:00Z")), null)
})

test("a meeting 30 minutes out appears, counting down in whole minutes", () => {
  const m = Model.nextMeeting([standup, review], at("2026-10-26T13:00:00Z"))
  assert.equal(m.event, standup)
  assert.equal(m.phase, "soon")
  assert.equal(m.minutes, 30)
  // 11m 20s rounds up: the bar never says "in 11m" when it's 11m 20s away.
  assert.equal(Model.nextMeeting([standup], at("2026-10-26T13:18:40Z")).minutes, 12)
  assert.equal(Model.nextMeeting([standup], at("2026-10-26T13:29:30Z")).minutes, 1)
})

test("a meeting in progress stays, with time left", () => {
  const starting = Model.nextMeeting([standup], at("2026-10-26T13:30:20Z"))
  assert.equal(starting.phase, "starting")
  const m = Model.nextMeeting([standup], at("2026-10-26T13:37:00Z"))
  assert.equal(m.phase, "now")
  assert.equal(m.minutes, 8)
  assert.equal(Model.nextMeeting([standup], at("2026-10-26T13:45:00Z")), null)
})

test("the next meeting takes over five minutes before it starts", () => {
  const long = meeting("Planning", "2026-10-26T13:00:00Z", "2026-10-26T14:30:00Z")
  assert.equal(Model.nextMeeting([long, review], at("2026-10-26T13:50:00Z")).event, long)
  const m = Model.nextMeeting([long, review], at("2026-10-26T13:55:00Z"))
  assert.equal(m.event, review)
  assert.equal(m.phase, "soon")
})

test("of two meetings going at once, the later-started one is current", () => {
  const a = meeting("All hands", "2026-10-26T13:00:00Z", "2026-10-26T15:00:00Z")
  const b = meeting("Side call", "2026-10-26T13:20:00Z", "2026-10-26T13:40:00Z")
  assert.equal(Model.nextMeeting([a, b], at("2026-10-26T13:25:00Z")).event, b)
  assert.equal(Model.nextMeeting([a, b], at("2026-10-26T13:45:00Z")).event, a)
})

test("declined meetings never claim the bar", () => {
  const declined = meeting("Nope", "2026-10-26T13:10:00Z", "2026-10-26T13:20:00Z", { response: "declined" })
  assert.equal(Model.nextMeeting([declined], at("2026-10-26T13:00:00Z")), null)
})

test("shortTitle trims mail prefixes and cuts on a word", () => {
  assert.equal(Model.shortTitle("RE: FW: Weekly sync"), "Weekly sync")
  assert.equal(Model.shortTitle("Standup", 24), "Standup")
  assert.equal(Model.shortTitle("Quarterly business review with the Netstratum team", 24), "Quarterly business…")
  assert.equal(Model.shortTitle("Supercalifragilisticexpialidocious", 10), "Supercali…")
  assert.equal(Model.shortTitle("", 10), "")
})

test("duration splits hours and minutes", () => {
  assert.deepEqual(Model.duration(45), { hours: 0, minutes: 45 })
  assert.deepEqual(Model.duration(60), { hours: 1, minutes: 0 })
  assert.deepEqual(Model.duration(80), { hours: 1, minutes: 20 })
})

test("provider recognizes the join links people paste", () => {
  assert.equal(Model.provider(standup.joinUrl), "teams")
  assert.equal(Model.provider("https://teams.microsoft.com/meet/2345?p=abc"), "teams")
  assert.equal(Model.provider(review.joinUrl), "zoom")
  assert.equal(Model.provider("https://zoom.us/j/123"), "zoom")
  assert.equal(Model.provider("https://meet.google.com/abc-defg-hij"), "meet")
  assert.equal(Model.provider("https://vaspian.webex.com/meet/chris"), "webex")
  assert.equal(Model.provider("https://meet.goto.com/123456789"), "goto")
  assert.equal(Model.provider("https://example.com/room"), "web")
  assert.equal(Model.provider(""), "")
  // A lookalike host isn't Zoom.
  for (const fake of ["https://notzoom.us.evil.example/j/1", "https://evilzoom.us/j/1", "https://evil.example//zoom.us/j/1",
    "https://zoom.us@evil.example/j/1", "http://zoom.us/j/1"])
    assert.notEqual(Model.provider(fake), "zoom", fake)
  assert.equal(Model.zoomAppUrl("https://evilzoom.us/j/123"), "")
})

test("Zoom links open in the Zoom app, with the passcode", () => {
  assert.equal(Model.zoomAppUrl(review.joinUrl), "zoommtg://vaspian.zoom.us/join?action=join&confno=81234567890&pwd=AbC123.1")
  assert.equal(Model.zoomAppUrl("https://zoom.us/j/123456"), "zoommtg://zoom.us/join?action=join&confno=123456")
  assert.equal(Model.zoomAppUrl("https://zoom.us/my/chris"), "")
  assert.deepEqual(Model.joinCommand(review.joinUrl, true), ["xdg-open", Model.zoomAppUrl(review.joinUrl)])
  assert.deepEqual(Model.joinCommand(review.joinUrl, false), ["xdg-open", review.joinUrl])
  assert.deepEqual(Model.joinCommand("https://zoom.us/my/chris", true), ["xdg-open", "https://zoom.us/my/chris"])
})

test("Teams and Meet join in a web app window", () => {
  assert.deepEqual(Model.joinCommand(standup.joinUrl, true), ["omarchy-launch-webapp", standup.joinUrl])
  assert.deepEqual(Model.joinCommand("https://meet.google.com/abc-defg-hij", true), ["omarchy-launch-webapp", "https://meet.google.com/abc-defg-hij"])
  assert.deepEqual(Model.joinCommand("https://vaspian.webex.com/meet/chris", true), ["xdg-open", "https://vaspian.webex.com/meet/chris"])
})

test("joinCommand refuses anything that isn't https", () => {
  assert.deepEqual(Model.joinCommand("javascript:alert(1)", true), [])
  assert.deepEqual(Model.joinCommand("file:///etc/passwd", true), [])
  assert.deepEqual(Model.joinCommand("", true), [])
})

test("timeline orders the day and marks where each meeting stands", () => {
  const early = meeting("Early", "2026-10-26T12:00:00Z", "2026-10-26T12:30:00Z", { joinUrl: standup.joinUrl })
  const allDay = meeting("Office closed", "2026-10-26T00:00:00Z", "2026-10-27T00:00:00Z", { allDay: true })
  const declined = meeting("Skip", "2026-10-26T13:35:00Z", "2026-10-26T13:50:00Z", { response: "declined" })
  const gone = meeting("Cancelled", "2026-10-26T16:00:00Z", "2026-10-26T16:30:00Z", { cancelled: true })
  const rows = Model.timeline([review, gone, declined, standup, early, allDay], at("2026-10-26T13:20:00Z"))
  assert.deepEqual(rows.map(r => [r.event.subject, r.state]), [
    ["Office closed", "allday"],
    ["Early", "past"],
    ["Standup", "next"],
    ["Skip", "later"],
    ["Design review", "later"]
  ])
  assert.equal(rows[1].joinable, false)
  assert.equal(rows[2].joinable, true)
  assert.equal(rows[2].provider, "teams")
  assert.equal(rows[3].quiet, true)
  assert.equal(rows[0].quiet, false)
})

test("a declined meeting is never the one marked next", () => {
  const declined = meeting("Skip", "2026-10-26T13:25:00Z", "2026-10-26T13:28:00Z", { response: "declined" })
  const rows = Model.timeline([declined, standup], at("2026-10-26T13:20:00Z"))
  assert.equal(rows[0].state, "later")
  assert.equal(rows[1].state, "next")
})

test("dayKey is the local date", () => {
  const d = new Date(2026, 9, 26, 23, 59)
  assert.equal(Model.dayKey(d.getTime()), "2026-10-26")
  assert.equal(Model.dayKey(d.getTime() + 2 * 60000), "2026-10-27")
})

test("refreshDelay is calm, quicker near a meeting, and backs off offline", () => {
  assert.equal(Model.refreshDelay("ready", 0, null), 5 * 60000)
  assert.equal(Model.refreshDelay("ready", 0, 10), 2 * 60000)
  assert.equal(Model.refreshDelay("offline", 1), 60000)
  assert.equal(Model.refreshDelay("offline", 2), 2 * 60000)
  assert.equal(Model.refreshDelay("offline", 9), 8 * 60000)
})

test("errorState maps the helper's error kinds", () => {
  assert.equal(Model.errorState("signin"), "signedOut")
  assert.equal(Model.errorState("offline"), "offline")
  assert.equal(Model.errorState("consent"), "consent")
  assert.equal(Model.errorState("keyring"), "keyring")
  assert.equal(Model.errorState("weird"), "error")
})
