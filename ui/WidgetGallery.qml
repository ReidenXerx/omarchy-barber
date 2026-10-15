import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../BarberModel.js" as Model

// Widgets that can go on the bar and are not on it, found by typing. A pick goes after the widget chosen on the bar,
// or to the widget's own side of the bar when none is chosen.
Item {
  id: gallery

  property var service: null
  property var selected: null
  signal added(string id)

  property string query: ""
  property int current: 0
  readonly property var items: service ? Model.gallery(service.plugins, service.catalog, query) : []
  readonly property color ink: Commons.Color.menu.text
  readonly property color accent: Commons.Color.accent
  readonly property color faint: Qt.rgba(ink.r, ink.g, ink.b, 0.6)

  implicitHeight: header.implicitHeight + Style.space(8) + (items.length > 0 ? Math.min(list.contentHeight, Style.space(420)) : empty.implicitHeight)

  function pick(item) {
    if (!item || !gallery.service) return
    var place = Model.addPlace(gallery.service.bar, gallery.selected, gallery.service.widgetMeta(item.id))
    if (gallery.service.add(item.id, place)) gallery.added(item.id)
  }

  Component.onCompleted: search.forceActiveFocus()
  onItemsChanged: current = Math.max(0, Math.min(current, items.length - 1))

  Column {
    id: header
    width: parent.width
    spacing: Style.space(6)

    Text {
      // Widget names come from other people's plugin manifests, which
      // this plugin only truncates. Rendered literally, not interpreted.
      textFormat: Text.PlainText
      text: "Add a widget"
      color: gallery.ink
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
      text: gallery.selected && gallery.service
        ? "It goes right after " + gallery.service.widgetName(gallery.selected.id) + "."
        : "It goes to its usual side of the bar. Pick a widget on the bar first to put it next to that one."
      color: gallery.faint
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    BoxField {
      id: search
      width: parent.width
      placeholderText: "Search by name, kind or id"
      maximumLength: 80
      foreground: gallery.ink
      accent: gallery.accent
      onTextChanged: gallery.query = text
      onAccepted: gallery.pick(gallery.items[gallery.current])
      keyFilter: function (event) {
        if (event.key === Qt.Key_Down) gallery.current = Math.min(gallery.items.length - 1, gallery.current + 1)
        else if (event.key === Qt.Key_Up) gallery.current = Math.max(0, gallery.current - 1)
        else return
        event.accepted = true
      }
    }
  }

  ListView {
    id: list
    anchors { top: header.bottom; topMargin: Style.space(8); left: parent.left; right: parent.right; bottom: parent.bottom }
    clip: true
    model: gallery.items.length
    currentIndex: gallery.current
    boundsBehavior: Flickable.StopAtBounds
    spacing: Style.space(2)

    delegate: Rectangle {
      id: row
      required property int index
      readonly property var item: gallery.items[index] || null
      readonly property bool current: index === gallery.current

      width: list.width
      height: rowColumn.implicitHeight + Style.space(12)
      radius: Style.cornerRadius
      color: current ? Commons.Color.menu.selectedBackground : "transparent"

      Column {
        id: rowColumn
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.space(8); rightMargin: Style.space(8) }
        spacing: Style.space(2)

        Text {
          // Widget names come from other people's plugin manifests, which
          // this plugin only truncates. Rendered literally, not interpreted.
          textFormat: Text.PlainText
          width: parent.width
          elide: Text.ElideRight
          text: row.item ? row.item.name : ""
          color: row.current ? Commons.Color.menu.selectedText : gallery.ink
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Text {
          // Widget names come from other people's plugin manifests, which
          // this plugin only truncates. Rendered literally, not interpreted.
          textFormat: Text.PlainText
          width: parent.width
          elide: Text.ElideRight
          text: row.item
            ? [row.item.category, row.item.id].filter(function (s) { return !!s }).join(" · ")
              + (gallery.service.stopsPlugin(row.item.id) ? " · turns its whole plugin on" : "")
            : ""
          color: gallery.faint
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Text {
          // Widget names come from other people's plugin manifests, which
          // this plugin only truncates. Rendered literally, not interpreted.
          textFormat: Text.PlainText
          visible: text !== ""
          width: parent.width
          wrapMode: Text.Wrap
          maximumLineCount: 2
          elide: Text.ElideRight
          text: row.item ? row.item.description : ""
          color: gallery.faint
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          gallery.current = row.index
          gallery.pick(row.item)
        }
      }
    }
  }

  Text {
    // Widget names come from other people's plugin manifests, which
    // this plugin only truncates. Rendered literally, not interpreted.
    textFormat: Text.PlainText
    id: empty
    visible: gallery.items.length === 0
    anchors { top: header.bottom; topMargin: Style.space(10); left: parent.left; right: parent.right }
    wrapMode: Text.Wrap
    text: gallery.service && gallery.service.catalogAt === 0 ? "Loading the widget list…"
      : gallery.query ? "No widget matches “" + gallery.query + "”." : "Every widget there is is already on the bar."
    color: gallery.faint
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }
}
