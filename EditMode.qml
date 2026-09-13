import Quickshell
import QtQuick

// Edit mode as the shell opens it (`omarchy-shell shell toggle reidenxerx.barber`, the shortcut, or the menu). The
// window itself belongs to the service: the shell makes this item anew whenever the bar changes, so it only passes
// open and close along, and reports edit mode as open for as long as the service has it open.
Item {
  id: overlay

  property var shell: null
  property var manifest: null
  property var service: null
  property string omarchyPath: ""
  property bool opened: overlay.service ? overlay.service.editing === true : false

  readonly property string pluginId: "reidenxerx.barber"
  readonly property var panels: ["layouts", "gallery", "bar"]

  function barber() {
    if (!overlay.service && overlay.shell && typeof overlay.shell.serviceFor === "function")
      overlay.service = overlay.shell.serviceFor(overlay.pluginId)
    if (!overlay.service) console.warn("Barber: the service is not running, so edit mode cannot open")
    return overlay.service
  }

  // The payload may name a card to open with: {"panel": "layouts"}.
  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) { payload = {} }
    var panel = overlay.panels.indexOf(String(payload.panel || "")) >= 0 ? String(payload.panel) : ""
    var service = overlay.barber()
    if (service) service.openEditor(panel)
  }

  function close() {
    var service = overlay.barber()
    if (service) service.closeEditor()
  }

  function toggle() {
    var service = overlay.barber()
    if (!service) return
    if (service.editing) service.finishEditing()
    else service.openEditor("")
  }

  // ---------------------------------------------------------------- for scripts and key bindings

  // `omarchy-shell shell call reidenxerx.barber <verb> <argument>`, answered in words:
  //   layouts            the saved layouts' names, as JSON
  //   save <name>        save the bar as it is now under that name
  //   wear <name>        put that layout on the bar
  //   forget <name>      delete that layout
  //   auto on|off|toggle whether layouts switch by themselves

  function ready() {
    var service = overlay.barber()
    return service && service.loaded ? service : null
  }

  function layoutNamed(service, name) {
    var list = service.settings.layouts
    for (var i = 0; i < list.length; i++) if (list[i].name === String(name || "")) return list[i]
    return null
  }

  function layouts() {
    var service = overlay.ready()
    if (!service) return "not ready"
    return JSON.stringify(service.settings.layouts.map(function (l) { return l.name }))
  }

  function save(name) {
    var service = overlay.ready()
    if (!service) return "not ready"
    if (!String(name || "").trim()) return "a layout needs a name"
    service.saveLayout(String(name))
    return "ok"
  }

  function wear(name) {
    var service = overlay.ready()
    if (!service) return "not ready"
    if (!overlay.layoutNamed(service, name)) return "no layout named " + String(name || "")
    service.wearLayout(String(name), false)
    return "ok"
  }

  function forget(name) {
    var service = overlay.ready()
    if (!service) return "not ready"
    if (!overlay.layoutNamed(service, name)) return "no layout named " + String(name || "")
    service.deleteLayout(String(name))
    return "ok"
  }

  function auto(state) {
    var service = overlay.ready()
    if (!service) return "not ready"
    var s = String(state || "toggle")
    var on = s === "on" ? true : s === "off" ? false : !service.settings.auto
    service.setAuto(on)
    return on ? "on" : "off"
  }
}
