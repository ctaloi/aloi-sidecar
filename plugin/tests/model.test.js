const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

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
