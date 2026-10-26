.pragma library

// Formatting the window shares: clock times, lengths and which day a
// meeting falls under in the list.

function clock(seconds) {
    if (!seconds) return ""
    return new Date(seconds * 1000).toLocaleTimeString(Qt.locale(), "h:mm AP")
}

// "5:58:15", for the transcript: the list's clock, to the second, without AM/PM.
function seconds(t) {
    const d = new Date(t * 1000)
    const two = n => (n < 10 ? "0" : "") + n
    return (d.getHours() % 12 || 12) + ":" + two(d.getMinutes()) + ":" + two(d.getSeconds())
}

function span(m, now) {
    const start = clock(m.started)
    if (m.state !== "ended") return start
    return start + " – " + clock(m.ended)
}

// "4m", "1h 05m"; live meetings run to now.
function length(m, now) {
    const end = m.state === "ended" ? m.ended : now / 1000
    const minutes = Math.max(0, Math.round((end - m.started) / 60))
    if (minutes < 60) return minutes + "m"
    const h = Math.floor(minutes / 60), r = minutes % 60
    return h + "h " + (r < 10 ? "0" : "") + r + "m"
}

// "23:41" while live.
function elapsed(m, now) {
    const s = Math.max(0, Math.floor(now / 1000 - m.started))
    const h = Math.floor(s / 3600), mm = Math.floor(s % 3600 / 60), ss = s % 60
    const two = n => (n < 10 ? "0" : "") + n
    return (h > 0 ? h + ":" + two(mm) : mm) + ":" + two(ss)
}

function startOfDay(d) { return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime() }

// Which group a meeting goes under: live first, then by day.
function group(m, now) {
    if (m.state !== "ended") return "now"
    const today = startOfDay(new Date(now))
    const t = m.started * 1000
    if (t >= today) return "today"
    if (t >= today - 86400000) return "yesterday"
    if (t >= today - 6 * 86400000) return "week"
    return "earlier"
}

function dayLabel(m) {
    return new Date(m.started * 1000).toLocaleDateString(Qt.locale(), "ddd d MMM")
}

// Where a meeting is in its life after the call, for chips and the list.
function stage(m) {
    if (!m || !m.id) return ""
    if (m.state !== "ended") return "on"
    const n = m.notion || {}
    if (n.state === "sent") return "sent"
    if (n.state === "sending") return "sending"
    if (n.state === "failed") return "sendFailed"
    if (m.skipped) return "skipped"
    if (m.wrapup === "drafting") return "drafting"
    if (m.wrapup === "failed") return "draftFailed"
    if (m.wrapup === "ready") return "ready"
    return "none"
}

// Still to wrap up: over, talked in, not filed or set aside, and recent
// enough that it's still on Chris's mind (older ones sit under their day).
function needsWrapup(m, now) {
    const s = stage(m)
    if (s === "on" || s === "sent" || s === "skipped" || !(m.lines > 0)) return false
    return now / 1000 - m.started < 7 * 86400
}

// "6:02 PM" today, "Mon 6:02 PM" this week, else the date.
function when(t, now) {
    const d = new Date(t * 1000)
    if (startOfDay(d) === startOfDay(new Date(now))) return clock(t)
    if (now - d.getTime() < 6 * 86400000) return d.toLocaleDateString(Qt.locale(), "ddd") + " " + clock(t)
    return d.toLocaleDateString(Qt.locale(), "d MMM")
}
