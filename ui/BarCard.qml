import QtQuick
import qs.Commons
import qs.Ui
import "../BarberModel.js" as Model

// The bar as a whole: where it sits, whether it is see-through, and the shortcut that opens edit mode.
Item {
  id: card

  property var service: null

  readonly property var bar: service ? service.bar : Model.readBar(null)
  readonly property string shortcut: service ? service.settings.shortcut : ""
  readonly property color ink: Color.menu.text
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color faint: Qt.rgba(ink.r, ink.g, ink.b, 0.6)

  implicitHeight: content.implicitHeight

  Column {
    id: content
    width: parent.width
    spacing: Style.space(10)

    Text {
      text: "The bar"
      color: card.ink
      font.family: Style.font.family
      font.pixelSize: Style.font.title
      font.bold: true
    }

    ButtonGroup {
      options: [{ value: "top", label: "Top" }, { value: "bottom", label: "Bottom" }, { value: "left", label: "Left" }, { value: "right", label: "Right" }]
      value: card.bar.position
      onChanged: function (v) { if (card.service) card.service.setPosition(v) }
    }

    Row {
      spacing: Style.space(10)

      ToggleSwitch {
        anchors.verticalCenter: parent.verticalCenter
        checked: card.bar.transparent
        foreground: card.ink
        accent: card.accent
        onToggled: if (card.service) card.service.toggleTransparency()
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "See-through"
        color: card.ink
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }

    Rectangle {
      width: parent.width
      height: 1
      color: Qt.rgba(card.ink.r, card.ink.g, card.ink.b, 0.12)
    }

    Dropdown {
      width: parent.width
      label: "Shortcut for edit mode"
      options: Model.SHORTCUTS.map(function (c) { return { value: c, label: c } }).concat([{ value: "", label: "No shortcut" }])
      value: card.shortcut
      onChanged: function (v) { if (card.service) card.service.setShortcut(v) }
    }

    Text {
      width: parent.width
      wrapMode: Text.Wrap
      readonly property string bindState: card.service ? card.service.shortcutState : ""
      text: card.shortcut === "" ? "No shortcut. Edit mode is in the Omarchy menu: Style, then Menu Bar."
        : bindState === "ours" ? "Press " + card.shortcut + " anywhere to edit the bar."
        : bindState === "taken" ? card.shortcut + " already does something else here, so Barber left it alone. Pick another."
        : bindState === "failed" ? "Hyprland did not take " + card.shortcut + ". Pick another, or use the Omarchy menu."
        : "Checking " + card.shortcut + "…"
      color: bindState === "taken" || bindState === "failed" ? card.urgent : card.faint
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
}
