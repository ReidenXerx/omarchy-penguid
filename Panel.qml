// SPDX-License-Identifier: GPL-3.0-or-later
// The PenguID panel: whether face unlock is on and, if not, why; a face test; and the terminal actions that change
// things. Everything is read through bin/penguid-status; anything that changes the system runs in a visible terminal.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import qs.Commons
import qs.Ui
import "PenguidModel.js" as Model

Panel {
  id: root
  moduleName: "reidenxerx.penguid"
  ipcTarget: "reidenxerx.penguid"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string python: "/usr/bin/python3"
  readonly property string irlume: "/usr/bin/irlume"
  readonly property string terminalLauncher: "/usr/bin/omarchy-launch-floating-terminal-with-presentation"
  readonly property string ellipsis: String.fromCharCode(0x2026)

  property var status: null
  property bool statusLoaded: false
  property int openTicks: 0
  property string testState: ""
  property string testText: ""
  // The action waiting for its second click.
  property string confirmAction: ""
  // The 48-hour password gate, confirmed here with the same password-only PAM stack the lock screen uses.
  property bool checkingPassword: false
  property string pendingPassword: ""
  property string passwordError: ""
  property bool passwordConfirmed: false

  readonly property var view: Model.view(status, statusLoaded, Date.now())
  readonly property bool needsAttention: view.attention
  readonly property string summaryText: "PenguID: " + view.summary
  readonly property color fg: root.barForeground
  readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.3)
  readonly property string headerMood: testState !== "" ? testState : view.mood

  onOpenedChanged: {
    if (!opened) {
      confirmAction = ""
      passwordError = ""
      passwordField.text = ""
    }
    openTicks = 0
  }

  // ---------------------------------------------------------------- status

  Process {
    id: statusProc
    property bool quick: false
    command: [root.python, "-B", root.pluginDir + "/bin/penguid-status"].concat(quick ? ["--quick"] : [])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseStatus(text)
        if (!parsed) return
        // A quick refresh skips the doctor checks; keep the last ones instead of dropping them.
        if (parsed.checks === undefined && root.status && root.status.checks) parsed.checks = root.status.checks
        root.status = parsed
        root.statusLoaded = true
      }
    }
    onStarted: statusWatchdog.restart()
    onExited: statusWatchdog.stop()
  }

  Timer {
    id: statusWatchdog
    interval: 40000
    onTriggered: if (statusProc.running) statusProc.signal(9)
  }

  function refresh(quick) {
    if (statusProc.running) return
    statusProc.quick = quick === true
    statusProc.running = true
  }

  // While open: everything on opening, then a quick look every 5 s and the checks again once a minute.
  Timer {
    running: root.opened
    interval: 5000
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.refresh(root.openTicks % 12 !== 0)
      root.openTicks += 1
    }
  }

  // While closed: enough to keep the bar dot honest, without the checks.
  Timer {
    running: !root.opened
    interval: 60000
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(true)
  }

  // ---------------------------------------------------------------- face test

  Process {
    id: testProc
    property double startedAt: 0
    command: [root.irlume, "auth", "test", "--events=jsonl", "--contract", "1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = Model.testResult(text, Date.now() - testProc.startedAt)
        root.testState = result.state
        root.tellHud(result.state)
        root.testText = result.text
        testClear.restart()
      }
    }
    onStarted: {
      startedAt = Date.now()
      root.testState = "looking"
      root.tellHud("looking")
      root.testText = "Look at the camera" + root.ellipsis
      testWatchdog.restart()
    }
    onExited: testWatchdog.stop()
  }

  Timer {
    id: testWatchdog
    interval: 30000
    onTriggered: if (testProc.running) testProc.signal(15)
  }

  Timer {
    id: testClear
    interval: 15000
    onTriggered: {
      if (testProc.running) return
      root.testState = ""
      root.testText = ""
    }
  }

  // The face HUD shows the test above everything, like any other face attempt.
  function tellHud(state) {
    Quickshell.execDetached(["omarchy-shell", "penguid", "hud", state])
  }

  function runTest() {
    if (testProc.running) return
    testClear.stop()
    testProc.running = true
  }

  // ---------------------------------------------------------------- password gate

  PamContext {
    id: passwordCheck
    config: "omarchy-lock-password"
    user: Quickshell.env("USER") || Quickshell.env("LOGNAME")

    onResponseRequiredChanged: root.respondToPassword()
    onPamMessage: root.respondToPassword()

    // PamContext follows an error with completed(Error), so this is the only handler.
    onCompleted: function (result) {
      root.checkingPassword = false
      root.pendingPassword = ""
      if (result === PamResult.Success) root.recordPassword()
      else if (result === PamResult.MaxTries) root.passwordError = "Too many tries. Wait a couple of minutes, then try again"
      else if (result === PamResult.Failed) root.passwordError = "That password did not work"
      else root.passwordError = "The password could not be checked"
    }
  }

  // The lock screen's rule state. The lock screen watches this file and applies the new time at once.
  FileView {
    id: faceStateFile
    path: Quickshell.env("HOME") + "/.local/state/penguid/state.json"
    atomicWrites: true
    printErrors: false
  }

  Timer {
    id: passwordConfirmedClear
    interval: 8000
    onTriggered: root.passwordConfirmed = false
  }

  Timer {
    id: passwordRefresh
    interval: 800
    onTriggered: root.refresh(true)
  }

  function submitPassword(value) {
    if (root.checkingPassword || !value) return
    root.pendingPassword = value
    root.passwordError = ""
    root.checkingPassword = true
    if (!passwordCheck.start()) {
      root.checkingPassword = false
      root.pendingPassword = ""
      root.passwordError = "The password could not be checked"
      return
    }
    Qt.callLater(root.respondToPassword)
  }

  function respondToPassword() {
    if (!root.checkingPassword || !passwordCheck.active || !passwordCheck.responseRequired) return
    passwordCheck.respond(root.pendingPassword)
  }

  function recordPassword() {
    faceStateFile.setText(JSON.stringify({ version: 1, lastPasswordAt: Date.now(), faceFailures: 0 }, null, 2) + "\n")
    root.passwordError = ""
    root.passwordConfirmed = true
    passwordConfirmedClear.restart()
    passwordRefresh.restart()
  }

  // ---------------------------------------------------------------- actions

  function launch(action) {
    var argv = Model.actionCommand(action, root.status ? root.status.profile : null, root.pluginDir)
    if (!argv) return
    root.confirmAction = ""
    // The launcher runs its arguments through bash -c, so it gets one command line quoted argument by argument.
    Quickshell.execDetached([root.terminalLauncher, Model.commandLine(argv)])
    root.close()
  }

  function press(action, confirm) {
    if (confirm && root.confirmAction !== action) {
      root.confirmAction = action
      confirmExpiry.restart()
      return
    }
    root.launch(action)
  }

  Timer {
    id: confirmExpiry
    interval: 4000
    onTriggered: root.confirmAction = ""
  }

  component TextButton: Rectangle {
    id: button
    property string label: ""
    property bool asking: false
    property bool busy: false
    signal activated()

    implicitWidth: buttonText.implicitWidth + Style.space(20)
    implicitHeight: Style.space(28)
    radius: Style.space(6)
    color: buttonArea.containsMouse && !button.busy ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
    border.width: 1
    border.color: button.asking ? Color.urgent : root.faint

    Text {
      id: buttonText
      anchors.centerIn: parent
      text: button.label
      color: button.asking ? Color.urgent : root.fg
      opacity: button.busy ? 0.6 : 1
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: buttonArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: button.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
      onClicked: if (!button.busy) button.activated()
    }
  }

  // ---------------------------------------------------------------- view

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    // Paused: the password field takes the keys as soon as the panel opens.
    focusTarget: root.view.gateNeeded ? passwordField : keyCatcher
    popoutSwitching: root.popoutSwitching
    popoutSwitchClosing: root.popoutSwitchClosing
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The catcher takes keys before its children; step aside while the password field is typed into.
      blocked: passwordField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      ColumnLayout {
        id: column
        width: parent.width
        spacing: Style.space(12)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(14)

          PenguinMark {
            Layout.preferredWidth: Style.space(46)
            Layout.preferredHeight: Style.space(46)
            color: root.fg
            accentColor: Color.accent
            tinted: true
            mood: root.headerMood
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(3)

            Row {
              Text {
                text: "Pengu"
                color: root.fg
                font.pixelSize: Style.font.heading
                font.bold: true
              }
              Text {
                text: "ID"
                color: Color.accent
                font.pixelSize: Style.font.heading
                font.bold: true
              }
            }

            Text {
              Layout.fillWidth: true
              text: root.testText !== "" ? root.testText : (root.passwordConfirmed ? "Password confirmed: face unlock is on for the next 48 hours" : root.view.summary)
              color: root.testState === "refused" ? Color.urgent : root.fg
              opacity: root.testText !== "" ? 1 : 0.7
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }
          }
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: 1
          color: root.faint
        }

        Repeater {
          model: root.view.rows

          delegate: RowLayout {
            id: row
            required property var modelData
            Layout.fillWidth: true
            spacing: Style.space(10)

            Rectangle {
              Layout.preferredWidth: Style.space(7)
              Layout.preferredHeight: Style.space(7)
              Layout.alignment: Qt.AlignVCenter
              radius: width / 2
              color: row.modelData.state === "ok" ? Color.accent : (row.modelData.state === "warn" ? Color.urgent : root.faint)
            }

            Text {
              Layout.preferredWidth: Style.space(112)
              text: row.modelData.label
              color: root.fg
              opacity: 0.6
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              Layout.fillWidth: true
              text: row.modelData.value
              color: root.fg
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }

            TextButton {
              visible: row.modelData.key === "privileged"
              readonly property string action: row.modelData.wired ? "privileged-off" : "privileged-on"
              label: root.confirmAction === action ? (row.modelData.wired ? "Turn off?" : "Turn on?") : (row.modelData.wired ? "Turn off" : "Turn on")
              asking: root.confirmAction === action
              onActivated: root.press(action, true)
            }
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          visible: root.view.gateNeeded
          spacing: Style.space(6)

          Text {
            Layout.fillWidth: true
            text: root.view.gateText
            color: root.fg
            opacity: 0.85
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Rectangle {
              Layout.fillWidth: true
              implicitHeight: Style.space(28)
              radius: Style.space(6)
              color: "transparent"
              border.width: 1
              border.color: passwordField.activeFocus ? Color.accent : root.faint

              TextInput {
                id: passwordField
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                verticalAlignment: TextInput.AlignVCenter
                echoMode: TextInput.Password
                color: root.fg
                font.pixelSize: Style.font.body
                clip: true
                enabled: !root.checkingPassword
                onAccepted: {
                  var value = text
                  text = ""
                  root.submitPassword(value)
                }
                Keys.onEscapePressed: root.close()
              }

              Text {
                anchors.fill: passwordField
                verticalAlignment: Text.AlignVCenter
                visible: passwordField.text.length === 0
                text: root.checkingPassword ? "Checking" + root.ellipsis : "Password"
                color: root.fg
                opacity: 0.4
                font.pixelSize: Style.font.body
              }
            }

            TextButton {
              label: root.checkingPassword ? "Checking" + root.ellipsis : "Confirm"
              busy: root.checkingPassword
              onActivated: {
                var value = passwordField.text
                passwordField.text = ""
                root.submitPassword(value)
              }
            }
          }

          Text {
            Layout.fillWidth: true
            visible: root.passwordError !== ""
            text: root.passwordError
            color: Color.urgent
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }
        }

        Text {
          Layout.fillWidth: true
          visible: !root.view.gateNeeded && root.view.dueText !== ""
          text: root.view.dueText
          color: root.fg
          opacity: 0.5
          font.pixelSize: Style.font.caption
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: 1
          color: root.faint
        }

        Flow {
          Layout.fillWidth: true
          spacing: Style.space(8)

          TextButton {
            label: testProc.running ? "Looking" + root.ellipsis : "Test my face"
            busy: testProc.running
            onActivated: root.runTest()
          }
          TextButton {
            label: "Add scans"
            onActivated: root.press("add-scans", false)
          }
          TextButton {
            label: root.confirmAction === "enroll-again" ? "Replace your face?" : "Enroll again"
            asking: root.confirmAction === "enroll-again"
            onActivated: root.press("enroll-again", true)
          }
          TextButton {
            label: "Checks"
            onActivated: root.press("doctor", false)
          }
        }

        Text {
          Layout.fillWidth: true
          visible: root.view.checks.length > 0
          text: root.view.checks.length + (root.view.checks.length === 1 ? " warning from irlume: " : " warnings from irlume: ")
                + root.view.checks.map(function (c) { return c.id }).join(", ")
          color: root.fg
          opacity: 0.5
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }
      }
    }
  }
}
