import QtQuick
import qs.Commons
import qs.Ui
import "../BarberModel.js" as Model

// Saved layouts, and the rules that put them on by themselves.
Item {
  id: card

  property var service: null

  readonly property var settings: service ? service.settings : Model.readSettings(null)
  readonly property var layoutNames: settings.layouts.map(function (l) { return l.name })
  readonly property color ink: Color.menu.text
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color faint: Qt.rgba(ink.r, ink.g, ink.b, 0.6)

  property string deleting: ""
  property string ruleLayout: ""
  property string rulePower: ""
  property string ruleScreens: ""
  property bool ruleFullscreen: false

  implicitHeight: content.implicitHeight

  // Typed straight away: L, a name, Enter.
  Component.onCompleted: nameField.forceActiveFocus()

  function save() {
    if (!card.service) return
    card.service.saveLayout(nameField.text)
    nameField.text = ""
  }

  function addRule() {
    if (!card.service) return
    var layout = card.ruleLayout || (card.layoutNames.length > 0 ? card.layoutNames[0] : "")
    var added = card.service.addRule({ layout: layout, enabled: true,
                                       when: { power: card.rulePower, screens: card.ruleScreens, fullscreen: card.ruleFullscreen, app: appField.text } })
    if (added) {
      card.rulePower = ""
      card.ruleScreens = ""
      card.ruleFullscreen = false
      appField.text = ""
    }
  }

  // Inline components do not see this file's ids, so they take the theme directly.
  component Caption: Text {
    width: parent ? parent.width : implicitWidth
    wrapMode: Text.Wrap
    color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.6)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  component Heading: Text {
    color: Color.menu.text
    font.family: Style.font.family
    font.pixelSize: Style.font.title
    font.bold: true
  }

  Flickable {
    anchors.fill: parent
    contentHeight: content.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: content
      width: card.width
      spacing: Style.space(10)

      Heading { text: "Layouts" }
      Caption { text: "A layout is the whole bar: which widgets, where, with their settings, where the bar sits and whether it is see-through." }

      Row {
        width: parent.width
        spacing: Style.space(6)

        TextField {
          id: nameField
          width: parent.width - saveButton.width - parent.spacing
          placeholderText: "Name this bar, e.g. Docked"
          foreground: card.ink
          accent: card.accent
          onAccepted: card.save()
        }

        Button {
          id: saveButton
          text: "Save"
          bordered: true
          foreground: card.ink
          accent: card.accent
          onClicked: card.save()
        }
      }

      Caption {
        visible: card.settings.layouts.length === 0
        text: "No layouts yet. Arrange the bar, then save it here."
      }

      Repeater {
        model: card.settings.layouts.length

        delegate: Rectangle {
          id: layoutRow
          required property int index
          readonly property var layout: card.settings.layouts[index] || null
          readonly property bool worn: !!(layout && card.service
            && Model.wears(card.service.bar, layout, card.service.installedWidget, card.service.mustStay))

          width: content.width
          height: layoutColumn.implicitHeight + Style.space(12)
          radius: Style.cornerRadius
          color: worn ? Qt.rgba(card.accent.r, card.accent.g, card.accent.b, 0.12) : Qt.rgba(card.ink.r, card.ink.g, card.ink.b, 0.04)

          Column {
            id: layoutColumn
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.space(10); rightMargin: Style.space(6) }
            spacing: Style.space(4)

            Row {
              width: parent.width
              spacing: Style.space(4)

              Column {
                width: parent.width - actions.width - parent.spacing
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  // Widget names come from other people's plugin manifests, which
                  // this plugin only truncates. Rendered literally, not interpreted.
                  textFormat: Text.PlainText
                  width: parent.width
                  elide: Text.ElideRight
                  text: layoutRow.layout ? layoutRow.layout.name + (layoutRow.worn ? "  · on the bar now" : "") : ""
                  color: layoutRow.worn ? card.accent : card.ink
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  // Widget names come from other people's plugin manifests, which
                  // this plugin only truncates. Rendered literally, not interpreted.
                  textFormat: Text.PlainText
                  text: layoutRow.layout ? Model.summarizeLayout(layoutRow.layout) : ""
                  color: card.faint
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              Row {
                id: actions
                spacing: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter

                Button {
                  visible: card.deleting !== layoutRow.layout.name
                  text: "Put on"
                  foreground: card.ink
                  accent: card.accent
                  opacity: layoutRow.worn ? 0.45 : 1
                  onClicked: card.service.wearLayout(layoutRow.layout.name, false)
                }

                Button {
                  visible: card.deleting !== layoutRow.layout.name
                  text: "Update"
                  tooltipText: "Save the bar as it is now under this name"
                  foreground: card.ink
                  accent: card.accent
                  onClicked: card.service.saveLayout(layoutRow.layout.name)
                }

                Button {
                  text: card.deleting === layoutRow.layout.name ? "Delete it" : "Delete"
                  foreground: card.deleting === layoutRow.layout.name ? card.urgent : card.ink
                  accent: card.accent
                  onClicked: {
                    if (card.deleting === layoutRow.layout.name) {
                      card.deleting = ""
                      card.service.deleteLayout(layoutRow.layout.name)
                    } else {
                      card.deleting = layoutRow.layout.name
                    }
                  }
                }

                Button {
                  visible: card.deleting === layoutRow.layout.name
                  text: "Keep"
                  foreground: card.ink
                  accent: card.accent
                  onClicked: card.deleting = ""
                }
              }
            }
          }
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        color: Qt.rgba(card.ink.r, card.ink.g, card.ink.b, 0.12)
      }

      Row {
        spacing: Style.space(10)

        ToggleSwitch {
          anchors.verticalCenter: parent.verticalCenter
          checked: card.settings.auto
          foreground: card.ink
          accent: card.accent
          onToggled: card.service.setAuto(!card.settings.auto)
        }

        Heading {
          anchors.verticalCenter: parent.verticalCenter
          text: "Switch layouts by themselves"
        }
      }

      Caption {
        text: card.service
          ? "Right now: " + Model.describeContext(card.service.context)
            + (card.settings.auto && card.service.wantedLayout ? " → " + card.service.wantedLayout : "")
          : ""
      }

      Dropdown {
        width: parent.width
        label: "Usual layout, when no rule holds"
        options: [{ value: "", label: "None: leave the bar as it is" }].concat(card.layoutNames.map(function (n) { return { value: n, label: n } }))
        value: card.settings.baseLayout
        onChanged: function (v) { card.service.setBaseLayout(v) }
      }

      Caption { text: "Rules are read from the top; the first one that holds puts its layout on." }

      Repeater {
        model: card.settings.rules.length

        delegate: Row {
          id: ruleRow
          required property int index
          readonly property var rule: card.settings.rules[index] || null

          width: content.width
          spacing: Style.space(8)

          ToggleSwitch {
            anchors.verticalCenter: parent.verticalCenter
            checked: ruleRow.rule ? ruleRow.rule.enabled : false
            foreground: card.ink
            accent: card.accent
            onToggled: card.service.setRuleEnabled(ruleRow.index, !ruleRow.rule.enabled)
          }

          Text {
            // Widget names come from other people's plugin manifests, which
            // this plugin only truncates. Rendered literally, not interpreted.
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - removeRule.width - Style.space(60)
            wrapMode: Text.Wrap
            text: ruleRow.rule ? ruleRow.rule.layout + ", " + Model.describeRule(ruleRow.rule) : ""
            color: ruleRow.rule && ruleRow.rule.enabled ? card.ink : card.faint
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Button {
            id: removeRule
            anchors.verticalCenter: parent.verticalCenter
            iconText: String.fromCodePoint(0xf0156)
            tooltipText: "Remove the rule"
            foreground: card.ink
            accent: card.accent
            onClicked: card.service.removeRule(ruleRow.index)
          }
        }
      }

      Column {
        visible: card.layoutNames.length > 0
        width: parent.width
        spacing: Style.space(8)

        Text {
          // Widget names come from other people's plugin manifests, which
          // this plugin only truncates. Rendered literally, not interpreted.
          textFormat: Text.PlainText
          text: "New rule"
          color: card.ink
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Dropdown {
          width: parent.width
          label: "Put on"
          options: card.layoutNames
          value: card.ruleLayout || (card.layoutNames.length > 0 ? card.layoutNames[0] : "")
          onChanged: function (v) { card.ruleLayout = v }
        }

        ButtonGroup {
          options: [{ value: "", label: "Any power" }, { value: "battery", label: "On battery" }, { value: "ac", label: "Plugged in" }]
          value: card.rulePower
          onChanged: function (v) { card.rulePower = v }
        }

        ButtonGroup {
          options: [{ value: "", label: "Any screens" }, { value: "external", label: "Monitor connected" }, { value: "laptop", label: "Laptop screen alone" }]
          value: card.ruleScreens
          onChanged: function (v) { card.ruleScreens = v }
        }

        Row {
          spacing: Style.space(10)

          ToggleSwitch {
            anchors.verticalCenter: parent.verticalCenter
            checked: card.ruleFullscreen
            foreground: card.ink
            accent: card.accent
            onToggled: card.ruleFullscreen = !card.ruleFullscreen
          }

          Text {
            // Widget names come from other people's plugin manifests, which
            // this plugin only truncates. Rendered literally, not interpreted.
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: "While a window is fullscreen"
            color: card.ink
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          TextField {
            id: appField
            width: parent.width - addButton.width - parent.spacing
            placeholderText: "In an app: part of its name or title, e.g. zed"
            foreground: card.ink
            accent: card.accent
            onAccepted: card.addRule()
          }

          Button {
            id: addButton
            text: "Add rule"
            bordered: true
            foreground: card.ink
            accent: card.accent
            onClicked: card.addRule()
          }
        }
      }
    }
  }
}
