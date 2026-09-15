// Tests for PenguID's polkit dialog helpers: node tests/polkit-test.js
"use strict"

const assert = require("assert")
const fs = require("fs")
const path = require("path")

const root = path.join(__dirname, "..")
const M = require(path.join(root, "polkit", "PolkitModel.js"))

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

test("the Enter prompt is recognized, a plain password prompt is not", () => {
  assert.strictEqual(M.promptOffersFace("Press Enter for face, or type your password: "), true)
  assert.strictEqual(M.promptOffersFace("Password: "), false)
  assert.strictEqual(M.promptOffersFace(""), false)
})

test("the dialog recognizes the prompt pam_penguid.c actually sends", () => {
  const source = fs.readFileSync(path.join(root, "pam", "pam_penguid.c"), "utf8")
  const match = source.match(/#define PROMPT "([^"]+)"/)
  assert.ok(match, "PROMPT define")
  assert.strictEqual(M.promptOffersFace(match[1]), true)
})

test("Omarchy's helpers still behave", () => {
  assert.strictEqual(M.authorizationLabel("Authentication is needed to run `/usr/bin/true' as the super user"), "Authorize running '/usr/bin/true'")
  assert.strictEqual(M.fingerprintConfiguredFromPamConfig("auth sufficient pam_fprintd.so\n"), true)
})

console.log("polkit tests: " + passed + " passed")
