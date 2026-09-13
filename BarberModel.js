// BarberModel.js -- what Barber decides, with no Qt in it, so node can test it.
//
// The bar as the shell reports it (shell.json's `bar` and the live geometry of its widgets), the calls that change it,
// each paired with the calls that take it back, the plan that turns the bar into a saved layout, and the rules that
// pick a layout for the moment. Everything read from shell.json or the shell's IPC is untrusted: shapes are checked
// and sizes are bounded before anything is built from them.

var SECTIONS = ["left", "center", "right"]
var POSITIONS = ["top", "bottom", "left", "right"]
var ENTRIES_MAX = 64          // widgets in one section
var OPTIONS_MAX = 32          // options on one widget
var FIELDS_MAX = 40           // fields in one widget's settings form
var CHOICES_MAX = 64
var LAYOUTS_MAX = 24
var RULES_MAX = 32
var UNDO_MAX = 100
var NAME_MAX = 40
var TEXT_MAX = 240
var MANIFEST_MAX = 256 * 1024 // a widget's manifest.json
var OUTPUT_MAX = 4 * 1024 * 1024 // anything the shell, the catalog or Hyprland prints
var ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/
var COMBO_RE = /^(SUPER|ALT|CTRL|SHIFT)( \+ (SUPER|ALT|CTRL|SHIFT))* \+ [A-Z0-9]$/

var NL = String.fromCharCode(10)
var QUOTE = String.fromCharCode(34)
var BACKSLASH = String.fromCharCode(92)

function isList(v) { return Array.isArray(v) || v instanceof Array }
function isObject(v) { return v !== null && typeof v === "object" && !isList(v) }
function toList(v) { return isList(v) ? Array.prototype.slice.call(v) : [] }
function copy(v) { return v === undefined ? undefined : JSON.parse(JSON.stringify(v)) }
function same(a, b) { return JSON.stringify(a) === JSON.stringify(b) }
function num(v) { var n = Number(v); return isFinite(n) ? n : 0 }
function text(v, max) { return typeof v === "string" ? v.slice(0, max || TEXT_MAX) : "" }
function validId(id) { return typeof id === "string" && ID_RE.test(id) }
function json(v) { return JSON.stringify(v === undefined ? null : v) }
function has(object, key) { return isObject(object) && Object.prototype.hasOwnProperty.call(object, key) }

// Parsed JSON from a tool's output, or null when it is too big or not JSON.
function parseOutput(raw) {
  if (typeof raw !== "string" || raw.length > OUTPUT_MAX) return null
  try { return JSON.parse(raw) } catch (e) { return null }
}

// ---------------------------------------------------------------- the bar

function entryId(entry) {
  if (typeof entry === "string") return entry
  return isObject(entry) && typeof entry.id === "string" ? entry.id : ""
}

function entryOptions(entry) {
  var out = {}
  if (!isObject(entry)) return out
  var count = 0
  for (var key in entry) {
    if (key === "id" || count >= OPTIONS_MAX) continue
    out[key] = copy(entry[key])
    count++
  }
  return out
}

// The bar as Barber works on it. Entries keep their places in shell.json's arrays even when their ids are not ones it
// can act on, because the shell's IPC addresses widgets by those places.
function readBar(config) {
  var bar = isObject(config) && isObject(config.bar) ? config.bar : {}
  var layout = isObject(bar.layout) ? bar.layout : {}
  var sections = {}
  for (var s = 0; s < SECTIONS.length; s++) {
    sections[SECTIONS[s]] = toList(layout[SECTIONS[s]]).slice(0, ENTRIES_MAX).map(function (entry) {
      return { id: entryId(entry), options: entryOptions(entry) }
    })
  }
  return {
    position: POSITIONS.indexOf(bar.position) >= 0 ? bar.position : "top",
    transparent: bar.transparent === true,
    sections: sections
  }
}

// Barber's own entry in shell.json's plugin list, where its settings are kept.
function ownEntry(config, id) {
  var list = isObject(config) ? toList(config.plugins) : []
  for (var i = 0; i < list.length; i++)
    if (isObject(list[i]) && list[i].id === id) return list[i]
  return null
}

function isVertical(bar) { return !!bar && (bar.position === "left" || bar.position === "right") }

function count(sections, id) {
  var n = 0
  for (var s = 0; s < SECTIONS.length; s++)
    toList(sections[SECTIONS[s]]).forEach(function (e) { if (e.id === id) n++ })
  return n
}

function locate(sections, id) {
  return nth(sections, id, 0)
}

// Where the `n`th instance of `id` is along the bar (0 is the first).
function nth(sections, id, n) {
  var seen = 0
  for (var s = 0; s < SECTIONS.length; s++) {
    var entries = toList(sections[SECTIONS[s]])
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].id !== id) continue
      if (seen === n) return { section: SECTIONS[s], index: i }
      seen++
    }
  }
  return null
}

