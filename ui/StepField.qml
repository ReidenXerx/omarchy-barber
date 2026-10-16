import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Barber's number box: the shell's NumberField look, with a KeyField inside instead of Qt's SpinBox, whose editable
// text reads the clipboard (KeyField.qml says why). Digits are typed and applied on Enter or when the box loses focus;
// − and + (held, they repeat) and the Up and Down keys step. The value always stays within from..to.
FocusScope {
  id: box

  property int value: 0
  property int from: 0
  property int to: 100
  property int stepSize: 1
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent

  signal modified(int value)

  readonly property bool focused: field.activeFocus
  readonly property var borderSpec: Border.controlSpec(focused ? "focus" : (hover.containsMouse ? "hover-cursor" : "normal"),
                                                       foreground, accent)

  implicitWidth: Style.spacing.numberFieldWidth
  implicitHeight: Math.max(Style.spacing.controlHeight, Style.font.body + Style.spacing.controlPaddingY * 2)

  function clamp(n) { return Math.max(box.from, Math.min(box.to, Math.round(n))) }

  // What is typed, when it is a whole number; null while it is empty or only a minus sign.
  function typed() {
    return /^-?[0-9]{1,9}$/.test(field.text) ? Number(field.text) : null
  }

  function apply(n) {
    var v = box.clamp(n)
    field.text = String(v)
    if (v !== box.value) box.modified(v)
  }

  function stepBy(k) {
    var now = box.typed()
    box.apply((now === null ? box.value : now) + k * Math.max(1, box.stepSize))
  }

  // The value set from outside is shown, except while you are typing over it.
  onValueChanged: if (!field.activeFocus) field.text = String(box.value)
  Component.onCompleted: field.text = String(box.value)

  BorderSurface {
    anchors.fill: parent
    color: Style.controlFill(box.focused, hover.containsMouse, box.foreground, box.accent)
    borderSpec: box.borderSpec
    radius: Style.cornerRadius
  }

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.IBeamCursor
    onClicked: field.forceActiveFocus()
  }

  // Inline components do not see this file's ids, so each stepper is handed its box.
  component Stepper: Item {
    id: stepper
    property var owner: null
    property string glyph: ""
    property int direction: 1
    readonly property int current: owner ? (owner.typed() ?? owner.value) : 0
    readonly property bool usable: owner !== null && (direction < 0 ? current > owner.from : current < owner.to)
    width: height
    anchors.top: parent.top
    anchors.bottom: parent.bottom

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: stepper.glyph
      color: stepper.owner ? stepper.owner.foreground : "white"
      opacity: !stepper.usable ? 0.35 : press.containsMouse ? 1 : 0.7
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    MouseArea {
      id: press
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onPressed: { stepper.owner.stepBy(stepper.direction); ticker.interval = 400; ticker.start() }
      onReleased: ticker.stop()
      onCanceled: ticker.stop()
    }

    Timer {
      id: ticker
      repeat: true
      onTriggered: { interval = 80; stepper.owner.stepBy(stepper.direction) }
    }
  }

  Stepper {
    id: minus
    anchors.left: parent.left
    anchors.leftMargin: Border.left(box.borderSpec)
    owner: box
    glyph: "−"
    direction: -1
  }

  Stepper {
    id: plus
    anchors.right: parent.right
    anchors.rightMargin: Border.right(box.borderSpec)
    owner: box
    glyph: "+"
    direction: 1
  }

  KeyField {
    id: field
    focus: true
    anchors.left: minus.right
    anchors.right: plus.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.topMargin: Border.top(box.borderSpec)
    anchors.bottomMargin: Border.bottom(box.borderSpec)
    maximumLength: 10
    pasteEnabled: false
    color: box.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    // Up and Down step; anything typed that is not a digit (or a leading minus, where the range allows one) is
    // dropped here, so the box only ever holds a number.
    keyFilter: function (event) {
      if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
        event.accepted = true
        box.stepBy(event.key === Qt.Key_Up ? 1 : -1)
        return
      }
      var t = event.text
      if ((event.modifiers & Qt.ControlModifier) === 0 && t.length > 0 && t.charCodeAt(0) >= 32
          && !/^[0-9]$/.test(t) && !(t === "-" && box.from < 0 && field.text === ""))
        event.accepted = true
    }
    onEditingFinished: {
      var n = box.typed()
      if (n === null) field.text = String(box.value)
      else box.apply(n)
    }
  }
}
