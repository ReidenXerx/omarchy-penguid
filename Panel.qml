// SPDX-License-Identifier: GPL-3.0-or-later
// The PenguID panel: whether face unlock is on and, if not, why; a face test; and the terminal actions that change
// things. Everything is read through bin/penguid-status; anything that changes the system runs in a visible terminal.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
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

  readonly property var view: Model.view(status, statusLoaded)
  readonly property bool needsAttention: view.attention
  readonly property string summaryText: "PenguID: " + view.summary
  readonly property color fg: root.barForeground
  readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.3)
  readonly property string headerMood: testState !== "" ? testState : view.mood

  onOpenedChanged: {
    if (!opened) confirmAction = ""
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
        root.testText = result.text
        testClear.restart()
      }
    }
    onStarted: {
      startedAt = Date.now()
      root.testState = "looking"
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

  function runTest() {
    if (testProc.running) return
    testClear.stop()
    testProc.running = true
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
    focusTarget: keyCatcher
    popoutSwitching: root.popoutSwitching
    popoutSwitchClosing: root.popoutSwitchClosing
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
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
              text: root.testText !== "" ? root.testText : root.view.summary
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