function widgetCount(sections) {
  var n = 0
  for (var s = 0; s < SECTIONS.length; s++)
    toList(sections[SECTIONS[s]]).forEach(function (e) { if (validId(e.id)) n++ })
  return n
}

// What undo relies on: the bar as Barber last left it. When anything else has changed the bar since, the places a
// stored undo names may point at other widgets, so the history is dropped rather than replayed.
function barSignature(bar) {
  return JSON.stringify({ p: bar.position, t: bar.transparent, s: bar.sections })
}

// The live geometry (the shell's debugBarGeometry) matched to the layout: which drawn box is which entry. The shell
// lists its slots in the order they were made, one bar after another, so for each id the first boxes are taken, as
// many as the section has entries with that id, and paired with those entries in order along the bar.
function chips(geometry, bar) {
  var list = toList(geometry).filter(function (g) {
    return isObject(g) && validId(g.id) && SECTIONS.indexOf(g.section) >= 0
  })
  var along = isVertical(bar) ? "y" : "x"
  var out = []
  for (var s = 0; s < SECTIONS.length; s++) {
    var section = SECTIONS[s]
    var entries = bar.sections[section]
    var wanted = {}
    entries.forEach(function (e) { if (validId(e.id)) wanted[e.id] = (wanted[e.id] || 0) + 1 })
    var boxes = {}
    list.forEach(function (g) {
      if (g.section !== section || !wanted[g.id]) return
      var mine = boxes[g.id] || (boxes[g.id] = [])
      if (mine.length < wanted[g.id])
        mine.push({ x: num(g.x), y: num(g.y), width: Math.max(0, num(g.width)), height: Math.max(0, num(g.height)),
                    visible: g.visible === true })
    })
    for (var id in boxes) boxes[id].sort(function (a, b) { return a[along] - b[along] })
    var taken = {}
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      if (!validId(entry.id)) continue
      var nthBox = taken[entry.id] || 0
      taken[entry.id] = nthBox + 1
      var box = (boxes[entry.id] || [])[nthBox] || null
      out.push({ key: section + ":" + i, id: entry.id, section: section, index: i, options: entry.options,
                 instances: count(bar.sections, entry.id),
                 x: box ? box.x : 0, y: box ? box.y : 0, width: box ? box.width : 0, height: box ? box.height : 0,
                 shown: !!box && box.visible && box.width > 0 && box.height > 0 })
    }
  }
  return out
}

// The widgets in the order you meet them along the bar: left, center, right, each in its own order.
function barOrder(chipList) {
  return toList(chipList).slice().sort(function (a, b) {
    var sa = SECTIONS.indexOf(a.section), sb = SECTIONS.indexOf(b.section)
    return sa !== sb ? sa - sb : a.index - b.index
  })
}

// The key of the widget `delta` places along from the one with `key` (the first or last when none is chosen).
function stepKey(chipList, key, delta) {
  var order = barOrder(chipList)
  if (order.length === 0) return ""
  var at = -1
  for (var i = 0; i < order.length; i++) if (order[i].key === key) at = i
  if (at < 0) return order[delta >= 0 ? 0 : order.length - 1].key
  return order[Math.max(0, Math.min(order.length - 1, at + delta))].key
}

function chipByKey(chipList, key) {
  var list = toList(chipList)
  for (var i = 0; i < list.length; i++) if (list[i].key === key) return list[i]
  return null
}

// A widget picked in edit mode is remembered as which instance of its id it is along the bar, not by its place, so
// the pick stays on the widget when a move, an undo or another widget's removal shifts the places around it.
function chipInstance(chipList, chip) {
  if (!chip) return 0
  var order = barOrder(chipList)
  var n = 0
  for (var i = 0; i < order.length; i++) {
    if (order[i].key === chip.key) return n
    if (order[i].id === chip.id) n++
  }
  return 0
}

function chipOfInstance(chipList, id, n) {
  if (!id) return null
  var order = barOrder(chipList)
  var seen = 0
  for (var i = 0; i < order.length; i++) {
    if (order[i].id !== id) continue
    if (seen === n) return order[i]
    seen++
  }
  return null
}

// One place earlier or later along the bar: within the section, or over into the next section's near end.
function nudgeTarget(bar, chip, delta) {
  var s = SECTIONS.indexOf(chip.section)
  var length = bar.sections[chip.section].length
  if (delta < 0) {
    if (chip.index > 0) return { section: chip.section, index: chip.index - 1 }
    return s > 0 ? { section: SECTIONS[s - 1], index: bar.sections[SECTIONS[s - 1]].length } : null
  }
  if (chip.index < length - 1) return { section: chip.section, index: chip.index + 1 }
  return s < SECTIONS.length - 1 ? { section: SECTIONS[s + 1], index: 0 } : null
}

var DROP_NEAR = 48            // pixels from a widget's middle that count as dropping beside it

