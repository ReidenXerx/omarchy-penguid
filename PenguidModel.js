// SPDX-License-Identifier: GPL-3.0-or-later
// Pure functions behind the PenguID bar widget and panel: status parsing, the rows, the summary, face test results.
.pragma library

var ELLIPSIS = String.fromCharCode(0x2026)

function parseStatus(text) {
  try {
    var doc = JSON.parse(String(text || "").trim())
    return doc && doc.version === 1 ? doc : null
  } catch (e) {
    return null
  }
}

function plural(n, one, many) {
  return n + " " + (n === 1 ? one : many)
}

function blockedText(reason) {
  if (reason === "48h") return "Paused: type your password once (48 hours without it)"
  if (reason === "failures") return "Paused: 5 refused tries, type your password"
  if (reason === "unknown") return "Paused until you type your password"
  return "Paused"
}

// Rows for the panel, the tooltip summary, whether the bar shows its dot, and the header mood.
// Only things face unlock needs you for light the dot; standing warnings such as Secure Boot do not.
function view(status, loaded) {
  if (!loaded || !status) {
    return { summary: "PenguID: checking" + ELLIPSIS, attention: false, rows: [], mood: "ready", checks: [] }
  }

  var rows = []
  var attention = []
  var engine = status.engine || {}
  var enrollment = status.enrollment || {}
  var lock = status.lock || {}
  var privileged = status.privileged || {}

  if (!status.irlumeInstalled) {
    rows.push({ key: "engine", label: "Engine", value: "irlume is not installed", state: "warn" })
    attention.push("irlume is not installed")
  } else if (!engine.reachable || engine.daemon !== "running") {
    rows.push({ key: "engine", label: "Engine", value: "irlume is not running", state: "warn" })
    attention.push("irlume is not running")
  } else {
    var mode = engine.sensor === "ir-only" ? "IR only" : (engine.sensor === "dual" ? "IR and colour" : "mode unknown")
    rows.push({ key: "engine", label: "Engine", value: "irlume running, " + mode, state: "ok" })
  }

  if (enrollment.known && (enrollment.profiles || 0) > 0) {
    var face = plural(enrollment.scans || 0, "scan", "scans")
    if (enrollment.templates === "encrypted") face += ", encrypted"
    rows.push({ key: "face", label: "Your face", value: face, state: "ok" })
  } else if (enrollment.known) {
    rows.push({ key: "face", label: "Your face", value: "Not enrolled yet", state: "warn" })
    attention.push("No face enrolled")
  } else {
    rows.push({ key: "face", label: "Your face", value: "Unknown", state: "off" })
  }

  if (!lock.ours) {
    rows.push({ key: "lock", label: "Lock screen", value: "Omarchy's own lock screen is running", state: "warn" })
    attention.push("PenguID's lock screen is not running")
  } else if (!lock.face) {
    rows.push({ key: "lock", label: "Lock screen", value: "Face lane off (no /etc/pam.d/omarchy-lock-face)", state: "warn" })
    attention.push("The face lane is off")
  } else if (lock.blocked) {
    rows.push({ key: "lock", label: "Lock screen", value: blockedText(lock.blocked), state: "warn" })
    attention.push(blockedText(lock.blocked))
  } else {
    var failures = lock.failures || 0
    rows.push({ key: "lock", label: "Lock screen", value: failures > 0 ? "Face on, " + plural(failures, "refused try", "refused tries") : "Face on", state: "ok" })
  }

  var both = privileged.sudo && privileged.polkit
  var either = privileged.sudo || privileged.polkit
  rows.push({
    key: "privileged",
    label: "sudo and polkit",
    value: both ? "Face on (type yes)" : (either ? (privileged.sudo ? "Face on for sudo only" : "Face on for polkit only") : "Password only"),
    state: both ? "ok" : "off",
    wired: both
  })

  // irlume cannot see PenguID's own PAM lines, so its login-wiring warning is expected here and left out.
  // Array.isArray misses QML sequences and instanceof misses arrays from another JS realm, so accept either.
  var list = status.checks
  var checks = (Array.isArray(list) || list instanceof Array ? Array.prototype.slice.call(list) : []).filter(function (c) { return c && c.id !== "login-wiring" })
  var summary = attention.length > 0 ? attention[0] : "Face unlock is on"
  return { summary: summary, attention: attention.length > 0, rows: rows, mood: attention.length > 0 ? "paused" : "ready", checks: checks }
}

// One irlume `auth test --events=jsonl` run: a state for the mark and a sentence.
function testResult(text, elapsedMs) {
  var lines = String(text || "").split("\n")
  var terminal = null
  var plain = null
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    try {
      var doc = JSON.parse(line)
      if (doc && doc.terminal) terminal = doc
      else if (doc && doc.event === undefined) plain = doc
    } catch (e) {}
  }
  var seconds = (Math.max(0, elapsedMs || 0) / 1000).toFixed(1) + " s"

  if (terminal && terminal.event === "result") {
    var data = terminal.data || {}
    if (data.granted) return { state: "granted", text: "Recognized in " + seconds }
    var why = data.refusal || data.reason || ""
    var words = { "no-match": "a face, but not yours", "not-live": "that did not look like a live face", "policy": "refused by irlume's policy (retry limit or settings)" }
    return { state: "refused", text: "Not recognized: " + (words[why] || why || "refused") + " (" + seconds + ")" }
  }

  var source = terminal || plain
  var code = source && source.error ? (source.error.code || "") : ""
  if (code === "session-busy") return { state: "refused", text: "Another face test is running" }
  if (code === "operation-failed") return { state: "refused", text: "No face found in time, or the camera is busy (" + seconds + ")" }
  return { state: "refused", text: "The test could not run" + (code ? " (" + code + ")" : "") }
}

// The terminal command lines behind the panel's buttons.
function actionCommand(action, profile, pluginDir) {
  if (action === "add-scans") return ["irlume", "profiles", "add-scan", "--profile", profile || "Face Profile 1"]
  if (action === "enroll-again") return ["irlume", "enroll", "--reset"]
  if (action === "privileged-on") return ["sudo", pluginDir + "/tools/privileged-pam.sh", "enable"]
  if (action === "privileged-off") return ["sudo", pluginDir + "/tools/privileged-pam.sh", "disable"]
  if (action === "doctor") return ["irlume", "doctor"]
  return null
}

// One argument as a single-quoted shell word: the terminal launcher runs its command through bash -c.
function shellQuote(arg) {
  return "'" + String(arg).replace(/'/g, "'\\''") + "'"
}

function commandLine(argv) {
  return argv.map(shellQuote).join(" ")
}
