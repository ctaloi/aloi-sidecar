const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

const root = path.join(__dirname, "..")
const catalog = JSON.parse(fs.readFileSync(path.join(root, "i18n/en.json"), "utf8"))
const sources = ["RecorderContent.qml", "BarWidget.qml"].map(f => fs.readFileSync(path.join(root, f), "utf8"))

test("every string the plugin shows exists in en.json", () => {
  const used = new Set()
  for (const source of sources)
    for (const m of source.matchAll(/\bt\("([A-Za-z0-9.]+)"/g)) used.add(m[1])
  assert.deepEqual([...used].filter(k => !(k in catalog)), [])
})

test("every string in en.json is used", () => {
  const all = sources.join("\n")
  assert.deepEqual(Object.keys(catalog).filter(k => !all.includes(`"${k}"`)), [])
})

test("placeholders are named and every string is plain text", () => {
  for (const [key, value] of Object.entries(catalog)) {
    assert.equal(typeof value, "string", key)
    assert.doesNotMatch(value, /<[a-z]/i, key)
    assert.doesNotMatch(value, /%\d/, key)
  }
})