// Where a widget dragged to `point` lands: beside the nearest shown widget when the point is close to one, before or
// after it by which side of its middle the point is on; otherwise in the third of the bar the point is over (the
// nearest widget in that section, or the section itself when it is empty). The index is the one the shell wants:
// counted after the dragged widget has been taken out of its section.
function dropTarget(bar, chipList, dragged, point, barLength) {
  var along = isVertical(bar) ? "y" : "x"
  var size = along === "x" ? "width" : "height"
  var at = num(point[along])
  var third = Math.max(1, num(barLength)) / 3
  var zone = SECTIONS[Math.max(0, Math.min(2, Math.floor(at / third)))]

  function nearest(section) {
    var best = null
    toList(chipList).forEach(function (c) {
      if (!c.shown || c.key === dragged.key || (section && c.section !== section)) return
      var middle = c[along] + c[size] / 2
      var distance = Math.abs(at - middle)
      if (!best || distance < best.distance) best = { chip: c, distance: distance, after: at > middle }
    })
    return best
  }

  var close = nearest("")
  var pick = close && close.distance <= DROP_NEAR ? close : nearest(zone)
  var target = pick ? { section: pick.chip.section, index: pick.chip.index + (pick.after ? 1 : 0) }
                    : { section: zone, index: zone === "left" ? 0 : bar.sections[zone].length }
  if (target.section === dragged.section && target.index > dragged.index) target.index--
  return target
}

// Where along the bar the marker for a drop at `target` goes: the start of the widget that will follow the dropped
// one, the end of the one it will follow, or the middle of an empty section's third of the bar.
function dropMarker(bar, chipList, dragged, target, barLength) {
  var along = isVertical(bar) ? "y" : "x"
  var size = along === "x" ? "width" : "height"
  // The target counts places with the dragged widget out; the chips still count them with it in.
  var place = target.index + (target.section === dragged.section && target.index >= dragged.index ? 1 : 0)
  var after = null
  var before = null
  toList(chipList).forEach(function (c) {
    if (c.section !== target.section || c.key === dragged.key || !c.shown) return
    if (c.index >= place && (!after || c.index < after.index)) after = c
    if (c.index < place && (!before || c.index > before.index)) before = c
  })
  if (after) return after[along]
  if (before) return before[along] + before[size]
  return Math.max(1, num(barLength)) / 3 * (SECTIONS.indexOf(target.section) + 0.5)
}

// ---------------------------------------------------------------- calls, and the calls that take them back

// A call to the shell's IPC (`omarchy-shell shell <fn> <args>`), or to `omarchy-bar` for what the IPC has no verb for.
function call(fn) {
  return { tool: "shell", fn: fn, args: Array.prototype.slice.call(arguments, 1).map(String) }
}

function barCall() {
  return { tool: "bar", fn: "", args: Array.prototype.slice.call(arguments).map(String) }
}

// The argument list a call runs with, tool first: the shell's IPC by its verb, or the bar command.
function argv(c, tools) {
  if (!isObject(c) || !isObject(tools)) return []
  if (c.tool === "shell") return [tools.shell, "shell", c.fn].concat(toList(c.args))
  if (c.tool === "bar") return [tools.bar].concat(toList(c.args))
  return []
}

// Whether a call's output says it worked: the IPC's verbs answer "ok" or say what went wrong.
function callSucceeded(c, exitCode, output) {
  if (exitCode !== 0) return false
  return c.tool === "bar" || String(output || "").trim() === "ok"
}

// A change to the bar: what runs, and what undoes it.
function change(label, run, undo) {
  return { label: label, run: run, undo: undo }
}

function moveChange(bar, chip, target) {
  if (!target || SECTIONS.indexOf(target.section) < 0) return null
  var room = bar.sections[target.section].length - (target.section === chip.section ? 1 : 0)
  var index = Math.max(0, Math.min(Math.floor(num(target.index)), room))
  if (target.section === chip.section && index === chip.index) return null
  return change("Move", [call("moveBarWidget", chip.id, json({ fromSection: chip.section, fromIndex: chip.index,
                                                                section: target.section, index: index }))],
                [call("moveBarWidget", chip.id, json({ fromSection: target.section, fromIndex: index,
                                                        section: chip.section, index: chip.index }))])
}

// Off the bar. The shell drops the entry, options and all, so putting it back sets them again. A widget that is on the
// bar more than once cannot be taken off one instance at a time through the shell, so it is not offered.
function removeChange(chip) {
  if (!chip || chip.instances > 1) return null
  var undo = [call("enablePlugin", chip.id, json({ section: chip.section, index: chip.index }))]
  for (var key in chip.options)
    undo.push(call("setBarWidget", chip.id, key, json(chip.options[key]), json({ section: chip.section })))
  return change("Remove", [call("setPluginEnabled", chip.id, "false")], undo)
}

