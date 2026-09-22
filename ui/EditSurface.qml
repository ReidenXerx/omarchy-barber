import Quickshell
import QtQuick
import qs.Commons
import qs.Ui
import "."
import "../BarberModel.js" as Model

// Edit mode itself: the real bar, a frame over each widget on it, and the controls around them. Widgets are picked,
// dragged, taken off, added and set up where they are; every change goes through the service, which keeps the undo.
Item {
  id: surface

  property var service: null
  property string panel: ""
  signal finished()

  readonly property var barber: service
  readonly property bool ready: barber !== null && barber.loaded === true
  readonly property var bar: barber ? barber.bar : Model.readBar(null)
  readonly property var chipList: barber ? barber.chips : []
  readonly property string position: bar.position
  readonly property bool vertical: position === "left" || position === "right"
  readonly property int barSize: vertical ? Style.bar.sizeVertical : Style.bar.sizeHorizontal
  readonly property real barLength: vertical ? height : width
  // The shell measures widgets inside the bar's own window; this is where that window starts on the screen.
  readonly property real offsetX: position === "right" ? width - barSize : 0
  readonly property real offsetY: position === "bottom" ? height - barSize : 0

  // The pick is a widget, not a place: which instance of its id it is along the bar.
  property string selectedId: ""
  property int selectedNth: 0
  readonly property var selected: Model.chipOfInstance(chipList, selectedId, selectedNth)
  readonly property string selectedKey: selected ? selected.key : ""
  property string confirmKey: ""
  property var dragging: null
  readonly property var dragChip: dragging ? Model.chipByKey(chipList, dragging.key) : null
  readonly property var dropAt: dragChip ? Model.dropTarget(bar, chipList, dragChip, dragging.point, barLength) : null
  readonly property real markerAlong: dragChip && dropAt ? Model.dropMarker(bar, chipList, dragChip, dropAt, barLength) : 0
  readonly property int hiddenCount: chipList.filter(function (c) { return !c.shown }).length

  readonly property color ink: Color.menu.text
  readonly property color paper: Qt.rgba(Color.menu.background.r, Color.menu.background.g, Color.menu.background.b, 1)
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color faint: Qt.rgba(ink.r, ink.g, ink.b, 0.6)
  readonly property var cardBorder: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property string fontFamily: Style.font.family
  readonly property real gap: Style.space(10)
  readonly property real pad: Style.spacing.popupPadding
  readonly property real lane: Style.spacing.controlHeight + Style.space(16)

  readonly property var glyphs: ({
    close: String.fromCodePoint(0xf0156), cog: String.fromCodePoint(0xf0493), plus: String.fromCodePoint(0xf0415),
    undo: String.fromCodePoint(0xf054c), redo: String.fromCodePoint(0xf044e), layers: String.fromCodePoint(0xf0328),
    check: String.fromCodePoint(0xf012c), edit: String.fromCodePoint(0xf1947),
    dock: String.fromCodePoint(position === "bottom" ? 0xf10a9 : position === "left" ? 0xf10aa : position === "right" ? 0xf10ab : 0xf1513)
  })

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // ---------------------------------------------------------------- actions

  function choose(chip) {
    surface.selectedId = chip ? chip.id : ""
    surface.selectedNth = chip ? Model.chipInstance(surface.chipList, chip) : 0
  }

  function step(delta) {
    surface.confirmKey = ""
    choose(Model.chipByKey(surface.chipList, Model.stepKey(surface.chipList, surface.selectedKey, delta)))
  }

  // A moved widget stays picked by itself: the pick names the widget, and the bar read back shows where it landed.
  function nudge(delta) {
    var chip = surface.selected
    if (!chip || !surface.ready) return
    var target = Model.nudgeTarget(surface.bar, chip, delta)
    if (target) surface.barber.move(chip, target)
  }

  function drop() {
    var chip = surface.dragChip
    var target = surface.dropAt
    if (!chip || !target || !surface.ready) return
    surface.barber.move(chip, target)
  }

  // Taking off a widget whose plugin stops with it asks first.
  function requestRemove(chip) {
    if (!chip || !surface.ready) return
    if (chip.instances <= 1 && surface.barber.stopsPlugin(chip.id) && surface.confirmKey !== chip.key) {
      surface.confirmKey = chip.key
      return
    }
    surface.confirmKey = ""
    // The pick moves on to the widget beside it, so Delete can be pressed again.
    var nextKey = Model.stepKey(surface.chipList, chip.key, 1)
    if (nextKey === chip.key) nextKey = Model.stepKey(surface.chipList, chip.key, -1)
    var next = nextKey !== chip.key ? Model.chipByKey(surface.chipList, nextKey) : null
    if (surface.barber.remove(chip)) choose(next)
  }

  function openSettings(chip) {
    if (!chip || !surface.ready) return
    choose(chip)
    surface.barber.loadManifest(chip.id)
    surface.panel = "settings"
  }

  function togglePanel(name) {
    surface.confirmKey = ""
    surface.panel = surface.panel === name ? "" : name
  }

  focus: true
  Component.onCompleted: forceActiveFocus()
  onPanelChanged: if (panel === "") forceActiveFocus()
  onSelectedChanged: if (!selected && panel === "settings") panel = ""

  Keys.onPressed: function (event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var key = event.key
    event.accepted = true
    if (key === Qt.Key_Escape) {
      if (surface.dragging) surface.dragging = null
      else if (surface.confirmKey) surface.confirmKey = ""
      else if (surface.panel) surface.panel = ""
      else surface.finished()
    } else if (!surface.ready) {
      event.accepted = false
    } else if (ctrl && key === Qt.Key_Z) {
      if (shift) surface.barber.redo()
      else surface.barber.undo()
    } else if (ctrl && key === Qt.Key_Y) {
      surface.barber.redo()
    } else if (key === Qt.Key_Left || key === Qt.Key_Up) {
      if (shift) surface.nudge(-1)
      else surface.step(-1)
    } else if (key === Qt.Key_Right || key === Qt.Key_Down) {
      if (shift) surface.nudge(1)
      else surface.step(1)
    } else if (key === Qt.Key_Tab) {
      surface.step(1)
    } else if (key === Qt.Key_Backtab) {
      surface.step(-1)
    } else if (key === Qt.Key_Delete || key === Qt.Key_Backspace) {
      surface.requestRemove(surface.selected)
    } else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Space) {
      surface.openSettings(surface.selected)
    } else if (key === Qt.Key_A || key === Qt.Key_Plus || key === Qt.Key_Insert) {
      surface.togglePanel("gallery")
    } else if (key === Qt.Key_L) {
      surface.togglePanel("layouts")
    } else if (key === Qt.Key_B) {
      surface.togglePanel("bar")
    } else {
      event.accepted = false
    }
  }

  // ---------------------------------------------------------------- the screen around the bar, dimmed

  Rectangle {
    x: surface.position === "left" ? surface.barSize : 0
    y: surface.position === "top" ? surface.barSize : 0
    width: surface.vertical ? surface.width - surface.barSize : surface.width
    height: surface.vertical ? surface.height : surface.height - surface.barSize
    color: surface.alpha(Color.menu.scrim, Math.min(Color.menu.scrim.a, 0.45))

    MouseArea {
      anchors.fill: parent
      onClicked: {
        if (surface.confirmKey) surface.confirmKey = ""
        else if (surface.panel) surface.panel = ""
        else surface.choose(null)
        surface.forceActiveFocus()
      }
    }
  }

  // ---------------------------------------------------------------- the bar, framed

  Rectangle {
    id: barFrame
    x: surface.offsetX
    y: surface.offsetY
    width: surface.vertical ? surface.barSize : surface.width
    height: surface.vertical ? surface.height : surface.barSize
    color: surface.alpha(surface.accent, 0.07)
    border.width: 1
    border.color: surface.alpha(surface.accent, 0.55)

    MouseArea {
      anchors.fill: parent
      onClicked: {
        surface.choose(null)
        surface.confirmKey = ""
        surface.forceActiveFocus()
      }
    }

    // The thirds of the bar a widget can be dropped into, shown while one is dragged.
    Repeater {
      model: surface.dragging ? ["left", "center", "right"] : []
      delegate: Item {
        required property int index
        required property var modelData
        x: surface.vertical ? 0 : index * barFrame.width / 3
        y: surface.vertical ? index * barFrame.height / 3 : 0
        width: surface.vertical ? barFrame.width : barFrame.width / 3
        height: surface.vertical ? barFrame.height / 3 : barFrame.height

        Rectangle {
          visible: index > 0
          color: surface.alpha(surface.accent, 0.35)
          width: surface.vertical ? parent.width : 1
          height: surface.vertical ? 1 : parent.height
        }

        Text {
          // Widget names come from other people's plugin manifests, which
          // this plugin only truncates. Rendered literally, not interpreted.
          textFormat: Text.PlainText
          anchors.centerIn: parent
          visible: !surface.vertical
          text: modelData
          color: surface.alpha(surface.accent, 0.5)
          font.family: surface.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // ---------------------------------------------------------------- a frame over every widget

  // Counted, not listed: the service reads the bar again after every change and while editing, and a list model would
  // make every frame anew each time, dropping a drag in progress.
  Repeater {
    model: surface.chipList.length
    delegate: Item {
      id: frame
      required property int index
      readonly property var chip: surface.chipList[index] || null
      readonly property bool chosen: chip !== null && chip.key === surface.selectedKey

      visible: chip !== null && chip.shown
      x: chip ? surface.offsetX + chip.x : 0
      y: chip ? surface.offsetY + chip.y : 0
      width: chip ? chip.width : 0
      height: chip ? chip.height : 0
      opacity: surface.dragging && chip && surface.dragging.key === chip.key ? 0.3 : 1

      Rectangle {
        anchors.fill: parent
        anchors.margins: 1
        radius: Math.min(Style.space(4), height / 4)
        color: frame.chosen ? surface.alpha(surface.accent, 0.2) : (pointer.containsMouse ? surface.alpha(surface.ink, 0.1) : "transparent")
        border.width: frame.chosen ? 2 : 1
        border.color: frame.chosen ? surface.accent : surface.alpha(surface.ink, pointer.containsMouse ? 0.65 : 0.25)
      }

      MouseArea {
        id: pointer
        property real pressX: 0
        property real pressY: 0
        property bool moved: false

        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: moved ? Qt.ClosedHandCursor : Qt.OpenHandCursor

        onPressed: function (mouse) {
          pressX = mouse.x
          pressY = mouse.y
          moved = false
          if (!frame.chip) return
          if (surface.selectedKey !== frame.chip.key) surface.confirmKey = ""
          surface.choose(frame.chip)
          surface.forceActiveFocus()
        }
        onPositionChanged: function (mouse) {
          if (!(mouse.buttons & Qt.LeftButton) || !frame.chip || !surface.ready) return
          if (!moved && Math.abs(mouse.x - pressX) + Math.abs(mouse.y - pressY) < Style.space(5)) return
          moved = true
          var p = mapToItem(surface, mouse.x, mouse.y)
          surface.dragging = { key: frame.chip.key, point: { x: p.x - surface.offsetX, y: p.y - surface.offsetY }, sx: p.x, sy: p.y }
        }
        onReleased: {
          if (moved && surface.dragging) surface.drop()
          surface.dragging = null
          moved = false
        }
        onCanceled: {
          surface.dragging = null
          moved = false
        }
        onClicked: function (mouse) {
          if (mouse.button === Qt.RightButton) surface.openSettings(frame.chip)
        }
        onDoubleClicked: surface.openSettings(frame.chip)
      }
    }
  }

  // ---------------------------------------------------------------- where a dragged widget will land

  Rectangle {
    visible: surface.dropAt !== null
    color: surface.accent
    radius: 1
    x: surface.vertical ? surface.offsetX + 2 : surface.offsetX + surface.markerAlong - 1.5
    y: surface.vertical ? surface.offsetY + surface.markerAlong - 1.5 : surface.offsetY + 2
    width: surface.vertical ? surface.barSize - 4 : 3
    height: surface.vertical ? 3 : surface.barSize - 4
  }

  BorderSurface {
    visible: surface.dragChip !== null
    width: ghostLabel.implicitWidth + Style.space(16)
    height: Style.spacing.controlHeight
    radius: Style.cornerRadius
    color: surface.paper
    borderSpec: Border.controlSpec("focus", surface.ink, surface.accent)
    x: surface.dragging ? surface.dragging.sx - width / 2 : 0
    y: surface.dragging ? (surface.position === "bottom" ? surface.dragging.sy - height - Style.space(14)
                                                         : surface.dragging.sy + Style.space(14)) : 0

    Text {
      // Widget names come from other people's plugin manifests, which
      // this plugin only truncates. Rendered literally, not interpreted.
      textFormat: Text.PlainText
      id: ghostLabel
      anchors.centerIn: parent
      text: surface.dragChip ? surface.barber.widgetName(surface.dragChip.id) : ""
      color: surface.ink
      font.family: surface.fontFamily
      font.pixelSize: Style.font.body
    }
  }

  // ---------------------------------------------------------------- beside the widget picked

  BorderSurface {
    id: chipTools
    readonly property var chip: surface.selected
    readonly property bool confirming: chip !== null && surface.confirmKey === chip.key

    visible: surface.ready && chip !== null && surface.dragging === null
    width: toolsColumn.implicitWidth + surface.pad
    height: toolsColumn.implicitHeight + Style.space(10)
    radius: Style.cornerRadius
    color: surface.paper
    borderSpec: surface.cardBorder

    x: {
      if (!chip) return 0
      if (surface.position === "left") return surface.barSize + Style.space(6)
      if (surface.position === "right") return surface.width - surface.barSize - Style.space(6) - width
      return Math.max(surface.gap, Math.min(surface.width - width - surface.gap, surface.offsetX + chip.x + chip.width / 2 - width / 2))
    }
    y: {
      if (!chip) return 0
      if (surface.position === "top") return surface.barSize + Style.space(6)
      if (surface.position === "bottom") return surface.height - surface.barSize - Style.space(6) - height
      return Math.max(surface.gap, Math.min(surface.height - height - surface.gap, surface.offsetY + chip.y + chip.height / 2 - height / 2))
    }

    MouseArea { anchors.fill: parent }

    Column {
      id: toolsColumn
      anchors.centerIn: parent
      spacing: Style.space(6)

      Row {
        spacing: Style.space(4)

        Text {
          // Widget names come from other people's plugin manifests, which
          // this plugin only truncates. Rendered literally, not interpreted.
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          rightPadding: Style.space(6)
          leftPadding: Style.space(4)
          text: chipTools.chip ? surface.barber.widgetName(chipTools.chip.id) + (chipTools.chip.shown ? "" : "  (not showing now)") : ""
          color: surface.ink
          font.family: surface.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Button {
          iconText: surface.glyphs.cog
          text: "Settings"
          foreground: surface.ink
          accent: surface.accent
          selected: surface.panel === "settings"
          onClicked: surface.panel === "settings" ? surface.panel = "" : surface.openSettings(chipTools.chip)
        }

        Button {
          iconText: surface.glyphs.close
          text: chipTools.confirming ? "Take it off" : "Remove"
          foreground: chipTools.confirming ? surface.urgent : surface.ink
          accent: surface.accent
          opacity: chipTools.chip && chipTools.chip.instances > 1 ? 0.45 : 1
          tooltipText: chipTools.chip && chipTools.chip.instances > 1 ? "On the bar more than once: the shell can only take them off together" : "Delete"
          onClicked: surface.requestRemove(chipTools.chip)
        }

        Button {
          anchors.verticalCenter: parent.verticalCenter
          visible: chipTools.confirming
          text: "Keep it"
          foreground: surface.ink
          accent: surface.accent
          onClicked: surface.confirmKey = ""
        }
      }

      Text {
        // Widget names come from other people's plugin manifests, which
        // this plugin only truncates. Rendered literally, not interpreted.
        textFormat: Text.PlainText
        visible: chipTools.confirming
        width: parent.width
        wrapMode: Text.Wrap
        text: chipTools.chip ? "Taking " + surface.barber.widgetName(chipTools.chip.id) + " off the bar turns its whole plugin off, service and panels too. Undo puts it back." : ""
        color: surface.urgent
        font.family: surface.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // ---------------------------------------------------------------- the toolbar

  BorderSurface {
    id: toolbar
    width: toolbarColumn.implicitWidth + surface.pad * 2
    height: toolbarColumn.implicitHeight + surface.pad
    radius: Style.cornerRadius
    color: surface.paper
    borderSpec: surface.cardBorder
    x: Math.round((surface.width - width) / 2)
    y: surface.position === "top" ? surface.barSize + surface.lane + surface.gap
      : surface.position === "bottom" ? surface.height - surface.barSize - surface.lane - surface.gap - height
      : surface.gap * 3

    MouseArea { anchors.fill: parent }

    Column {
      id: toolbarColumn
      anchors.centerIn: parent
      spacing: Style.space(6)

      Row {
        id: toolbarRow
        spacing: Style.space(4)

        Text {
          // Widget names come from other people's plugin manifests, which
          // this plugin only truncates. Rendered literally, not interpreted.
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          rightPadding: Style.space(10)
          text: surface.glyphs.edit + "  Barber"
          color: surface.accent
          font.family: surface.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Button {
          iconText: surface.glyphs.plus
          text: "Add"
          foreground: surface.ink
          accent: surface.accent
          selected: surface.panel === "gallery"
          tooltipText: "Add a widget (A)"
          onClicked: surface.togglePanel("gallery")
        }

        Button {
          iconText: surface.glyphs.undo
          foreground: surface.ink
          accent: surface.accent
          opacity: surface.ready && surface.barber.canUndo ? 1 : 0.4
          tooltipText: "Undo (Ctrl+Z)"
          onClicked: if (surface.ready) surface.barber.undo()
        }

        Button {
          iconText: surface.glyphs.redo
          foreground: surface.ink
          accent: surface.accent
          opacity: surface.ready && surface.barber.canRedo ? 1 : 0.4
          tooltipText: "Redo (Ctrl+Shift+Z)"
          onClicked: if (surface.ready) surface.barber.redo()
        }

        Button {
          iconText: surface.glyphs.layers
          text: "Layouts"
          foreground: surface.ink
          accent: surface.accent
          selected: surface.panel === "layouts"
          tooltipText: "Saved layouts and when they switch (L)"
          onClicked: surface.togglePanel("layouts")
        }

        Button {
          iconText: surface.glyphs.dock
          text: "Bar"
          foreground: surface.ink
          accent: surface.accent
          selected: surface.panel === "bar"
          tooltipText: "Position, transparency, shortcut (B)"
          onClicked: surface.togglePanel("bar")
        }

        Button {
          iconText: surface.glyphs.check
          text: "Done"
          foreground: surface.ink
          accent: surface.accent
          bordered: true
          tooltipText: "Esc"
          onClicked: surface.finished()
        }
      }

      Text {
        // Widget names come from other people's plugin manifests, which
        // this plugin only truncates. Rendered literally, not interpreted.
        textFormat: Text.PlainText
        width: toolbarRow.implicitWidth
        wrapMode: Text.Wrap
        horizontalAlignment: Text.AlignHCenter
        text: {
          if (!surface.barber) return "Barber's service is not running. Turn the plugin off and on again, or restart the shell."
          if (!surface.barber.loaded) return "Reading the bar…"
          if (surface.barber.busy) return "Working…"
          if (surface.barber.status) return surface.barber.status
          var hint = "Click a widget to pick it · drag to move · Shift+arrows nudge · Delete takes it off · Esc when done"
          return surface.hiddenCount > 0 ? hint + " · " + surface.hiddenCount + " on the bar but not showing: reach them with Tab" : hint
        }
        color: surface.barber && surface.barber.statusIsError && !surface.barber.busy ? surface.urgent : surface.faint
        font.family: surface.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // ---------------------------------------------------------------- the card: gallery, settings, layouts, the bar

  BorderSurface {
    id: card
    readonly property real room: surface.position === "bottom"
      ? toolbar.y - surface.gap * 2
      : surface.height - (toolbar.y + toolbar.height + surface.gap) - surface.gap

    visible: surface.ready && surface.panel !== "" && cardLoader.item !== null
    width: Math.min(Style.space(500), surface.width - surface.gap * 2)
    height: Math.max(0, Math.min(room, cardLoader.item ? cardLoader.item.implicitHeight + surface.pad * 2 : 0))
    x: Math.round((surface.width - width) / 2)
    y: surface.position === "bottom" ? toolbar.y - surface.gap - height : toolbar.y + toolbar.height + surface.gap
    radius: Style.cornerRadius
    color: surface.paper
    borderSpec: surface.cardBorder

    MouseArea { anchors.fill: parent }

    Loader {
      id: cardLoader
      anchors.fill: parent
      anchors.margins: surface.pad
      active: surface.ready
      sourceComponent: surface.panel === "gallery" ? galleryCard
        : surface.panel === "settings" ? settingsCard
        : surface.panel === "layouts" ? layoutsCard
        : surface.panel === "bar" ? barCard : null
    }
  }

  Component {
    id: galleryCard
    WidgetGallery {
      service: surface.barber
      selected: surface.selected
      onAdded: function (id) {
        surface.selectedId = id
        surface.selectedNth = 0
        surface.panel = ""
      }
    }
  }

  Component {
    id: settingsCard
    WidgetSettings {
      service: surface.barber
      chip: surface.selected
      vertical: surface.vertical
    }
  }

  Component {
    id: layoutsCard
    LayoutsCard { service: surface.barber }
  }

  Component {
    id: barCard
    BarCard { service: surface.barber }
  }
}
