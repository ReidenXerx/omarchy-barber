import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Barber's text box: the shell's TextField look around a KeyField, which reads typed keys only (KeyField.qml says why).
FocusScope {
  id: box

  property alias text: field.text
  property alias placeholderText: field.placeholderText
  property alias maximumLength: field.maximumLength
  property alias keyFilter: field.keyFilter
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent

  signal accepted()
  signal editingFinished()

  readonly property bool focused: field.activeFocus
  readonly property var borderSpec: Border.controlSpec(focused ? "focus" : (hover.containsMouse ? "hover-cursor" : "normal"),
                                                       foreground, accent)

  implicitWidth: 200
  implicitHeight: field.implicitHeight + 2 * Style.spacing.inputPaddingY + Border.top(borderSpec) + Border.bottom(borderSpec)

  BorderSurface {
    anchors.fill: parent
    color: Style.controlFill(box.focused, hover.containsMouse, box.foreground, box.accent)
    borderSpec: box.borderSpec
    radius: Style.cornerRadius
  }

  // Anywhere on the box, its border and padding included, puts the caret in it.
  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.IBeamCursor
    onClicked: field.forceActiveFocus()
  }

  KeyField {
    id: field
    focus: true
    anchors.fill: parent
    anchors.leftMargin: Style.spacing.controlPaddingX + Border.left(box.borderSpec)
    anchors.rightMargin: Style.spacing.controlPaddingX + Border.right(box.borderSpec)
    anchors.topMargin: Style.spacing.inputPaddingY + Border.top(box.borderSpec)
    anchors.bottomMargin: Style.spacing.inputPaddingY + Border.bottom(box.borderSpec)
    color: box.foreground
    placeholderColor: Qt.darker(box.foreground, 1.6)
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    onAccepted: box.accepted()
    onEditingFinished: box.editingFinished()
  }
}