function addChange(bar, id, section, index) {
  if (!validId(id) || SECTIONS.indexOf(section) < 0 || count(bar.sections, id) > 0) return null
  var length = bar.sections[section].length
  var at = index === undefined || index === null ? length : Math.max(0, Math.min(Math.floor(num(index)), length))
  return change("Add", [call("enablePlugin", id, json({ section: section, index: at }))],
                [call("setPluginEnabled", id, "false")])
}

// Where a widget picked in the gallery goes: after the widget chosen on the bar, or at the end of its own side.
function addPlace(bar, chip, meta) {
  if (chip && SECTIONS.indexOf(chip.section) >= 0) return { section: chip.section, index: chip.index + 1 }
  var section = isObject(meta) && SECTIONS.indexOf(meta.defaultSection) >= 0 ? meta.defaultSection : "center"
  return { section: section, index: bar.sections[section].length }
}

// One option. A key the entry did not have is undone back to the field's own default, when there is one: the shell
// can set an option but not take it off again.
function optionChange(chip, key, value, fallback) {
  if (!chip || typeof key !== "string" || !key || key === "id") return null
  var had = Object.prototype.hasOwnProperty.call(chip.options, key)
  var before = had ? chip.options[key] : fallback
  if (same(before, value)) return null
  var selector = chip.instances > 1 ? { section: chip.section, index: chip.index } : { section: chip.section }
  var undo = before === undefined ? [] : [call("setBarWidget", chip.id, key, json(before), json(selector))]
  return change("Change", [call("setBarWidget", chip.id, key, json(value), json(selector))], undo)
}

function transparencyChange() {
  return change("Transparency", [call("toggleBarTransparency")], [call("toggleBarTransparency")])
}

function positionChange(bar, position) {
  if (POSITIONS.indexOf(position) < 0 || position === bar.position) return null
  return change("Position", [barCall("position", position)], [barCall("position", bar.position)])
}

// Undo and redo, as plain values.
function emptyHistory() { return { done: [], undone: [] } }

function record(history, ch) {
  if (!ch) return history
  var done = toList(history.done).concat([ch])
  return { done: done.slice(Math.max(0, done.length - UNDO_MAX)), undone: [] }
}

function undoStep(history) {
  var done = toList(history.done)
  if (done.length === 0) return null
  var ch = done.pop()
  return { history: { done: done, undone: toList(history.undone).concat([ch]) }, calls: ch.undo, change: ch }
}

function redoStep(history) {
  var undone = toList(history.undone)
  if (undone.length === 0) return null
  var ch = undone.pop()
  return { history: { done: toList(history.done).concat([ch]), undone: undone }, calls: ch.run, change: ch }
}

// ---------------------------------------------------------------- plugins that are more than their button

function pluginById(plugins, id) {
  var list = toList(plugins)
  for (var i = 0; i < list.length; i++) if (isObject(list[i]) && list[i].id === id) return list[i]
  return null
}

function widgetInstalled(plugins, id) {
  var plugin = pluginById(plugins, id)
  return !!plugin && toList(plugin.kinds).indexOf("bar-widget") >= 0
}

// Whether taking the widget off the bar switches its whole plugin off. A plugin that is not built in is enabled by
// having a place in shell.json, and for a widget that place is the bar: one that also runs a service, a panel or a
// menu stops with its button. Built-in plugins stay loaded either way.
function stopsPlugin(plugin) {
  return isObject(plugin) && plugin.firstParty !== true &&
    toList(plugin.kinds).some(function (kind) { return kind !== "bar-widget" })
}

// ---------------------------------------------------------------- layouts

// A layout as Barber keeps it: each section's widgets with their options, and how the bar sits.
function snapshot(bar, name) {
  var sections = {}
  for (var s = 0; s < SECTIONS.length; s++)
    sections[SECTIONS[s]] = bar.sections[SECTIONS[s]].filter(function (e) { return validId(e.id) })
                                                     .map(function (e) { return { id: e.id, options: copy(e.options) } })
  return { name: text(name, NAME_MAX), position: bar.position, transparent: bar.transparent, sections: sections }
}

