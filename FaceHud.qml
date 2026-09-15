// SPDX-License-Identifier: GPL-3.0-or-later
// PenguID's face HUD: the mark in a card above every window, fullscreen apps included, like Face ID on iOS. It shows
// whenever face unlock runs outside the lock screen: corners breathing in amber while irlume looks, then a green wink
// or red flat eyes with a shake, before it fades. Visual only: the input region is empty, so it takes no click or key.
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Item {
  id: hud

  // The lock screen draws its own mark, so the HUD keeps away while it is up.
  property bool suppressed: false
  property string mood: "looking"
  property bool opened: false
  property int shakeOffset: 0

  readonly property int cardSize: Style.space(164)

  // looking, granted, refused or hide.
  function show(state) {
    if (state === "hide") {
      opened = false
      return
    }
    if (suppressed || (state !== "looking" && state !== "granted" && state !== "refused")) return
    mood = state
    opened = true
    // A scan that never reports back still goes away.
    closeTimer.interval = state === "looking" ? 15000 : (state === "granted" ? 900 : 1300)
    closeTimer.restart()
    if (state === "refused") shake.restart()
  }

  onSuppressedChanged: if (suppressed) opened = false

  Timer {
    id: closeTimer
    repeat: false
    onTriggered: hud.opened = false
  }

  SequentialAnimation {
    id: shake
    NumberAnimation { target: hud; property: "shakeOffset"; to: -10; duration: 45; easing.type: Easing.OutQuad }
    NumberAnimation { target: hud; property: "shakeOffset"; to: 10; duration: 70; easing.type: Easing.InOutQuad }
    NumberAnimation { target: hud; property: "shakeOffset"; to: -6; duration: 60; easing.type: Easing.InOutQuad }
    NumberAnimation { target: hud; property: "shakeOffset"; to: 0; duration: 55; easing.type: Easing.OutQuad }
  }

  PanelWindow {
    // Stays mapped while the card fades out.
    visible: hud.opened || card.opacity > 0
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "penguid-hud"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}

    BorderSurface {
      id: card
      width: hud.cardSize
      height: hud.cardSize
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.horizontalCenterOffset: hud.shakeOffset
      // Near the top edge, just under a top bar, like Face ID on iOS.
      anchors.top: parent.top
      anchors.topMargin: Style.bar.sizeHorizontal + Style.space(18)
      color: Util.alpha(Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      opacity: hud.opened ? 1 : 0
      scale: hud.opened ? 1 : 0.9
      Behavior on opacity { NumberAnimation { duration: hud.opened ? 160 : 240; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack } }

      PenguinMark {
        anchors.centerIn: parent
        width: Math.round(hud.cardSize * 0.6)
        height: width
        tinted: true
        color: Color.popups.text
        mood: hud.mood
      }
    }
  }
}
