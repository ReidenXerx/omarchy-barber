import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Services.UPower
import QtQuick
import "BarberModel.js" as Model

// Barber's service: the bar as the shell holds it, the changes made to it and their undo, the saved layouts and the
// rules that put them on by themselves, and the shortcut that opens edit mode.
//
// Everything that changes the bar goes through the shell's own IPC (`omarchy-shell shell ...`) or `omarchy-bar`, by
// absolute path, one process at a time, each with a deadline; shell.json is never edited behind the shell's back.
// Barber's own settings go through the shell's scoped API into Barber's entry in shell.json.
Item {
  id: barber
  visible: false

  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  readonly property string pluginId: "reidenxerx.barber"
  readonly property var tools: ({ shell: "/usr/bin/omarchy-shell", bar: "/usr/bin/omarchy-bar" })
  readonly property string hyprctl: "/usr/bin/hyprctl"
  readonly property string catalogTool: "/usr/bin/omarchy-plugin-catalog"
  readonly property string headTool: "/usr/bin/head"
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string toggleCommand: "/usr/bin/omarchy-shell shell toggle reidenxerx.barber '{}'"
  readonly property int killGraceMs: 1500

  // ---------------------------------------------------------------- what Barber knows

  property bool loaded: false
  property var bar: Model.readBar(null)
  property var settings: Model.readSettings(null)
  property bool hasEntry: false
  property var plugins: []
  property var catalog: ({})
  property real catalogAt: 0
  property var manifests: ({})
  property var manifestAsked: ({})
  property int metaRevision: 0
  property var geometry: []
  readonly property var chips: Model.chips(geometry, bar)

  property var history: Model.emptyHistory()
  property string historySignature: ""
  readonly property bool canUndo: history.done.length > 0
  readonly property bool canRedo: history.undone.length > 0

  property bool busy: false
  property bool editing: false
  property bool pendingAuto: false
  property string appliedLayout: ""
  property string status: ""
  property bool statusIsError: false
  property int statusSerial: 0
  property string shortcutState: ""
  property string boundCombo: ""

  // ---------------------------------------------------------------- the moment, as the rules see it

  readonly property var screenNames: {
    var out = []
    var list = Quickshell.screens
    for (var i = 0; i < list.length; i++) out.push(String(list[i].name || ""))
    return out
  }
  readonly property var focused: ToplevelManager.activeToplevel
  readonly property var context: ({
    onBattery: UPower.onBattery === true,
    externalScreen: Model.hasExternalScreen(barber.screenNames),
    fullscreen: (barber.focused !== null && barber.focused.fullscreen === true)
      || (Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.hasFullscreen === true),
    appClass: barber.focused ? String(barber.focused.appId || "") : "",
    appTitle: barber.focused ? String(barber.focused.title || "") : ""
  })
  readonly property string wantedLayout: loaded && settings.auto ? Model.chooseLayout(settings, context) : ""
  readonly property string shortcut: settings.shortcut

  onWantedLayoutChanged: autoTimer.restart()
  onShortcutChanged: if (loaded) shortcutTimer.restart()

  function say(message, isError) {
    barber.status = String(message || "")
    barber.statusIsError = isError === true
    barber.statusSerial++
  }

  // ---------------------------------------------------------------- one process at a time, each with a deadline

  property var queue: []
  property var job: null

  function enqueue(argv, deadlineMs, done) {
    if (!argv || argv.length === 0) {
      done(-1, "", "", false)
      return
    }
    var next = barber.queue.slice()
    next.push({ argv: argv, deadline: deadlineMs, done: done, timedOut: false })
    barber.queue = next
    Qt.callLater(barber.pump)
  }

  function pump() {
    if (barber.job || runner.running || barber.queue.length === 0) return
    var next = barber.queue.slice()
    barber.job = next.shift()
    barber.queue = next
    runner.outDone = false
    runner.exited = false
    runner.code = -1
    runner.command = barber.job.argv
    runner.running = true
    deadline.interval = barber.job.deadline
    deadline.restart()
  }

  // A job is over when its process has exited and its output has been read, or when it had to be given up on.
  function settle(force) {
    var current = barber.job
    if (!current) return
    if (!runner.exited && !force) return
    if (!runner.outDone && !force) {
      settleGrace.restart()
      return
    }
    deadline.stop()
    settleGrace.stop()
    barber.job = null
    var out = current.timedOut ? "" : String(runnerOut.text || "")
    var err = current.timedOut ? "" : String(runnerErr.text || "")
    try {
      current.done(runner.exited ? runner.code : -1, out, err, current.timedOut)
    } catch (e) {
      console.warn("Barber: " + e)
    }
    Qt.callLater(barber.pump)
  }

  Process {
    id: runner
    property bool outDone: false
    property bool exited: false
    property int code: -1
    stdout: StdioCollector {
      id: runnerOut
      onStreamFinished: {
        runner.outDone = true
        barber.settle(false)
      }
    }
    stderr: StdioCollector { id: runnerErr }
    onExited: function (exitCode, exitStatus) {
      runner.code = exitCode
      runner.exited = true
      barber.settle(false)
    }
  }

  // Past its deadline a process is asked to stop, then killed; one that never started is given up on at once.
  Timer {
    id: deadline
    onTriggered: {
      if (!barber.job) return
      barber.job.timedOut = true
      if (runner.running) {
        runner.signal(15)
        killTimer.restart()
      } else {
        barber.settle(true)
      }
    }
  }

  Timer {
    id: killTimer
    interval: barber.killGraceMs
    onTriggered: if (runner.running) runner.signal(9)
  }

  Timer {
    id: settleGrace
    interval: 400
    onTriggered: barber.settle(true)
  }

  // Nothing Barber does takes a minute; if a change is still marked as running by then, something was lost on the
  // way, and edit mode should not stay locked because of it.
  Timer {
    interval: 60000
    running: barber.busy
    onTriggered: {
      barber.busy = false
      barber.say("The last change took too long to finish. Check the bar before going on.", true)
    }
  }

  // ---------------------------------------------------------------- reading the bar back

  // Which bar the running shell has, from the layout Omarchy ships: one with centerBegin is the center-box bar, even
  // when this user's shell.json has not been given those keys yet.
  property bool splitShell: false

  FileView {
    path: "/usr/share/omarchy/config/omarchy/shell.json"
    printErrors: false
    onLoaded: {
      var raw = text()
      if (raw.length > 1024 * 1024) return
      var parsed = Model.parseOutput(raw)
      var layout = parsed && parsed.bar && parsed.bar.layout ? parsed.bar.layout : null
      barber.splitShell = layout !== null && typeof layout === "object" && Object.prototype.hasOwnProperty.call(layout, "centerBegin")
      if (barber.loaded) barber.refreshConfig(null)
    }
  }

  function refreshConfig(then) {
    enqueue(Model.argv(Model.call("listShellConfig"), barber.tools), 5000, function (code, out) {
      var parsed = code === 0 ? Model.parseOutput(out) : null
      var ok = parsed !== null && typeof parsed === "object" && !(parsed instanceof Array)
      if (ok) {
        var entry = Model.ownEntry(parsed, barber.pluginId)
        barber.bar = Model.readBar(parsed, barber.splitShell)
        barber.settings = Model.readSettings(entry)
        barber.hasEntry = entry !== null
        barber.loaded = true
      }
      if (then) then(ok)
    })
  }

  function refreshPlugins(then) {
    enqueue(Model.argv(Model.call("listPlugins"), barber.tools), 5000, function (code, out) {
      var parsed = code === 0 ? Model.parseOutput(out) : null
      var ok = parsed instanceof Array
      if (ok) barber.plugins = parsed
      if (then) then(ok)
    })
  }

  function refreshGeometry() {
    enqueue(Model.argv(Model.call("debugBarGeometry"), barber.tools), 4000, function (code, out) {
      var parsed = code === 0 ? Model.parseOutput(out) : null
      // Most readings while editing find nothing moved; leaving the value alone then keeps edit mode still.
      if (parsed instanceof Array && JSON.stringify(parsed) !== JSON.stringify(barber.geometry)) barber.geometry = parsed
    })
  }

  function refreshCatalog() {
    enqueue([barber.catalogTool], 20000, function (code, out) {
      var parsed = code === 0 ? Model.parseOutput(out) : null
      if (parsed instanceof Array) {
        barber.catalog = Model.catalogIndex(parsed)
        barber.catalogAt = Date.now()
        barber.metaRevision++
      }
    })
  }

  // The bar lays itself out again after a change, and some widgets animate their width, so it is measured twice.
  Timer {
    id: geometrySoon
    interval: 300
    onTriggered: barber.refreshGeometry()
  }

  Timer {
    id: geometryLater
    interval: 1000
    onTriggered: barber.refreshGeometry()
  }

  // While editing, widgets that change size on their own (a clock, a title) are followed.
  Timer {
    interval: 1500
    repeat: true
    running: barber.editing
    onTriggered: if (!barber.busy && !barber.job && barber.queue.length === 0) barber.refreshGeometry()
  }

  function afterCalls(then) {
    refreshConfig(function () {
      refreshPlugins(function () {
        try {
          then()
        } finally {
          geometrySoon.restart()
          geometryLater.restart()
        }
      })
    })
  }

  function setEditing(on) {
    if (barber.editing === on) return
    barber.editing = on
    if (on) {
      barber.say("", false)
      refreshConfig(null)
      refreshPlugins(null)
      refreshGeometry()
      if (Date.now() - barber.catalogAt > 60000) refreshCatalog()
    } else if (barber.pendingAuto) {
      barber.pendingAuto = false
      autoTimer.restart()
    }
  }

  // ---------------------------------------------------------------- edit mode's window

  // Held by the service, not the overlay: the shell makes every overlay anew whenever the bar changes, and a window the
  // overlay held would close after each edit. Services are kept across those rebuilds.
  Loader { id: editorLoader }

  function openEditor(panel) {
    var p = String(panel || "")
    setEditing(true)
    if (editorLoader.item) {
      if (p) editorLoader.item.panel = p
      return
    }
    editorLoader.setSource(Qt.resolvedUrl("ui/EditWindow.qml"), { service: barber, panel: p })
  }

  function closeEditor() {
    editorLoader.source = ""
    setEditing(false)
  }

  // Done or Esc in edit mode: close it, and tell the shell it is closed.
  function finishEditing() {
    closeEditor()
    if (barber.shell && typeof barber.shell.hide === "function") barber.shell.hide(barber.pluginId)
  }

  // ---------------------------------------------------------------- changes, and their undo

  // Runs calls one after another and stops at the first the shell refuses.
  function runCalls(calls, done) {
    var list = calls ? Array.prototype.slice.call(calls) : []
    var ran = 0
    function next() {
      if (list.length === 0) {
        done(true, ran, "")
        return
      }
      var c = list.shift()
      enqueue(Model.argv(c, barber.tools), c.tool === "bar" ? 10000 : 5000, function (code, out, err, timedOut) {
        if (!Model.callSucceeded(c, code, out)) {
          var said = String(out || err || "").trim().split(String.fromCharCode(10))[0].slice(0, 160)
          done(false, ran, timedOut ? "The shell did not answer in time." : (said ? "The shell said: " + said : "The shell refused the change."))
          return
        }
        ran++
        next()
      })
    }
    next()
  }

  // A stored undo names places on the bar as Barber left it; if the bar has been changed since by anything else,
  // those places may hold other widgets now, so the history goes.
  function historyStillValid() {
    if (barber.history.done.length === 0 && barber.history.undone.length === 0) return true
    if (Model.barSignature(barber.bar) === barber.historySignature) return true
    barber.history = Model.emptyHistory()
    return false
  }

  function applyChange(ch, message) {
    if (!ch) return false
    if (barber.busy) {
      say("Wait for the last change to finish.", true)
      return false
    }
    barber.busy = true
    historyStillValid()
    runCalls(ch.run, function (done, ran, error) {
      afterCalls(function () {
        barber.busy = false
        if (done) {
          barber.history = Model.record(barber.history, ch)
          barber.historySignature = Model.barSignature(barber.bar)
          say(message, false)
        } else {
          if (ran > 0) barber.history = Model.emptyHistory()
          say(error, true)
        }
      })
    })
    return true
  }

  function stepHistory(forward) {
    if (barber.busy) return
    var step = forward ? Model.redoStep(barber.history) : Model.undoStep(barber.history)
    if (!step) {
      say(forward ? "Nothing to redo." : "Nothing to undo.", false)
      return
    }
    barber.busy = true
    refreshConfig(function (ok) {
      if (!ok || !historyStillValid()) {
        barber.busy = false
        say(ok ? "The bar was changed outside Barber, so there is nothing safe to undo." : "Could not read the bar from the shell.", true)
        return
      }
      runCalls(step.calls, function (done, ran, error) {
        afterCalls(function () {
          barber.busy = false
          if (done) {
            barber.history = step.history
            barber.historySignature = Model.barSignature(barber.bar)
            say((forward ? "Redone: " : "Undone: ") + step.change.label.toLowerCase(), false)
          } else {
            barber.history = Model.emptyHistory()
            say(error, true)
          }
        })
      })
    })
  }

  function undo() { stepHistory(false) }
  function redo() { stepHistory(true) }

  function widgetName(id) {
    var rev = barber.metaRevision
    return Model.widgetName(barber.catalog, id)
  }

  function stopsPlugin(id) {
    return Model.stopsPlugin(Model.pluginById(barber.plugins, id))
  }

  function remove(chip) {
    if (!chip) return false
    if (chip.instances > 1) {
      say(widgetName(chip.id) + " is on the bar more than once, and the shell can only take all of them off together.", true)
      return false
    }
    return applyChange(Model.removeChange(chip), "Took " + widgetName(chip.id) + " off the bar.")
  }

  function add(id, place) {
    if (!place) return false
    return applyChange(Model.addChange(barber.bar, id, place.section, place.index), "Added " + widgetName(id) + ".")
  }

  function move(chip, target) {
    var ch = chip ? Model.moveChange(barber.bar, chip, target) : null
    return ch ? applyChange(ch, "Moved " + widgetName(chip.id) + ".") : false
  }

  function setOption(chip, field, value) {
    var ch = chip && field ? Model.optionChange(chip, field.key, value, field.fallback) : null
    return ch ? applyChange(ch, widgetName(chip.id) + ": " + field.label + " changed.") : false
  }

  function setPosition(position) {
    var ch = Model.positionChange(barber.bar, position)
    return ch ? applyChange(ch, "The bar sits on the " + position + " now.") : false
  }

  function toggleTransparency() {
    return applyChange(Model.transparencyChange(), barber.bar.transparent ? "The bar is solid again." : "The bar is see-through now.")
  }

  // ---------------------------------------------------------------- what a widget's settings form is built from

  function widgetMeta(id) {
    var rev = barber.metaRevision
    var out = {}
    var base = Model.widgetMeta(barber.catalog, id)
    for (var k in base) out[k] = base[k]
    var read = barber.manifests[id]
    if (read) for (var r in read) if (read[r] !== "" && read[r] !== undefined) out[r] = read[r]
    return out
  }

  // The catalog leaves schemas out, so a widget's manifest is read when its settings are opened: only from a plugin
  // folder, and never more of it than a manifest could need.
  function loadManifest(id) {
    if (barber.manifestAsked[id]) return
    var entry = barber.catalog[id]
    var path = entry ? String(entry.manifestPath || "") : ""
    if (!Model.manifestPathAllowed(path, barber.home)) return
    var asked = Object.assign({}, barber.manifestAsked)
    asked[id] = true
    barber.manifestAsked = asked
    enqueue([barber.headTool, "-c", String(Model.MANIFEST_MAX + 1), "--", path], 3000, function (code, out) {
      var parsed = code === 0 && out.length <= Model.MANIFEST_MAX ? Model.parseOutput(out) : null
      var next = Object.assign({}, barber.manifests)
      next[id] = Model.readWidgetManifest(parsed)
      barber.manifests = next
      barber.metaRevision++
    })
  }

  // ---------------------------------------------------------------- layouts

  function installedWidget(id) { return Model.widgetInstalled(barber.plugins, id) }
  function mustStay(id) { return Model.stopsPlugin(Model.pluginById(barber.plugins, id)) }

  function writeSettings(next, message) {
    var payload = Model.settingsPayload(next)
    barber.settings = Model.readSettings(payload)
    if (!barber.shell || typeof barber.shell.updateEntryInline !== "function" || !barber.hasEntry) {
      say("Barber could not save its settings: it has no entry in shell.json's plugin list.", true)
      return false
    }
    barber.shell.updateEntryInline(barber.pluginId, payload)
    if (message) say(message, false)
    return true
  }

  function saveLayout(name) {
    var n = String(name || "").trim().slice(0, Model.NAME_MAX)
    if (!n) {
      say("Give the layout a name first.", true)
      return
    }
    if (barber.busy) {
      say("Wait for the last change to finish.", true)
      return
    }
    refreshConfig(function (ok) {
      if (!ok) {
        say("Could not read the bar from the shell.", true)
        return
      }
      var existed = Model.layoutByName(barber.settings, n) !== null
      if (!existed && barber.settings.layouts.length >= Model.LAYOUTS_MAX) {
        say("Barber keeps " + Model.LAYOUTS_MAX + " layouts at most. Delete one first.", true)
        return
      }
      if (writeSettings(Model.withLayout(barber.settings, Model.snapshot(barber.bar, n)), (existed ? "Updated " : "Saved ") + n + "."))
        barber.appliedLayout = n
    })
  }

  function deleteLayout(name) {
    writeSettings(Model.withoutLayout(barber.settings, name), "Deleted " + name + ".")
    if (barber.appliedLayout === name) barber.appliedLayout = ""
  }

  // Puts a layout on the bar. Worn by hand it can be undone; put on by a rule it clears the history instead, since the
  // undo stored before it would now name the wrong places.
  function wearLayout(name, byRule) {
    var layout = Model.layoutByName(barber.settings, name)
    if (!layout) return
    if (barber.busy) {
      if (byRule) autoTimer.restart()
      else say("Wait for the last change to finish.", true)
      return
    }
    barber.busy = true
    refreshConfig(function (configOk) {
      refreshPlugins(function (pluginsOk) {
        if (!configOk || !pluginsOk || barber.plugins.length === 0) {
          barber.busy = false
          if (!byRule) say("Could not read the bar from the shell.", true)
          return
        }
        historyStillValid()
        var before = Model.snapshot(barber.bar, "")
        var calls = Model.planLayout(barber.bar, layout, barber.installedWidget, barber.mustStay)
        if (calls.length === 0) {
          barber.busy = false
          barber.appliedLayout = name
          if (!byRule) say(name + " is already on the bar.", false)
          return
        }
        runCalls(calls, function (done, ran, error) {
          afterCalls(function () {
            barber.busy = false
            if (!done) {
              barber.history = Model.emptyHistory()
              say(error, true)
              return
            }
            barber.appliedLayout = name
            if (byRule) {
              barber.history = Model.emptyHistory()
              return
            }
            var back = Model.planLayout(barber.bar, before, barber.installedWidget, barber.mustStay)
            barber.history = Model.record(barber.history, Model.change("Layout", calls, back))
            barber.historySignature = Model.barSignature(barber.bar)
            say("Put " + name + " on the bar.", false)
          })
        })
      })
    })
  }

  // ---------------------------------------------------------------- rules

  Timer {
    id: autoTimer
    interval: 800
    onTriggered: barber.applyRules()
  }

  function applyRules() {
    if (!barber.loaded || !barber.settings.auto) return
    if (barber.editing) {
      barber.pendingAuto = true
      return
    }
    var name = barber.wantedLayout
    if (name && Model.layoutByName(barber.settings, name)) wearLayout(name, true)
  }

  function setAuto(on) {
    writeSettings(Object.assign({}, barber.settings, { auto: on === true }),
                  on ? "The bar now changes layouts by itself." : "Layouts no longer change by themselves.")
    autoTimer.restart()
  }

  function setBaseLayout(name) {
    writeSettings(Object.assign({}, barber.settings, { baseLayout: String(name || "") }), "")
    autoTimer.restart()
  }

  function addRule(rule) {
    var next = Model.withRule(barber.settings, rule)
    if (next.rules.length === barber.settings.rules.length) {
      say("A rule needs a saved layout and at least one condition.", true)
      return false
    }
    writeSettings(next, "Added the rule.")
    autoTimer.restart()
    return true
  }

  function removeRule(index) {
    writeSettings(Model.withoutRule(barber.settings, index), "Removed the rule.")
    autoTimer.restart()
  }

  function setRuleEnabled(index, on) {
    writeSettings(Model.withRuleEnabled(barber.settings, index, on), "")
    autoTimer.restart()
  }

  // ---------------------------------------------------------------- the shortcut

  property bool shortcutBusy: false
  property bool shortcutAgain: false

  function setShortcut(combo) {
    writeSettings(Object.assign({}, barber.settings, { shortcut: String(combo || "") }),
                  combo ? "Edit mode opens with " + combo + "." : "Edit mode has no shortcut now.")
  }

  Timer {
    id: shortcutTimer
    interval: 500
    onTriggered: barber.syncShortcut()
  }

  // Binds the shortcut when its keys are free, takes back a combination Barber bound before and no longer uses, and
  // leaves keys that something else holds alone (edit mode then says so).
  function syncShortcut() {
    if (barber.shortcutBusy) {
      barber.shortcutAgain = true
      return
    }
    barber.shortcutBusy = true
    enqueue([barber.hyprctl, "binds", "-j"], 3000, function (code, out) {
      var binds = code === 0 ? Model.parseOutput(out) : null
      if (!(binds instanceof Array)) {
        finishShortcut("unknown", "")
        return
      }
      var want = barber.settings.shortcut
      if (barber.boundCombo && barber.boundCombo !== want && Model.bindState(binds, barber.boundCombo) === "ours")
        enqueue([barber.hyprctl, "eval", Model.unbindStatement(barber.boundCombo)], 3000, function () {})
      var state = Model.bindState(binds, want)
      if (state !== "free") {
        finishShortcut(state, state === "ours" ? want : "")
        return
      }
      enqueue([barber.hyprctl, "eval", Model.bindStatement(want, barber.toggleCommand)], 3000, function (evalCode, evalOut) {
        var ok = evalCode === 0 && String(evalOut || "").toLowerCase().indexOf("error") < 0
        finishShortcut(ok ? "ours" : "failed", ok ? want : "")
      })
    })
  }

  function finishShortcut(state, combo) {
    barber.shortcutState = state
    barber.boundCombo = combo
    barber.shortcutBusy = false
    if (barber.shortcutAgain) {
      barber.shortcutAgain = false
      shortcutTimer.restart()
    }
  }

  // Runtime binds are gone after Hyprland reloads its config.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event && event.name === "configreloaded") shortcutTimer.restart()
    }
  }

  // ---------------------------------------------------------------- start and stop

  // The shell may still be starting when this service is made, so the first reading is retried until it answers.
  Timer {
    id: startTimer
    interval: 3000
    repeat: true
    running: true
    triggeredOnStart: true
    property int tries: 0
    onTriggered: {
      if (barber.loaded || tries >= 20) {
        stop()
        return
      }
      tries++
      if (barber.job || barber.queue.length > 0) return
      barber.refreshConfig(function (ok) {
        if (!ok) return
        barber.refreshPlugins(null)
        shortcutTimer.restart()
        autoTimer.restart()
      })
    }
  }

  Component.onDestruction: {
    if (barber.shortcutState === "ours" && barber.boundCombo)
      Quickshell.execDetached(["/usr/bin/timeout", "3", barber.hyprctl, "eval", Model.unbindStatement(barber.boundCombo)])
  }
}
