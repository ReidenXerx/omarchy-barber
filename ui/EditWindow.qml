import Quickshell
import Quickshell.Wayland
import QtQuick
import "."

// The layer edit mode draws on: the whole screen the first bar is on, above the bar, with the keyboard.
PanelWindow {
  id: editWindow

  property var service: null
  property string panel: ""

  screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "omarchy-barber"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

  EditSurface {
    anchors.fill: parent
    service: editWindow.service
    panel: editWindow.panel
    onPanelChanged: editWindow.panel = panel
    onFinished: if (editWindow.service) editWindow.service.finishEditing()
  }
}
