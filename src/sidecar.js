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
