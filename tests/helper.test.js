const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { spawnSync } = require("node:child_process")

const root = path.join(__dirname, "..")
const helper = path.join(root, "bin/aloi-meetings")
const fixture = fs.readFileSync(path.join(__dirname, "fixtures/calendarView.json"), "utf8")

// Each run gets its own runtime and state folders, and no keyring, so a test
// never touches a real sign-in.
function run(args, input) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "aloi-meetings-test-"))
  const env = { PATH: "/usr/bin:/bin", HOME: tmp, XDG_RUNTIME_DIR: tmp, XDG_STATE_HOME: path.join(tmp, "state") }
  const r = spawnSync("python3", ["-I", helper, ...args], { input, env, encoding: "utf8" })
  fs.rmSync(tmp, { recursive: true, force: true })
  return { code: r.status, json: JSON.parse(r.stdout || "null"), stderr: r.stderr }
}

const parsed = run(["parse", "2026-10-26"], fixture)
const byId = Object.fromEntries(parsed.json.events.map(e => [e.id, e]))

test("parse turns a Graph reply into today's events, in start order", () => {
  assert.equal(parsed.code, 0, parsed.stderr)
  assert.equal(parsed.json.day, "2026-10-26")
  assert.match(parsed.json.fetched, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/)
  assert.deepEqual(parsed.json.events.map(e => e.id),
    ["AAMk-allday", "AAMk-standup", "AAMk-zoom", "AAMk-cancelled", "AAMk-meet", "AAMk-private"])
})

test("events without times are dropped rather than guessed", () => {
  assert.equal(byId["AAMk-broken"], undefined)
})

test("the Teams link comes from the meeting itself", () => {
  const e = byId["AAMk-standup"]
  assert.equal(e.joinUrl, "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d")
  assert.equal(e.organizer, "Dana Ruiz")
  assert.equal(e.provider, "teamsforbusiness")
  assert.equal(e.start, "2026-10-26T13:30:00Z")
})

test("a Zoom link in the location is found, and the location isn't repeated", () => {
  const e = byId["AAMk-zoom"]
  assert.equal(e.joinUrl, "https://vaspian.zoom.us/j/81234567890?pwd=AbC123.1")
  assert.equal(e.location, "")
  assert.equal(e.response, "tentativelyaccepted")
  assert.equal(e.organizer, "pat@vendor.example")
})

test("times in the event's own Windows zone come out in UTC", () => {
  // 10:00 Eastern on 26 October 2026 is daylight time, UTC-4.
  assert.equal(byId["AAMk-zoom"].start, "2026-10-26T14:00:00Z")
  assert.equal(byId["AAMk-zoom"].end, "2026-10-26T14:30:00Z")
})

test("a Meet link behind Outlook Safe Links is unwrapped", () => {
  const e = byId["AAMk-meet"]
  assert.equal(e.joinUrl, "https://meet.google.com/abc-defg-hij")
  assert.equal(e.location, "Conference room B")
})

test("cancelled-by-title, all-day and private events are flagged", () => {
  assert.equal(byId["AAMk-cancelled"].cancelled, true)
  assert.equal(byId["AAMk-allday"].allDay, true)
  assert.equal(byId["AAMk-private"].private, true)
  assert.equal(byId["AAMk-standup"].private, false)
})

test("status without a keyring or sign-in says signed out or names the keyring", () => {
  const r = run(["status"])
  if (r.code === 0) assert.equal(r.json.signedIn, false)
  else assert.equal(r.json.error, "keyring")
})

test("today without a sign-in asks to sign in, as JSON", () => {
  const r = run(["today"])
  assert.notEqual(r.code, 0)
  assert.ok(["signin", "keyring"].includes(r.json.error), JSON.stringify(r.json))
})

test("bad options and commands fail as JSON", () => {
  let r = run(["--tenant", "../../evil", "status"])
  assert.equal(r.code, 1)
  assert.equal(r.json.error, "other")
  r = run(["bogus"])
  assert.equal(r.code, 1)
  assert.match(r.json.detail, /unknown command/)
})
