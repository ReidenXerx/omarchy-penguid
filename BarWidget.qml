// SPDX-License-Identifier: GPL-3.0-or-later
// PenguID in the bar: the penguin in its scan frame, a dot when face unlock needs you, and the panel on click.
// It never touches the lock screen service; the panel reads everything through bin/penguid-status.
import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "reidenxerx.penguid"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() { if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle() }
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item && panelLoader.item.open) panelLoader.item.open() }
  function close() { if (panelLoader.item && panelLoader.item.close) panelLoader.item.close() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  readonly property bool needsAttention: panelLoader.item ? panelLoader.item.needsAttention === true : false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    foreground: root.bar ? root.bar.barForeground : Color.foreground
    tooltipText: panelLoader.item ? panelLoader.item.summaryText : "PenguID"
    onPressed: function (b) { root.togglePanel() }

    // Drawn, not a font glyph: the mark is PenguID's own. Same colour as every other bar icon; state goes in the dot.
    iconComponent: Component {
      PenguinMark {
        mini: true
        color: button.foreground
      }
    }

    // A dot rather than a tint, the way the bell marks unread: only when face unlock is paused or broken.
    Rectangle {
      visible: root.needsAttention
      width: Style.space(6)
      height: width
      radius: width / 2
      color: Color.urgent
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(3)
      anchors.topMargin: Style.space(5)
    }
  }
}
