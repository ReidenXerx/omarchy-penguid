// SPDX-License-Identifier: GPL-3.0-or-later
// The PenguID mark: a line-drawn penguin inside scan corners, drawn in a 120 x 120 box and scaled to fit.
// mood: "ready" | "looking" (corners breathe) | "granted" (the penguin winks) | "refused" (flat eyes) | "paused" (dimmed)
// tinted: colour by mood as in the design (amber while looking, green on a match, red after a refusal); color otherwise.
// mini: the bar-size variant, a solid silhouette with heavier corners, because detail vanishes at 16 px.
import QtQuick
import QtQuick.Shapes

Item {
  id: mark

  property color color: "white"
  property color accentColor: color
  property string mood: "ready"
  property bool mini: false
  property bool tinted: false

  // The design's state colours for dark surfaces, such as the blurred lock screen.
  readonly property color lookingColor: "#F2B441"
  readonly property color grantedColor: "#5CC08A"
  readonly property color refusedColor: "#F0877D"
  readonly property bool moodTinted: tinted && (mood === "looking" || mood === "granted" || mood === "refused")
  readonly property color moodColor: mood === "looking" ? lookingColor : (mood === "granted" ? grantedColor : refusedColor)
  property color lineColor: moodTinted ? moodColor : color
  property color detailColor: moodTinted ? moodColor : accentColor
  Behavior on lineColor { ColorAnimation { duration: 180 } }
  Behavior on detailColor { ColorAnimation { duration: 180 } }

  implicitWidth: 24
  implicitHeight: 24
  opacity: mood === "paused" ? 0.45 : 1
  Behavior on opacity { NumberAnimation { duration: 180 } }

  readonly property string framePath: "M8 34V22Q8 8 22 8H34M86 8H98Q112 8 112 22V34M112 86V98Q112 112 98 112H86M34 112H22Q8 112 8 98V86"
  // The full-size penguin is scaled by 0.9 around (60, 62); these paths carry that scale already.
  readonly property string bodyPath: "M60 27.8C69 27.8 75.3 34.1 75.3 44C75.3 53 81.6 63.8 81.6 74.6C81.6 85.4 71.7 90.8 60 90.8C48.3 90.8 38.4 85.4 38.4 74.6C38.4 63.8 44.7 53 44.7 44C44.7 34.1 51 27.8 60 27.8Z"
  readonly property string miniBodyPath: "M60 24C70 24 77 31 77 42C77 52 84 64 84 76C84 88 73 94 60 94C47 94 36 88 36 76C36 64 43 52 43 42C43 31 50 24 60 24Z"
  readonly property string bellyPath: "M51 56.6C46.5 64.7 46.5 77.3 51.9 82.7C55.5 86.3 64.5 86.3 68.1 82.7C73.5 77.3 73.5 64.7 69 56.6"
  readonly property string eyesPath: mood === "granted" ? "M53.7 37.7V42.2M63.15 41.75Q66.3 37.25 69.45 41.75"
                                  : (mood === "refused" ? "M51.45 40.85H55.95M64.05 40.85H68.55" : "M53.7 37.7V42.2M66.3 37.7V42.2")
  readonly property string beakPath: "M55.5 47.6L60 51.65L64.5 47.6"
  readonly property string feetPath: "M49.2 96.2H56.4M63.6 96.2H70.8"

  onMoodChanged: if (mood === "granted") grantPop.restart()

  // A match gives the mark a small bounce.
  SequentialAnimation {
    id: grantPop
    NumberAnimation { target: popLayer; property: "scale"; to: 1.1; duration: 110; easing.type: Easing.OutQuad }
    NumberAnimation { target: popLayer; property: "scale"; to: 1; duration: 220; easing.type: Easing.OutBack }
  }

  Item {
    id: popLayer
    anchors.fill: parent

    Item {
      id: canvas
      width: 120
      height: 120
      anchors.centerIn: parent
      scale: Math.min(mark.width, mark.height) / 120

      Item {
        id: frameLayer
        anchors.fill: parent

        Shape {
          anchors.fill: parent
          preferredRendererType: Shape.CurveRenderer
          antialiasing: true

          ShapePath {
            strokeColor: mark.lineColor
            strokeWidth: mark.mini ? 12 : 6
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: mark.framePath }
          }
        }

        SequentialAnimation on scale {
          running: mark.mood === "looking"
          loops: Animation.Infinite
          alwaysRunToEnd: true
          NumberAnimation { from: 1; to: 0.9; duration: 600; easing.type: Easing.InOutQuad }
          NumberAnimation { from: 0.9; to: 1; duration: 600; easing.type: Easing.InOutQuad }
        }
      }

      // The bar variant: one solid shape reads as a penguin at icon size where lines would not.
      Shape {
        anchors.fill: parent
        visible: mark.mini
        preferredRendererType: Shape.CurveRenderer
        antialiasing: true

        ShapePath {
          strokeColor: "transparent"
          strokeWidth: 0
          fillColor: mark.lineColor
          PathSvg { path: mark.miniBodyPath }
        }
      }

      Shape {
        anchors.fill: parent
        visible: !mark.mini
        preferredRendererType: Shape.CurveRenderer
        antialiasing: true

        ShapePath {
          strokeColor: mark.lineColor
          strokeWidth: 4.5
          fillColor: "transparent"
          capStyle: ShapePath.RoundCap
          joinStyle: ShapePath.RoundJoin
          PathSvg { path: mark.bodyPath + mark.bellyPath }
        }

        ShapePath {
          strokeColor: mark.lineColor
          strokeWidth: 5
          fillColor: "transparent"
          capStyle: ShapePath.RoundCap
          joinStyle: ShapePath.RoundJoin
          PathSvg { path: mark.eyesPath }
        }

        ShapePath {
          strokeColor: mark.detailColor
          strokeWidth: 4.5
          fillColor: "transparent"
          capStyle: ShapePath.RoundCap
          joinStyle: ShapePath.RoundJoin
          PathSvg { path: mark.beakPath + mark.feetPath }
        }
      }
    }
  }
}