// The calls that turn the bar into `layout`, planned against a copy of the bar that each call is applied to as it is
// planned, so every place handed to the shell is right at the moment it acts. Widgets no longer installed are left
// out, a widget the bar holds more than once is left where it is, and a widget `keep` names is never taken off (its
// plugin would stop with it).
function planLayout(bar, layout, installed, keep) {
  var work = {}
  for (var s = 0; s < SECTIONS.length; s++)
    work[SECTIONS[s]] = bar.sections[SECTIONS[s]].map(function (e) { return { id: e.id, options: copy(e.options) } })
  var target = readLayout(layout)
  if (!target) return []
  var isInstalled = typeof installed === "function" ? installed : function () { return true }
  var mustStay = typeof keep === "function" ? keep : function () { return false }
  var calls = []

  function wanted(id) { return validId(id) && count(target.sections, id) === 1 && isInstalled(id) }

  // What the layout does not have comes off.
  SECTIONS.forEach(function (section) {
    for (var i = work[section].length - 1; i >= 0; i--) {
      var id = work[section][i].id
      if (!validId(id) || count(target.sections, id) > 0 || count(work, id) !== 1 || mustStay(id)) continue
      calls.push(call("setPluginEnabled", id, "false"))
      work[section].splice(i, 1)
    }
  })
  // What the bar does not have goes on, where the layout has it.
  SECTIONS.forEach(function (section) {
    target.sections[section].forEach(function (e, i) {
      if (!wanted(e.id) || count(work, e.id) > 0) return
      var at = Math.min(i, work[section].length)
      calls.push(call("enablePlugin", e.id, json({ section: section, index: at })))
      work[section].splice(at, 0, { id: e.id, options: {} })
    })
  })
  // Then into the layout's order, section by section from the left. A widget on the bar more than once is moved one
  // instance at a time: the instances already put in place come first along the bar, so the next one to place is
  // always the first of its id not yet placed.
  var placed = {}
  SECTIONS.forEach(function (section) {
    var position = 0
    target.sections[section].forEach(function (e) {
      if (!validId(e.id) || !isInstalled(e.id)) return
      var n = placed[e.id] || 0
      var from = nth(work, e.id, n)
      if (!from) return
      placed[e.id] = n + 1
      var at = Math.min(position, work[section].length - (from.section === section ? 1 : 0))
      if (!(from.section === section && from.index === at)) {
        var entry = work[from.section].splice(from.index, 1)[0]
        calls.push(call("moveBarWidget", e.id, json({ fromSection: from.section, fromIndex: from.index, section: section, index: at })))
        work[section].splice(at, 0, entry)
      }
      // Then the options it has that the bar does not, on this very instance.
      var current = work[section][at].options
      var selector = count(work, e.id) > 1 ? { section: section, index: at } : { section: section }
      for (var key in e.options) {
        if (same(current[key], e.options[key])) continue
        calls.push(call("setBarWidget", e.id, key, json(e.options[key]), json(selector)))
        current[key] = copy(e.options[key])
      }
      position = at + 1
    })
  })
  if (target.transparent !== bar.transparent) calls.push(call("toggleBarTransparency"))
  if (target.position !== bar.position) calls.push(barCall("position", target.position))
  return calls
}

// A stored layout, checked: null when it is not one.
function readLayout(raw) {
  if (!isObject(raw) || !isObject(raw.sections)) return null
  var sections = {}
  for (var s = 0; s < SECTIONS.length; s++) {
    sections[SECTIONS[s]] = toList(raw.sections[SECTIONS[s]]).slice(0, ENTRIES_MAX).filter(function (e) {
      return isObject(e) && validId(e.id)
    }).map(function (e) { return { id: e.id, options: entryOptions(isObject(e.options) ? e.options : {}) } })
  }
  return { name: text(raw.name, NAME_MAX), position: POSITIONS.indexOf(raw.position) >= 0 ? raw.position : "top",
           transparent: raw.transparent === true, sections: sections }
}

// Whether the bar already wears the layout: the same widgets in the same places, with its options set.
function wears(bar, layout, installed, keep) {
  return planLayout(bar, layout, installed, keep).length === 0
}

function summarizeLayout(layout) {
  var n = widgetCount(layout.sections)
  return n + (n === 1 ? " widget" : " widgets") + " · " + layout.position
}

// ---------------------------------------------------------------- rules

// When the bar should put a layout on by itself. A rule holds when every condition it sets holds:
//   power "battery" | "ac", screens "external" | "laptop", fullscreen true, app: text in the focused window's class
//   or title.
function readRule(raw) {
  if (!isObject(raw) || typeof raw.layout !== "string" || !raw.layout) return null
  var when = isObject(raw.when) ? raw.when : {}
  var rule = { layout: text(raw.layout, NAME_MAX), enabled: raw.enabled !== false, when: {} }
  if (when.power === "battery" || when.power === "ac") rule.when.power = when.power
  if (when.screens === "external" || when.screens === "laptop") rule.when.screens = when.screens
  if (when.fullscreen === true) rule.when.fullscreen = true
  if (typeof when.app === "string" && when.app.trim()) rule.when.app = when.app.trim().slice(0, 80)
  return Object.keys(rule.when).length ? rule : null
}

function holds(rule, context) {
  var when = rule.when
  var c = isObject(context) ? context : {}
  if (when.power === "battery" && c.onBattery !== true) return false
  if (when.power === "ac" && c.onBattery === true) return false
  if (when.screens === "external" && c.externalScreen !== true) return false
  if (when.screens === "laptop" && c.externalScreen === true) return false
  if (when.fullscreen === true && c.fullscreen !== true) return false
  if (when.app) {
    var needle = when.app.toLowerCase()
    if ((String(c.appClass || "") + NL + String(c.appTitle || "")).toLowerCase().indexOf(needle) < 0) return false
  }
  return true
}

