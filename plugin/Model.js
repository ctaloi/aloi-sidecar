// Small text helpers for the recording dot's tooltip and panel. (The day's
// meetings are Aloi Calendar's now; Sidecar's engine reads them from there.)

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

// Node's tests load this file directly.
if (typeof module !== "undefined") {
  module.exports = { duration: duration, shortTitle: shortTitle }
}
