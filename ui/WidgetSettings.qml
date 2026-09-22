import QtQuick
import qs.Commons
import qs.Ui
import "../BarberModel.js" as Model

// The picked widget's settings, drawn from its manifest's schema (or Omarchy's own form for the spacer, clock and
// weather). Each field is applied when it is committed, as one change that undo takes back.
Item {
  id: form

  property var service: null
  property var chip: null
  property bool vertical: false

  readonly property var meta: service && chip ? service.widgetMeta(chip.id) : ({})
  readonly property var fields: chip ? Model.formFieldsFor(meta, chip.options, vertical) : []
  readonly property bool reading: !!(service && chip && service.manifestAsked[chip.id] && service.manifests[chip.id] === undefined)
  readonly property color ink: Color.menu.text
  readonly property color accent: Color.accent
  readonly property color faint: Qt.rgba(ink.r, ink.g, ink.b, 0.6)

  implicitHeight: content.implicitHeight

  function commit(field, value) {
    if (!form.service || !form.chip || !field || value === undefined) return
    form.service.setOption(form.chip, field, value)
  }

  Flickable {
    anchors.fill: parent
    contentHeight: content.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: content
      width: form.width
      spacing: Style.space(12)

      Column {
        width: parent.width
        spacing: Style.space(3)

        Text {
          // Widget names come from other people's plugin manifests, which
          // this plugin only truncates. Rendered literally, not interpreted.
          textFormat: Text.PlainText
          width: parent.width
          elide: Text.ElideRight
          text: form.chip && form.service ? form.service.widgetName(form.chip.id) : "Pick a widget on the bar"
          color: form.ink
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          // Widget names come from other people's plugin manifests, which
          // this plugin only truncates. Rendered literally, not interpreted.
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.Wrap
          text: !form.chip ? ""
            : form.chip.id + " · " + form.chip.section + " side"
              + (form.chip.instances > 1 ? " · on the bar " + form.chip.instances + " times; these settings are for this one" : "")
          color: form.faint
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        // Widget names come from other people's plugin manifests, which
        // this plugin only truncates. Rendered literally, not interpreted.
        textFormat: Text.PlainText
        visible: form.chip !== null && form.fields.length === 0
        width: parent.width
        wrapMode: Text.Wrap
        text: form.reading ? "Reading its settings…" : "This widget has no settings to change."
        color: form.faint
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      // Counted, not listed, so a field being typed in is not made anew when the bar is read back.
      Repeater {
        model: form.fields.length

        delegate: Column {
          id: row
          required property int index
          readonly property var field: form.fields[index] || null

          width: content.width
          spacing: Style.space(4)

          Text {
            // Widget names come from other people's plugin manifests, which
            // this plugin only truncates. Rendered literally, not interpreted.
            textFormat: Text.PlainText
            visible: row.field !== null && row.field.type !== "boolean"
            width: parent.width
            wrapMode: Text.Wrap
            text: row.field ? row.field.label : ""
            color: form.ink
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Loader {
            width: parent.width
            sourceComponent: !row.field ? null
              : row.field.type === "boolean" ? switchField
              : row.field.type === "integer" ? numberField
              : row.field.type === "enum" ? choiceField
              : row.field.type === "multiselect" ? manyField
              : row.field.type === "unknown" ? unknownField
              : textField
          }

          Text {
            // Widget names come from other people's plugin manifests, which
            // this plugin only truncates. Rendered literally, not interpreted.
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            wrapMode: Text.Wrap
            text: row.field ? row.field.description : ""
            color: form.faint
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Component {
            id: switchField
            Row {
              spacing: Style.space(10)
              ToggleSwitch {
                anchors.verticalCenter: parent.verticalCenter
                checked: row.field.value === true
                foreground: form.ink
                accent: form.accent
                onToggled: form.commit(row.field, Model.coerce(row.field, row.field.value !== true))
              }
              Text {
                // Widget names come from other people's plugin manifests, which
                // this plugin only truncates. Rendered literally, not interpreted.
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: row.field.label
                color: form.ink
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }
          }

          // A number is applied once the stepping stops, not at every step.
          Component {
            id: numberField
            Item {
              implicitHeight: spin.implicitHeight
              NumberField {
                id: spin
                label: ""
                value: Number(row.field.value) || 0
                from: row.field.min !== null ? row.field.min : 0
                to: row.field.max !== null ? row.field.max : 100000
                stepSize: Math.max(1, Math.round(row.field.step))
                foreground: form.ink
                accent: form.accent
                onModified: function (v) {
                  settle.pending = v
                  settle.restart()
                }
              }
              Timer {
                id: settle
                property var pending: null
                interval: 600
                onTriggered: form.commit(row.field, Model.coerce(row.field, pending))
              }
            }
          }

          Component {
            id: choiceField
            Dropdown {
              showLabel: false
              options: row.field.choices
              value: String(row.field.value === undefined ? "" : row.field.value)
              onChanged: function (v) { form.commit(row.field, Model.coerce(row.field, v)) }
            }
          }

          Component {
            id: manyField
            Flow {
              spacing: Style.space(4)
              Repeater {
                model: row.field.choices
                delegate: Button {
                  required property var modelData
                  readonly property var chosen: row.field.value instanceof Array ? Array.prototype.slice.call(row.field.value) : []
                  text: modelData
                  selected: chosen.indexOf(modelData) >= 0
                  bordered: true
                  foreground: form.ink
                  accent: form.accent
                  onClicked: {
                    var next = selected ? chosen.filter(function (v) { return v !== modelData }) : chosen.concat([modelData])
                    form.commit(row.field, Model.coerce(row.field, next))
                  }
                }
              }
            }
          }

          Component {
            id: textField
            TextField {
              text: Model.shownText(row.field, row.field.value)
              placeholderText: Model.shownText(row.field, row.field.fallback)
              foreground: form.ink
              accent: form.accent
              onEditingFinished: {
                var value = row.field.type === "number"
                  ? Model.coerce(row.field, text)
                  : Model.coerce(row.field, Model.typedText(row.field, text))
                if (value !== undefined && JSON.stringify(value) !== JSON.stringify(row.field.value)) form.commit(row.field, value)
              }
            }
          }

          Component {
            id: unknownField
            Text {
              // Widget names come from other people's plugin manifests, which
              // this plugin only truncates. Rendered literally, not interpreted.
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: "Barber cannot edit this kind of setting; change it in Shell Settings."
              color: form.faint
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }
}