// The layout for the moment: the first rule that is on and holds, or the base layout.
function chooseLayout(settings, context) {
  var rules = toList(settings.rules)
  for (var i = 0; i < rules.length; i++)
    if (rules[i].enabled && holds(rules[i], context)) return rules[i].layout
  return settings.baseLayout
}

function describeRule(rule) {
  var parts = []
  var when = rule.when
  if (when.power) parts.push(when.power === "battery" ? "on battery" : "plugged in")
  if (when.screens) parts.push(when.screens === "external" ? "with a monitor connected" : "on the laptop screen alone")
  if (when.fullscreen) parts.push("while a window is fullscreen")
  if (when.app) parts.push("in " + when.app)
  return parts.join(", ")
}

// What the rules see right now, in words.
function describeContext(context) {
  var c = isObject(context) ? context : {}
  var parts = [c.onBattery === true ? "On battery" : "Plugged in", c.externalScreen === true ? "monitor connected" : "laptop screen alone"]
  if (c.fullscreen === true) parts.push("fullscreen")
  if (typeof c.appClass === "string" && c.appClass) parts.push(c.appClass.slice(0, 60))
  return parts.join(" · ")
}

// Laptop panels are eDP, LVDS or DSI outputs; a headless output is a virtual screen, not a monitor someone plugged in.
function hasExternalScreen(names) {
  return toList(names).some(function (name) {
    var s = String(name || "")
    return s !== "" && !/^(eDP|LVDS|DSI|HEADLESS)-/i.test(s)
  })
}

// ---------------------------------------------------------------- Barber's own settings

// What Barber keeps in its entry in shell.json, checked on the way in.
function readSettings(entry) {
  var raw = isObject(entry) ? entry : {}
  var layouts = []
  var names = {}
  toList(raw.layouts).slice(0, LAYOUTS_MAX).forEach(function (l) {
    var layout = readLayout(l)
    if (layout && layout.name && !names[layout.name]) {
      names[layout.name] = true
      layouts.push(layout)
    }
  })
  var rules = toList(raw.rules).slice(0, RULES_MAX).map(readRule).filter(function (r) { return r && names[r.layout] })
  return {
    layouts: layouts,
    rules: rules,
    baseLayout: typeof raw.baseLayout === "string" && names[raw.baseLayout] ? raw.baseLayout : "",
    auto: raw.auto === true,
    shortcut: typeof raw.shortcut === "string" && (raw.shortcut === "" || COMBO_RE.test(raw.shortcut))
      ? raw.shortcut : "SUPER + ALT + B"
  }
}

// The settings as they are written back to Barber's entry.
function settingsPayload(settings) {
  return { layouts: copy(settings.layouts), rules: copy(settings.rules), baseLayout: settings.baseLayout,
           auto: settings.auto === true, shortcut: settings.shortcut }
}

function withLayout(settings, layout) {
  var next = copy(settings)
  var at = -1
  next.layouts.forEach(function (l, i) { if (l.name === layout.name) at = i })
  if (at >= 0) next.layouts[at] = copy(layout)
  else if (next.layouts.length < LAYOUTS_MAX) next.layouts.push(copy(layout))
  return next
}

function withoutLayout(settings, name) {
  var next = copy(settings)
  next.layouts = next.layouts.filter(function (l) { return l.name !== name })
  next.rules = next.rules.filter(function (r) { return r.layout !== name })
  if (next.baseLayout === name) next.baseLayout = ""
  return next
}

function layoutByName(settings, name) {
  var list = toList(settings.layouts)
  for (var i = 0; i < list.length; i++) if (list[i].name === name) return list[i]
  return null
}

// A name for a new layout that is not taken: "Layout 2", "Layout 3"...
function freshName(settings, base) {
  var stem = text(base || "Layout", NAME_MAX - 4)
  if (!layoutByName(settings, stem)) return stem
  for (var n = 2; n < 100; n++) if (!layoutByName(settings, stem + " " + n)) return stem + " " + n
  return stem + " " + Date.now() % 1000
}

function withRule(settings, raw) {
  var next = copy(settings)
  var rule = readRule(raw)
  if (rule && layoutByName(next, rule.layout) && next.rules.length < RULES_MAX) next.rules.push(rule)
  return next
}

function withoutRule(settings, index) {
  var next = copy(settings)
  if (index >= 0 && index < next.rules.length) next.rules.splice(index, 1)
  return next
}

function withRuleEnabled(settings, index, on) {
  var next = copy(settings)
  if (index >= 0 && index < next.rules.length) next.rules[index].enabled = on === true
  return next
}

// ---------------------------------------------------------------- widgets that can go on the bar, and their options

function catalogIndex(catalog) {
  var byId = {}
  toList(catalog).forEach(function (p) { if (isObject(p) && validId(p.id)) byId[p.id] = p })
  return byId
}

function widgetMeta(index, id) {
  var entry = index[id]
  return entry && isObject(entry.barWidget) ? entry.barWidget : {}
}

