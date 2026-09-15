// Tests for PenguidModel.js: node tests/model-test.js
"use strict"

const assert = require("assert")
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const source = fs.readFileSync(path.join(__dirname, "..", "PenguidModel.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const context = {}
vm.createContext(context)
vm.runInContext(source, context)
const M = context

let passed = 0
function test(name, fn) {
  try {
    fn()
    passed += 1
  } catch (error) {
    console.error("FAIL " + name)
    throw error
  }
}

function healthy(overrides) {
  const base = {
    version: 1,
    irlumeInstalled: true,
    engine: { reachable: true, daemon: "running", sensor: "ir-only" },
    enrollment: { known: true, profiles: 1, scans: 10, templates: "encrypted" },
    profile: "Face Profile 1",
    lock: { ours: true, face: true, blocked: "", failures: 0, locked: false },
    privileged: { sudo: true, polkit: true },
    checks: [{ id: "secure-boot", state: "warn" }, { id: "login-wiring", state: "warn" }],
  }
  return Object.assign(base, overrides || {})
}

test("parseStatus accepts version 1 only", () => {
  assert.strictEqual(M.parseStatus('{"version":1,"x":2}').x, 2)
  assert.strictEqual(M.parseStatus('{"version":2}'), null)
  assert.strictEqual(M.parseStatus("not json"), null)
  assert.strictEqual(M.parseStatus(""), null)
})

test("view before the first status says it is checking and lights nothing", () => {
  const v = M.view(null, false)
  assert.strictEqual(v.attention, false)
  assert.ok(v.summary.startsWith("PenguID: checking"))
  assert.strictEqual(v.rows.length, 0)
})

test("a healthy setup reads face on, with no dot", () => {
  const v = M.view(healthy(), true)
  assert.strictEqual(v.attention, false)
  assert.strictEqual(v.summary, "Face unlock is on")
  assert.strictEqual(v.mood, "ready")
  assert.deepStrictEqual(Array.from(v.rows, r => r.key), ["engine", "face", "lock", "privileged"])
  assert.strictEqual(v.rows[0].value, "irlume running, IR only")
  assert.strictEqual(v.rows[1].value, "10 scans, encrypted")
  assert.strictEqual(v.rows[2].value, "Face on")
  assert.strictEqual(v.rows[3].value, "Face on (type yes)")
  assert.strictEqual(v.rows[3].wired, true)
})

test("irlume's login-wiring warning is left out, others stay", () => {
  const v = M.view(healthy(), true)
  assert.deepStrictEqual(Array.from(v.checks, c => c.id), ["secure-boot"])
})

test("the 48-hour rule lights the dot and says what to do", () => {
  const v = M.view(healthy({ lock: { ours: true, face: true, blocked: "48h", failures: 0 } }), true)
  assert.strictEqual(v.attention, true)
  assert.strictEqual(v.mood, "paused")
  assert.ok(v.summary.includes("type your password once"))
})

test("a stopped daemon, a missing lane and the built-in lock all need attention", () => {
  assert.strictEqual(M.view(healthy({ engine: { reachable: false, daemon: null, sensor: "unknown" } }), true).summary, "irlume is not running")
  assert.ok(M.view(healthy({ lock: { ours: true, face: false } }), true).summary.includes("face lane is off"))
  assert.ok(M.view(healthy({ lock: { ours: false, face: false } }), true).summary.includes("lock screen is not running"))
})

test("sudo and polkit wording covers both, one and none", () => {
  const row = s => M.view(healthy({ privileged: s }), true).rows[3]
  assert.strictEqual(row({ sudo: false, polkit: false }).value, "Password only")
  assert.strictEqual(row({ sudo: true, polkit: false }).value, "Face on for sudo only")
  assert.strictEqual(row({ sudo: false, polkit: true }).value, "Face on for polkit only")
  assert.strictEqual(row({ sudo: false, polkit: false }).wired, false)
})

test("face test results read as sentences", () => {
  const granted = '{"event":"started","terminal":false}\n{"event":"result","terminal":true,"data":{"granted":true,"live":true,"reason":"granted"}}\n'
  assert.deepStrictEqual(JSON.parse(JSON.stringify(M.testResult(granted, 3620))), { state: "granted", text: "Recognized in 3.6 s" })
  const fake = '{"event":"result","terminal":true,"data":{"granted":false,"live":false,"reason":"not-live","refusal":"not-live"}}'
  assert.strictEqual(M.testResult(fake, 3300).state, "refused")
  assert.ok(M.testResult(fake, 3300).text.includes("live face"))
  const failed = '{"command":"auth.test","event":"error","terminal":true,"error":{"code":"operation-failed","retryable":false}}'
  assert.ok(M.testResult(failed, 15500).text.startsWith("No face found in time"))
  const busy = '{"ok":false,"error":{"code":"session-busy"}}'
  assert.strictEqual(M.testResult(busy, 10).text, "Another face test is running")
  assert.strictEqual(M.testResult("", 0).text, "The test could not run")
})

test("terminal commands are quoted argument by argument", () => {
  assert.strictEqual(M.commandLine(["irlume", "profiles", "add-scan", "--profile", "It's me"]),
    "'irlume' 'profiles' 'add-scan' '--profile' 'It'\\''s me'")
  assert.strictEqual(M.commandLine(Array.from(M.actionCommand("privileged-on", null, "/p/x"))), "'sudo' '/p/x/tools/privileged-pam.sh' 'enable'")
  assert.strictEqual(M.actionCommand("rm -rf", null, "/p"), null)
  assert.strictEqual(M.actionCommand("add-scans", null, "/p")[4], "Face Profile 1")
})

console.log("model tests: " + passed + " passed")