function widgetName(index, id) {
  var entry = index[id] || {}
  return text(widgetMeta(index, id).displayName || entry.name || id, 60)
}

// The widgets that can go on the bar and are not on it, found by name, description, category or id.
function gallery(plugins, index, query) {
  var q = String(query || "").trim().toLowerCase()
  return toList(plugins).filter(function (p) {
    return isObject(p) && validId(p.id) && toList(p.kinds).indexOf("bar-widget") >= 0 && p.enabled !== true
  }).map(function (p) {
    var meta = widgetMeta(index, p.id)
    var entry = index[p.id] || {}
    return { id: p.id, name: text(meta.displayName || p.name || p.id, 60),
             description: text(meta.description || entry.description, TEXT_MAX), category: text(meta.category, 40),
             firstParty: p.firstParty === true, stopsPlugin: false }
  }).filter(function (w) {
    return !q || (w.name + NL + w.description + NL + w.category + NL + w.id).toLowerCase().indexOf(q) >= 0
  }).sort(function (a, b) { return a.name.localeCompare(b.name) })
}

// Where a widget's manifest may be read from: the shell's own plugins, or the user's plugin folder. The catalog names
// the path, and nothing but a manifest.json under one of those two roots is opened.
function manifestPathAllowed(path, home) {
  var p = typeof path === "string" ? path : ""
  if (p.length === 0 || p.length > 4096 || p.charAt(0) !== "/" || p.indexOf(String.fromCharCode(0)) >= 0) return false
  var parts = p.split("/")
  if (parts[parts.length - 1] !== "manifest.json") return false
  for (var i = 1; i < parts.length; i++)
    if (parts[i] === "" || parts[i] === "." || parts[i] === "..") return false
  var roots = ["/usr/share/omarchy/shell/plugins/"]
  var h = typeof home === "string" ? home : ""
  while (h.length > 1 && h.charAt(h.length - 1) === "/") h = h.slice(0, -1)
  if (h.length > 1 && h.charAt(0) === "/") roots.push(h + "/.config/omarchy/plugins/")
  return roots.some(function (root) { return p.indexOf(root) === 0 && p.length > root.length })
}

// A widget manifest's bar-widget part, checked: what the settings form needs.
function readWidgetManifest(raw) {
  if (!isObject(raw) || !isObject(raw.barWidget)) return {}
  var bw = raw.barWidget
  return {
    displayName: text(bw.displayName, 60),
    description: text(bw.description),
    category: text(bw.category, 40),
    defaultSection: SECTIONS.indexOf(bw.defaultSection) >= 0 ? bw.defaultSection : "",
    allowMultiple: bw.allowMultiple === true,
    settingsForm: text(bw.settingsForm, 40),
    defaults: isObject(bw.defaults) ? entryOptions(bw.defaults) : {},
    schema: toList(bw.schema).slice(0, FIELDS_MAX)
  }
}

// The built-in widgets whose settings Omarchy draws with forms of its own instead of a schema, as schemas. Defaults are
// the widgets' own, so an option undone to its default looks the way it did before.
var BUILTIN_FORMS = {
  spacerSettings: [
    { key: "size", type: "integer", label: "Size (pixels)", min: 0, max: 256, step: 1, defaultValue: 12 }
  ],
  clockSettings: [
    { key: "format", type: "string", label: "Format", defaultValue: "dddd HH:mm", bars: "horizontal",
      description: "Qt date format: dddd weekday, d day, MMMM month, HH:mm time." },
    { key: "formatAlt", type: "string", label: "Format after a click", defaultValue: "d MMMM 'W'ww yyyy", bars: "horizontal" },
    { key: "verticalFormat", type: "string", label: "Format", defaultValue: "HH" + NL + "—" + NL + "mm", bars: "vertical",
      multiline: true, description: "Type " + BACKSLASH + "n for a new line." },
    { key: "verticalFormatAlt", type: "string", label: "Format after a click", defaultValue: "dd" + NL + "MMM" + NL + "'W'ww" + NL + "''yy",
      bars: "vertical", multiline: true }
  ],
  weatherSettings: [
    { key: "refreshMinutes", type: "integer", label: "Refresh every (minutes)", min: 1, max: 1440, step: 1, defaultValue: 15 }
  ]
}

var FIELD_TYPES = ["boolean", "integer", "number", "string", "path", "enum", "multiselect"]

// A widget's options as a form: its manifest's schema, filled from its entry, with the manifest's defaults behind.
function formFields(meta, options) {
  var defaults = isObject(meta) && isObject(meta.defaults) ? meta.defaults : {}
  var own = isObject(options) ? options : {}
  return toList(isObject(meta) ? meta.schema : null).slice(0, FIELDS_MAX).filter(function (f) {
    return isObject(f) && typeof f.key === "string" && f.key && f.key !== "id" && f.key.length <= 64
  }).map(function (f) {
    var fallback = f.defaultValue !== undefined ? f.defaultValue : defaults[f.key]
    var value = own[f.key] !== undefined ? own[f.key] : fallback
    return {
      key: f.key,
      type: FIELD_TYPES.indexOf(f.type) >= 0 ? f.type : "unknown",
      label: text(f.label || f.key, 80),
      description: text(f.description, 400),
      value: copy(value),
      fallback: copy(fallback),
      choices: toList(f.options).slice(0, CHOICES_MAX).map(function (o) { return isObject(o) ? String(o.value) : String(o) }),
      min: typeof f.min === "number" ? f.min : null,
      max: typeof f.max === "number" ? f.max : null,
      step: typeof f.step === "number" && f.step > 0 ? f.step : 1,
      multiline: f.multiline === true
    }
  })
}

// The form for a widget: the built-in form it names, for the way the bar runs, or its manifest's schema.
function formFieldsFor(meta, options, vertical) {
  var m = isObject(meta) ? meta : {}
  var schema = has(BUILTIN_FORMS, m.settingsForm) ? BUILTIN_FORMS[m.settingsForm] : m.schema
  var direction = vertical ? "vertical" : "horizontal"
  return formFields({ defaults: m.defaults, schema: toList(schema).filter(function (f) {
    return !isObject(f) || !f.bars || f.bars === direction
  }) }, options)
}

// Multi-line text is edited on one line, with the new lines written as backslash-n.
function shownText(field, value) {
  var s = value === undefined || value === null ? "" : String(value)
  return field.multiline ? s.split(NL).join(BACKSLASH + "n") : s
}

function typedText(field, s) {
  var t = String(s)
  return field.multiline ? t.split(BACKSLASH + "n").join(NL) : t
}

// A value typed or picked in a form, made the type its field wants: undefined when it cannot be one.
function coerce(field, value) {
  switch (field.type) {
  case "boolean":
    return value === true || value === "true"
  case "integer":
  case "number": {
    var n = Number(value)
    if (value === "" || value === null || !isFinite(n)) return undefined
    if (field.type === "integer") n = Math.round(n)
    if (field.min !== null) n = Math.max(field.min, n)
    if (field.max !== null) n = Math.min(field.max, n)
    return n
  }
  case "enum":
    return field.choices.indexOf(String(value)) >= 0 ? String(value) : undefined
  case "multiselect":
    return toList(value).map(String).filter(function (v) {
      return field.choices.length === 0 || field.choices.indexOf(v) >= 0
    }).slice(0, CHOICES_MAX)
  case "string":
  case "path":
    return typeof value === "string" ? value.slice(0, 1000) : undefined
  default:
    return undefined
  }
}

// ---------------------------------------------------------------- the shortcut

var BIND_DESCRIPTION = "Barber: edit the bar"
var SHORTCUTS = ["SUPER + ALT + B", "SUPER + CTRL + B", "SUPER + SHIFT + B", "SUPER + ALT + E"]
var MODS = { SUPER: 64, ALT: 8, CTRL: 4, SHIFT: 1 }

function comboParts(combo) {
  if (!COMBO_RE.test(String(combo || ""))) return null
  var parts = String(combo).split(" + ")
  var mask = 0
  for (var i = 0; i < parts.length - 1; i++) mask |= MODS[parts[i]]
  return { mask: mask, key: parts[parts.length - 1] }
}

// What holds the shortcut's keys now (from `hyprctl binds -j`): nothing ("free"), only Barber's own bind ("ours"),
// or something else ("taken"). Binds inside a submap do not hold the keys outside it.
function bindState(binds, combo) {
  if (combo === "") return "off"
  var parts = comboParts(combo)
  if (!parts) return "invalid"
  var on = toList(binds).filter(function (b) {
    return isObject(b) && Number(b.modmask) === parts.mask && String(b.key || "").toUpperCase() === parts.key && !b.submap
  })
  if (on.length === 0) return "free"
  return on.every(function (b) { return b.description === BIND_DESCRIPTION }) ? "ours" : "taken"
}

// Hyprland's Lua bind for the shortcut, or "" when it is not one Barber made itself.
function bindStatement(combo, command) {
  var cmd = String(command || "")
  if (!COMBO_RE.test(String(combo || "")) || cmd.indexOf(QUOTE) >= 0 || cmd.indexOf(BACKSLASH) >= 0 || cmd.indexOf(NL) >= 0) return ""
  return "hl.bind(" + QUOTE + combo + QUOTE + ", hl.dsp.exec_cmd(" + QUOTE + cmd + QUOTE + "), { description = " +
    QUOTE + BIND_DESCRIPTION + QUOTE + " })"
}

// Hyprland drops every bind on the keys it is given, so this is only sent when bindState says they are Barber's.
function unbindStatement(combo) {
  return COMBO_RE.test(String(combo || "")) ? "hl.unbind(" + QUOTE + combo + QUOTE + ")" : ""
}
