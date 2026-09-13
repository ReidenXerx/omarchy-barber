#!/usr/bin/env node
// Barber's model: reading the bar, matching its live geometry, every change and the change that undoes it, layouts,
// rules, settings, the widget gallery and settings forms. Changes are replayed through a small copy of the shell's
// registry (services/PluginRegistry.qml), so "undo restores the bar" is checked against the rules the shell applies.
const assert = require("assert")
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const source = fs.readFileSync(path.join(__dirname, "..", "BarberModel.js"), "utf8")
const box = {}
vm.runInNewContext(source + "\nthis.M = { SECTIONS, readBar, chips, barOrder, stepKey, chipByKey, nudgeTarget, dropTarget, call, " +
  "moveChange, removeChange, addChange, optionChange, transparencyChange, positionChange, emptyHistory, record, undoStep, " +
  "redoStep, snapshot, planLayout, readLayout, wears, readRule, holds, chooseLayout, describeRule, readSettings, withLayout, " +
  "withoutLayout, layoutByName, freshName, catalogIndex, widgetName, gallery, formFields, coerce, bindStatement, " +
  "dropMarker, addPlace, barSignature, stopsPlugin, pluginById, widgetInstalled, summarizeLayout, describeContext, " +
  "hasExternalScreen, settingsPayload, withRule, withoutRule, withRuleEnabled, manifestPathAllowed, readWidgetManifest, " +
  "formFieldsFor, shownText, typedText, comboParts, bindState, unbindStatement, SHORTCUTS, argv, callSucceeded, " +
  "parseOutput, ownEntry, chipInstance, chipOfInstance }", box)
const M = box.M

let passed = 0
let failed = 0
function test(name, fn) {
  try {
    fn()
    passed++
  } catch (e) {
    failed++
    console.log("FAIL " + name + ": " + e.message + " @ " + String(e.stack).split(String.fromCharCode(10)).slice(1, 4).join(" | "))
  }
}
const plain = (v) => JSON.parse(JSON.stringify(v))
// Node refuses an undefined message on a failing assertion, so one is passed only when there is one.
const eq = (a, b, msg) => (msg === undefined ? assert.deepStrictEqual(plain(a), plain(b)) : assert.deepStrictEqual(plain(a), plain(b), msg))

// ---------------------------------------------------------------- the shell's registry, reduced to what Barber calls

function simulate(config, calls) {
  const bar = config.bar
  const L = bar.layout
  const idOf = (e) => (typeof e === "string" ? e : e.id)
  const all = ["left", "center", "right"]
  function find(id, section) {
    for (const s of section ? [section] : all) {
      const i = L[s].findIndex((e) => idOf(e) === id)
      if (i >= 0) return { section: s, index: i }
    }
    return null
  }
  function target(p, fallback) {
    const section = all.includes(p.section) ? p.section : fallback
    const relative = p.before || p.after
    if (relative) {
      const r = find(relative, p.section ? section : "")
      if (!r) throw new Error("could not find target widget " + relative)
      return { section: r.section, index: r.index + (p.after ? 1 : 0) }
    }
    if (p.index !== undefined && p.index !== null)
      return { section, index: Math.min(Math.max(0, Math.floor(Number(p.index))), L[section].length) }
    return { section, index: L[section].length }
  }
  function move(id, p) {
    let from
    if (p.fromIndex !== undefined && p.fromIndex !== null) {
      from = { section: p.fromSection, index: p.fromIndex }
      if (!L[from.section][from.index] || idOf(L[from.section][from.index]) !== id)
        throw new Error("widget at " + from.section + "[" + from.index + "] is not " + id)
    } else {
      from = find(id, p.fromSection || "")
    }
    if (!from) throw new Error("could not find widget " + id)
    const entry = L[from.section].splice(from.index, 1)[0]
    const t = target(p, from.section)
    L[t.section].splice(t.index, 0, entry)
  }
  for (const c of calls) {
    if (c.tool === "bar") {
      if (c.args[0] === "position") bar.position = c.args[1]
      continue
    }
    const a = c.args
    switch (c.fn) {
    case "moveBarWidget":
      move(a[0], JSON.parse(a[1]))
      break
    case "setPluginEnabled": {
      const at = find(a[0])
      if (a[1] === "false" && at) L[at.section].splice(at.index, 1)
      break
    }
    case "enablePlugin": {
      const p = JSON.parse(a[1])
      if (!find(a[0])) {
        const t = target(p, "right")
        L[t.section].splice(t.index, 0, { id: a[0] })
      } else if (Object.keys(p).length) {
        move(a[0], p)
      }
      break
    }
    case "setBarWidget": {
      const sel = JSON.parse(a[3])
      const at = sel.index !== undefined ? { section: sel.section, index: sel.index } : find(a[0], sel.section || "")
      if (!at || !L[at.section][at.index] || idOf(L[at.section][at.index]) !== a[0]) throw new Error("setBarWidget: no " + a[0])
      if (typeof L[at.section][at.index] === "string") L[at.section][at.index] = { id: a[0] }
      L[at.section][at.index][a[1]] = JSON.parse(a[2])
      break
    }
    case "toggleBarTransparency":
      bar.transparent = !bar.transparent
      break
    default:
      throw new Error("unknown call " + c.fn)
    }
  }
  return config
}

function fixture() {
  return {
    version: 1,
    bar: {
      position: "top",
      transparent: false,
      layout: {
        left: [{ id: "omarchy.menu" }, { id: "omarchy.workspaces" }],
        center: [{ id: "omarchy.indicators", items: ["Dnd"] }, { id: "omarchy.clock", format: "HH:mm" }, { id: "omarchy.weather" }],
        right: [{ id: "omarchy.tray", pinned: ["TelegramDesktop"] }, { id: "reidenxerx.omagram" }, { id: "omarchy.audio" },
                { id: "omarchy.spacer", size: 8 }, { id: "omarchy.power" }, { id: "omarchy.spacer", size: 4 }]
      }
    }
  }
}

// Geometry as the shell lists it: in the order slots were made, a hidden widget, and a second bar's copies after it.
function geometryFor(config) {
  const out = []
  let x = 8
  const place = (section, start) => {
    x = start
    for (const e of config.bar.layout[section]) {
      const id = typeof e === "string" ? e : e.id
      const hidden = id === "reidenxerx.omagram"
      out.push({ id, section, x, y: 0, width: hidden ? 0 : 27, height: hidden ? 0 : 27, visible: !hidden })
      if (!hidden) x += 27
    }
  }
  place("right", 1200)
  place("left", 8)
  place("center", 700)
  const copies = out.map((g) => Object.assign({}, g, { x: g.x + 1920 }))
  return out.reverse().concat(copies)
}

// ---------------------------------------------------------------- tests

test("the bar is read with its places and options, bounded", () => {
  const config = fixture()
  config.bar.layout.left.push(42, {}, { id: "omarchy.clock" })
  const bar = M.readBar(config)
  eq(bar.sections.left.map((e) => e.id), ["omarchy.menu", "omarchy.workspaces", "", "", "omarchy.clock"], "odd entries keep their place")
  eq(bar.sections.center[1].options, { format: "HH:mm" })
  eq([bar.position, bar.transparent], ["top", false])
  const big = fixture()
  big.bar.layout.right = Array.from({ length: 80 }, (_, i) => ({ id: "w" + i }))
  big.bar.position = "diagonal"
  const read = M.readBar(big)
  eq([read.sections.right.length, read.position], [64, "top"])
  eq(M.readBar(null).sections, { left: [], center: [], right: [] })
})

test("live geometry is matched to entries: shuffled, hidden, repeated and a second bar", () => {
  const config = fixture()
  const bar = M.readBar(config)
  const list = M.chips(geometryFor(config), bar)
  eq(list.length, 11)
  const spacers = list.filter((c) => c.id === "omarchy.spacer")
  eq(spacers.map((c) => [c.index, c.options.size, c.instances]), [[3, 8, 2], [5, 4, 2]], "each spacer keeps its own options")
  assert.ok(spacers[0].x < spacers[1].x && spacers[1].x < 1920, "boxes from the first bar, in order along it")
  eq(M.chipByKey(list, "right:1").shown, false, "a widget taking no room is not drawn over")
  eq(M.chipByKey(list, "center:1").x, 727)
  eq(M.barOrder(list).map((c) => c.key).slice(0, 4), ["left:0", "left:1", "center:0", "center:1"])
  eq([M.stepKey(list, "left:1", 1), M.stepKey(list, "left:0", -1), M.stepKey(list, "", -1)], ["center:0", "left:0", "right:5"])
})

test("one place along the bar, within a section and over into the next", () => {
  const bar = M.readBar(fixture())
  const list = M.chips(geometryFor(fixture()), bar)
  eq(M.nudgeTarget(bar, M.chipByKey(list, "center:1"), -1), { section: "center", index: 0 })
  eq(M.nudgeTarget(bar, M.chipByKey(list, "center:0"), -1), { section: "left", index: 2 })
  eq(M.nudgeTarget(bar, M.chipByKey(list, "center:2"), 1), { section: "right", index: 0 })
  eq([M.nudgeTarget(bar, M.chipByKey(list, "left:0"), -1), M.nudgeTarget(bar, M.chipByKey(list, "right:5"), 1)], [null, null])
})

test("a move, and its undo, put the bar back exactly", () => {
  const cases = [["center:0", { section: "center", index: 2 }], ["center:2", { section: "center", index: 0 }],
                 ["right:1", { section: "left", index: 1 }], ["left:0", { section: "right", index: 99 }],
                 ["right:3", { section: "center", index: 1 }]]
  for (const [key, target] of cases) {
    const config = fixture()
    const bar = M.readBar(config)
    const chip = M.chipByKey(M.chips(geometryFor(config), bar), key)
    const ch = M.moveChange(bar, chip, target)
    simulate(config, ch.run)
    const moved = M.readBar(config)
    assert.ok(moved.sections[target.section].some((e) => e.id === chip.id), key + " arrived")
    simulate(config, ch.undo)
    eq(config, fixture(), key + " undone")
  }
  const bar = M.readBar(fixture())
  const chip = M.chipByKey(M.chips(geometryFor(fixture()), bar), "left:1")
  eq(M.moveChange(bar, chip, { section: "left", index: 1 }), null, "no move, no change")
})

test("a drop lands before or after the nearest widget, counted without the one dragged", () => {
  const config = fixture()
  const bar = M.readBar(config)
  const list = M.chips(geometryFor(config), bar)
  const clock = M.chipByKey(list, "center:1")
  eq(M.dropTarget(bar, list, M.chipByKey(list, "left:0"), { x: 700 + 27 + 27 + 20, y: 5 }, 1920), { section: "center", index: 3 })
  eq(M.dropTarget(bar, list, clock, { x: 700 + 27 * 2 + 20, y: 5 }, 1920), { section: "center", index: 2 }, "after the weather")
  eq(M.dropTarget(bar, list, clock, { x: 702, y: 5 }, 1920), { section: "center", index: 0 })
  const empty = fixture()
  empty.bar.layout.center = []
  const emptyBar = M.readBar(empty)
  const emptyList = M.chips(geometryFor(empty), emptyBar)
  eq(M.dropTarget(emptyBar, emptyList, M.chipByKey(emptyList, "left:0"), { x: 960, y: 5 }, 1920), { section: "center", index: 0 })
})

test("off the bar and back, options and place included; repeated widgets are not offered", () => {
  const config = fixture()
  const bar = M.readBar(config)
  const list = M.chips(geometryFor(config), bar)
  const tray = M.chipByKey(list, "right:0")
  const ch = M.removeChange(tray)
  simulate(config, ch.run)
  assert.ok(!M.readBar(config).sections.right.some((e) => e.id === "omarchy.tray"))
  simulate(config, ch.undo)
  eq(config, fixture())
  eq(M.removeChange(M.chipByKey(list, "right:3")), null)
})

test("a widget added where it was asked for, and taken off again", () => {
  const config = fixture()
  const bar = M.readBar(config)
  const ch = M.addChange(bar, "omarchy.media", "left", 1)
  simulate(config, ch.run)
  eq(M.readBar(config).sections.left.map((e) => e.id), ["omarchy.menu", "omarchy.media", "omarchy.workspaces"])
  simulate(config, ch.undo)
  eq(config, fixture())
  eq([M.addChange(bar, "omarchy.clock", "left", 0), M.addChange(bar, "bad id", "left", 0), M.addChange(bar, "x.y", "middle", 0)],
     [null, null, null])
})

test("an option, its undo, a new key undone to its default, and the one instance of several", () => {
  const config = fixture()
  const bar = M.readBar(config)
  const list = M.chips(geometryFor(config), bar)
  const clock = M.chipByKey(list, "center:1")
  const ch = M.optionChange(clock, "format", "HH:mm:ss")
  simulate(config, ch.run)
  eq(config.bar.layout.center[1].format, "HH:mm:ss")
  simulate(config, ch.undo)
  eq(config, fixture())
  eq(M.optionChange(clock, "format", "HH:mm"), null)
  const fresh = M.optionChange(clock, "showSeconds", true, false)
  simulate(config, fresh.run)
  simulate(config, fresh.undo)
  eq(config.bar.layout.center[1].showSeconds, false, "back to the field's default")
  const spacer = M.chipByKey(list, "right:5")
  const size = M.optionChange(spacer, "size", 12)
  simulate(config, size.run)
  eq([config.bar.layout.right[3].size, config.bar.layout.right[5].size], [8, 12], "only the instance chosen")
})

test("transparency and position, each undone", () => {
  const config = fixture()
  const bar = M.readBar(config)
  const t = M.transparencyChange()
  simulate(config, t.run)
  eq(config.bar.transparent, true)
  simulate(config, t.undo)
  const p = M.positionChange(bar, "bottom")
  simulate(config, p.run)
  eq(config.bar.position, "bottom")
  simulate(config, p.undo)
  eq(config, fixture())
  eq([M.positionChange(bar, "top"), M.positionChange(bar, "sideways")], [null, null])
})

test("undo and redo walk the history, and a new change forgets what was undone", () => {
  let h = M.emptyHistory()
  const a = { label: "a", run: [1], undo: [2] }
  const b = { label: "b", run: [3], undo: [4] }
  h = M.record(M.record(h, a), b)
  let u = M.undoStep(h)
  eq([u.calls, u.change.label], [[4], "b"])
  const r = M.redoStep(u.history)
  eq(r.calls, [3])
  u = M.undoStep(r.history)
  h = M.record(u.history, { label: "c", run: [5], undo: [6] })
  eq([h.done.length, h.undone.length, M.redoStep(h)], [2, 0, null])
  let many = M.emptyHistory()
  for (let i = 0; i < 130; i++) many = M.record(many, { label: String(i), run: [], undo: [] })
  eq([many.done.length, many.done[0].label], [100, "30"])
  eq(M.undoStep(M.emptyHistory()), null)
})

test("a layout is put on through the shell's calls, and the bar then wears it", () => {
  const config = fixture()
  const target = {
    name: "Focus",
    position: "bottom",
    transparent: true,
    sections: {
      left: [{ id: "omarchy.clock", options: { format: "HH" } }, { id: "omarchy.menu", options: {} }, { id: "omarchy.media", options: {} }],
      center: [{ id: "omarchy.workspaces", options: {} }],
      right: [{ id: "omarchy.power", options: {} }, { id: "omarchy.tray", options: { pinned: [] } }, { id: "gone.widget", options: {} },
              { id: "omarchy.spacer", options: {} }]
    }
  }
  const installed = (id) => id !== "gone.widget"
  const calls = M.planLayout(M.readBar(config), target, installed)
  simulate(config, calls)
  const after = M.readBar(config)
  eq(after.sections.left.map((e) => e.id), ["omarchy.clock", "omarchy.menu", "omarchy.media"])
  eq(after.sections.center.map((e) => e.id), ["omarchy.workspaces"])
  eq(after.sections.right.map((e) => e.id), ["omarchy.power", "omarchy.tray", "omarchy.spacer", "omarchy.spacer"],
     "spacers, on the bar twice, stay; a widget no longer installed is not asked for")
  eq([after.sections.left[0].options.format, after.sections.right[1].options.pinned, after.position, after.transparent],
     ["HH", [], "bottom", true])
  eq(M.planLayout(after, target, installed).length, 0, "nothing left to do")
  assert.ok(M.wears(M.readBar(fixture()), M.snapshot(M.readBar(fixture()), "Now")))
  eq(M.planLayout(M.readBar(fixture()), { nonsense: true }, installed), [])
})

test("rules: conditions, the first that holds wins, and how they read", () => {
  const settings = M.readSettings({
    layouts: [{ name: "Base", sections: {} }, { name: "Battery", sections: {} }, { name: "Code", sections: {} }],
    baseLayout: "Base",
    rules: [{ layout: "Code", when: { app: "zed" } }, { layout: "Battery", when: { power: "battery", screens: "laptop" } },
            { layout: "Battery", when: {} }, { layout: "Nope", when: { power: "ac" } }, { layout: "Code", enabled: false, when: { fullscreen: true } }]
  })
  eq(settings.rules.length, 3, "a rule with no condition or an unknown layout is dropped")
  eq(M.chooseLayout(settings, { onBattery: true, externalScreen: false, appClass: "dev.zed.Zed" }), "Code")
  eq(M.chooseLayout(settings, { onBattery: true, externalScreen: false, appClass: "kitty" }), "Battery")
  eq(M.chooseLayout(settings, { onBattery: true, externalScreen: true }), "Base")
  eq(M.chooseLayout(settings, { fullscreen: true }), "Base", "a rule that is off does not count")
  eq(M.describeRule(settings.rules[1]), "on battery, on the laptop screen alone")
})

test("settings are bounded and checked, and layouts are kept by name", () => {
  const raw = { layouts: Array.from({ length: 30 }, (_, i) => ({ name: "L" + (i % 26), sections: { left: [{ id: "a.b" }] } })),
                baseLayout: "missing", shortcut: "SUPER + ALT + B; rm", auto: "yes" }
  const s = M.readSettings(raw)
  eq([s.layouts.length, s.baseLayout, s.shortcut, s.auto], [24, "", "SUPER + ALT + B", false])
  eq(M.readSettings({ shortcut: "" }).shortcut, "", "no shortcut is a choice")
  const one = M.withLayout(M.readSettings({}), { name: "Work", position: "top", transparent: false, sections: { left: [], center: [], right: [] } })
  const two = M.withLayout(one, Object.assign({}, one.layouts[0], { transparent: true }))
  eq([two.layouts.length, two.layouts[0].transparent], [1, true])
  eq(M.freshName(two, "Work"), "Work 2")
  const gone = M.withoutLayout(Object.assign({}, two, { baseLayout: "Work", rules: [{ layout: "Work", enabled: true, when: { power: "ac" } }] }), "Work")
  eq([gone.layouts.length, gone.rules.length, gone.baseLayout], [0, 0, ""])
})

test("the gallery lists bar widgets not on the bar, found by what they are", () => {
  const plugins = [{ id: "omarchy.media", name: "Media", kinds: ["service", "bar-widget"], enabled: false, firstParty: true },
                   { id: "omarchy.clock", name: "Clock", kinds: ["bar-widget"], enabled: true },
                   { id: "some.panel", name: "Panel", kinds: ["panel"], enabled: false },
                   { id: "x.weather", name: "", kinds: ["bar-widget"], enabled: false }]
  const index = M.catalogIndex([{ id: "omarchy.media", barWidget: { displayName: "Media", description: "Now playing", category: "Media" } },
                                { id: "x.weather", description: "Rain or shine", barWidget: { category: "Weather" } }])
  eq(M.gallery(plugins, index, "").map((w) => w.id), ["omarchy.media", "x.weather"])
  eq(M.gallery(plugins, index, "rain").map((w) => w.name), ["x.weather"])
  eq(M.gallery(plugins, index, "PLAYING").length, 1)
  eq(M.widgetName(index, "omarchy.media"), "Media")
})

test("settings forms from a manifest's schema, and values made the right type", () => {
  const meta = {
    defaults: { keepDays: 30, badge: "Dot" },
    schema: [{ key: "badge", type: "enum", label: "Mark", options: ["Dot", "Count"] }, { key: "keepDays", type: "integer", min: 1, max: 365 },
             { key: "showBody", type: "boolean", defaultValue: true }, { key: "items", type: "multiselect", options: ["Dnd", "Idle"] },
             { key: "note", type: "string" }, { key: "id", type: "string" }, { key: "weird", type: "colour" }, "junk"]
  }
  const fields = M.formFields(meta, { keepDays: 7 })
  eq(fields.map((f) => [f.key, f.type, f.value]), [["badge", "enum", "Dot"], ["keepDays", "integer", 7], ["showBody", "boolean", true],
                                                  ["items", "multiselect", undefined], ["note", "string", undefined], ["weird", "unknown", undefined]])
  const [badge, days, body, items, note, weird] = fields
  eq([M.coerce(badge, "Count"), M.coerce(badge, "Stars")], ["Count", undefined])
  eq([M.coerce(days, "1000"), M.coerce(days, "4.6"), M.coerce(days, ""), M.coerce(days, "x")], [365, 5, undefined, undefined])
  eq([M.coerce(body, "true"), M.coerce(body, false)], [true, false])
  eq(M.coerce(items, ["Dnd", "Nope"]), ["Dnd"])
  eq([M.coerce(note, "hi"), M.coerce(note, 5), M.coerce(weird, "red")], ["hi", undefined, undefined])
})

test("the shortcut's Hyprland bind, only for combinations Barber can write safely", () => {
  const cmd = "/usr/bin/omarchy-shell shell toggle reidenxerx.barber {}"
  const statement = M.bindStatement("SUPER + ALT + B", cmd)
  assert.ok(statement.startsWith("hl.bind(") && statement.includes("SUPER + ALT + B") && statement.includes(cmd))
  eq([M.bindStatement("SUPER + ALT + B)", cmd), M.bindStatement("super + b", cmd), M.bindStatement("SUPER + B", "x\" os.exit()")], ["", "", ""])
})

const NL = String.fromCharCode(10)
const BS = String.fromCharCode(92)
const Q = String.fromCharCode(34)

test("built-in forms: the spacer, the clock for the way the bar runs, the weather", () => {
  const horizontal = M.formFieldsFor({ settingsForm: "clockSettings" }, { format: "HH:mm" }, false)
  eq(horizontal.map((f) => [f.key, f.value]), [["format", "HH:mm"], ["formatAlt", "d MMMM 'W'ww yyyy"]])
  const vertical = M.formFieldsFor({ settingsForm: "clockSettings" }, {}, true)
  eq(vertical.map((f) => [f.key, f.multiline]), [["verticalFormat", true], ["verticalFormatAlt", true]])
  eq(M.shownText(vertical[0], vertical[0].value), "HH" + BS + "n—" + BS + "nmm")
  eq(M.typedText(vertical[0], "HH" + BS + "nmm"), "HH" + NL + "mm")
  eq(M.typedText(horizontal[0], "a" + BS + "nb"), "a" + BS + "nb", "only multi-line fields read the escape")
  eq(M.formFieldsFor({ settingsForm: "spacerSettings" }, { size: 8 }, false).map((f) => [f.key, f.value, f.fallback, f.max]),
     [["size", 8, 12, 256]])
  eq(M.formFieldsFor({ settingsForm: "weatherSettings" }, {}, false)[0].fallback, 15)
  eq(M.formFieldsFor({ settingsForm: "constructor", schema: [{ key: "a", type: "boolean" }] }, {}, false).map((f) => f.key), ["a"],
     "a form name that is not a built-in form falls back to the schema")
})

test("widget manifests: read only from plugin folders, and bounded", () => {
  const home = "/home/someone"
  eq([M.manifestPathAllowed("/usr/share/omarchy/shell/plugins/agents/manifest.json", home),
      M.manifestPathAllowed("/usr/share/omarchy/shell/plugins/panels/clock/manifest.json", home),
      M.manifestPathAllowed("/home/someone/.config/omarchy/plugins/x.y/manifest.json", home + "/"),
      M.manifestPathAllowed("/home/someone/.config/omarchy/plugins/../../.ssh/manifest.json", home),
      M.manifestPathAllowed("/etc/manifest.json", home),
      M.manifestPathAllowed("/usr/share/omarchy/shell/plugins/agents/other.json", home),
      M.manifestPathAllowed("/usr/share/omarchy/shell/plugins//manifest.json", home),
      M.manifestPathAllowed("relative/manifest.json", home),
      M.manifestPathAllowed("/home/someone/.config/omarchy/plugins/x/manifest.json", ""),
      M.manifestPathAllowed(42, home)],
     [true, true, true, false, false, false, false, false, false, false])
  const meta = M.readWidgetManifest({ barWidget: { displayName: "Agents", settingsForm: 7, defaultSection: "middle",
                                                   defaults: { id: "x", every: 5 },
                                                   schema: Array.from({ length: 50 }, (_, i) => ({ key: "k" + i, type: "boolean" })) } })
  eq([meta.displayName, meta.settingsForm, meta.defaultSection, meta.defaults, meta.schema.length], ["Agents", "", "", { every: 5 }, 40])
  eq(M.readWidgetManifest({ name: "no widget" }), {})
})

test("a widget whose plugin would stop with it stays on the bar through layouts", () => {
  const plugins = [{ id: "reidenxerx.omagram", kinds: ["bar-widget", "service", "panel"], firstParty: false },
                   { id: "omarchy.menu", kinds: ["bar-widget", "menu"], firstParty: true },
                   { id: "x.clock", kinds: ["bar-widget"], firstParty: false }]
  eq(plugins.map((p) => M.stopsPlugin(p)), [true, false, false])
  eq([M.stopsPlugin(null), M.widgetInstalled(plugins, "x.clock"), M.widgetInstalled(plugins, "nope.widget")], [false, true, false])
  const keep = (id) => M.stopsPlugin(M.pluginById(plugins, id))
  const config = fixture()
  const target = M.snapshot(M.readBar(config), "Lean")
  target.sections.right = target.sections.right.filter((e) => e.id !== "reidenxerx.omagram" && e.id !== "omarchy.audio")
  simulate(config, M.planLayout(M.readBar(config), target, null, keep))
  const after = M.readBar(config)
  eq(after.sections.right.map((e) => e.id), ["omarchy.tray", "omarchy.spacer", "omarchy.power", "omarchy.spacer", "reidenxerx.omagram"])
  eq([after.sections.right[1].options.size, after.sections.right[3].options.size], [8, 4])
  assert.ok(M.wears(after, target, null, keep), "worn, with the widget that has to stay")
  assert.ok(!M.wears(after, target, null, null), "without keep it would come off")
})

test("screens: a laptop panel alone, or a monitor plugged in", () => {
  eq([M.hasExternalScreen(["eDP-1"]), M.hasExternalScreen(["eDP-1", "DP-2"]), M.hasExternalScreen(["HDMI-A-1"]),
      M.hasExternalScreen(["HEADLESS-2", "eDP-1"]), M.hasExternalScreen([]), M.hasExternalScreen(null)],
     [false, true, true, false, false, false])
})

test("the shortcut: free, Barber's own, or taken; and taken back only by name", () => {
  eq(M.comboParts("SUPER + ALT + B"), { mask: 72, key: "B" })
  eq(M.comboParts("SUPER + B;"), null)
  assert.ok(M.SHORTCUTS.every((c) => M.comboParts(c) !== null), "every offered shortcut is one Barber can write")
  const ours = { modmask: 72, key: "B", submap: "", description: "Barber: edit the bar" }
  const other = { modmask: 72, key: "b", submap: "", description: "Something else" }
  const inSubmap = { modmask: 72, key: "B", submap: "resize", description: "Resize" }
  eq([M.bindState([], "SUPER + ALT + B"), M.bindState([ours], "SUPER + ALT + B"), M.bindState([ours, other], "SUPER + ALT + B"),
      M.bindState([inSubmap], "SUPER + ALT + B"), M.bindState([other], "SUPER + CTRL + B"), M.bindState([], ""), M.bindState([], "B")],
     ["free", "ours", "taken", "free", "free", "off", "invalid"])
  eq([M.unbindStatement("SUPER + ALT + B"), M.unbindStatement("SUPER + ALT + B" + Q + ")")],
     ["hl.unbind(" + Q + "SUPER + ALT + B" + Q + ")", ""])
  eq(M.bindStatement("SUPER + ALT + B", "/usr/bin/x '{}'"),
     "hl.bind(" + Q + "SUPER + ALT + B" + Q + ", hl.dsp.exec_cmd(" + Q + "/usr/bin/x '{}'" + Q + "), { description = " + Q +
     "Barber: edit the bar" + Q + " })")
  eq([M.bindStatement("SUPER + B", "a" + BS + "b"), M.bindStatement("SUPER + B", "a" + NL + "b")], ["", ""])
})

test("the drop marker sits where the widget will land", () => {
  const config = fixture()
  const bar = M.readBar(config)
  const list = M.chips(geometryFor(config), bar)
  const clock = M.chipByKey(list, "center:1")
  eq(M.dropMarker(bar, list, clock, { section: "center", index: 2 }, 1920), 781, "after the weather")
  eq(M.dropMarker(bar, list, clock, { section: "center", index: 0 }, 1920), 700, "before the indicators")
  eq(M.dropMarker(bar, list, M.chipByKey(list, "left:0"), { section: "center", index: 1 }, 1920), 727, "before the clock")
  const empty = fixture()
  empty.bar.layout.center = []
  const emptyBar = M.readBar(empty)
  const emptyList = M.chips(geometryFor(empty), emptyBar)
  eq(M.dropMarker(emptyBar, emptyList, M.chipByKey(emptyList, "left:0"), { section: "center", index: 0 }, 1920), 960)
})

test("undo is replayed only on the bar it was recorded on", () => {
  const config = fixture()
  const before = M.barSignature(M.readBar(config))
  const ch = M.transparencyChange()
  simulate(config, ch.run)
  assert.notStrictEqual(M.barSignature(M.readBar(config)), before)
  simulate(config, ch.undo)
  eq(M.barSignature(M.readBar(config)), before)
})

test("rules are added for layouts that exist, switched off and on, removed; settings survive a round trip", () => {
  let s = M.readSettings({ layouts: [{ name: "Work", sections: {} }] })
  s = M.withRule(s, { layout: "Work", when: { screens: "external", power: "" } })
  s = M.withRule(s, { layout: "Missing", when: { power: "ac" } })
  s = M.withRule(s, { layout: "Work", when: {} })
  eq(s.rules, [{ layout: "Work", enabled: true, when: { screens: "external" } }])
  s = M.withRuleEnabled(s, 0, false)
  eq(s.rules[0].enabled, false)
  eq(M.withRuleEnabled(s, 5, true).rules, s.rules)
  const full = Object.assign({}, s, { auto: true, baseLayout: "Work", shortcut: "SUPER + CTRL + B" })
  eq(M.readSettings(Object.assign({ id: "reidenxerx.barber" }, M.settingsPayload(full))), full)
  eq([M.withoutRule(s, 0).rules.length, M.withoutRule(s, 3).rules.length], [0, 1])
  const config = { plugins: [{ id: "a.b" }, { id: "reidenxerx.barber", auto: true }] }
  eq([M.ownEntry(config, "reidenxerx.barber").auto, M.ownEntry({}, "reidenxerx.barber")], [true, null])
})

test("a widget from the gallery goes after the widget chosen, or to its own side", () => {
  const bar = M.readBar(fixture())
  const list = M.chips(geometryFor(fixture()), bar)
  eq(M.addPlace(bar, M.chipByKey(list, "center:1"), {}), { section: "center", index: 2 })
  eq(M.addPlace(bar, null, { defaultSection: "right" }), { section: "right", index: 6 })
  eq(M.addPlace(bar, null, {}), { section: "center", index: 3 })
})

test("calls become argument lists, and their answers are read", () => {
  const tools = { shell: "/usr/bin/omarchy-shell", bar: "/usr/bin/omarchy-bar" }
  eq(M.argv(M.call("moveBarWidget", "a.b", "{}"), tools), ["/usr/bin/omarchy-shell", "shell", "moveBarWidget", "a.b", "{}"])
  eq(M.argv({ tool: "bar", fn: "", args: ["position", "left"] }, tools), ["/usr/bin/omarchy-bar", "position", "left"])
  eq(M.argv({ tool: "rm", args: ["-rf"] }, tools), [])
  const shellCall = M.call("setPluginEnabled", "a.b", "false")
  eq([M.callSucceeded(shellCall, 0, "ok" + NL), M.callSucceeded(shellCall, 0, "unknown"), M.callSucceeded(shellCall, 1, "ok"),
      M.callSucceeded({ tool: "bar" }, 0, "")], [true, false, false, true])
  eq([M.parseOutput("[1]"), M.parseOutput("nope"), M.parseOutput(42)], [[1], null, null])
})

test("a pick follows its widget when places shift: moves, undo, repeated widgets", () => {
  const config = fixture()
  const before = M.chips(geometryFor(config), M.readBar(config))
  const weather = M.chipByKey(before, "center:2")
  const second = M.chipByKey(before, "right:5")
  eq([M.chipInstance(before, weather), M.chipInstance(before, second), M.chipInstance(before, null)], [0, 1, 0])
  const ch = M.moveChange(M.readBar(config), weather, { section: "left", index: 0 })
  simulate(config, ch.run)
  const after = M.chips(geometryFor(config), M.readBar(config))
  eq(M.chipOfInstance(after, "omarchy.weather", 0).key, "left:0", "the pick moved with the widget")
  eq(M.chipOfInstance(after, "omarchy.spacer", 1).options.size, 4, "the second spacer is still the second")
  simulate(config, ch.undo)
  eq(M.chipOfInstance(M.chips(geometryFor(config), M.readBar(config)), "omarchy.weather", 0).key, "center:2", "and back with the undo")
  eq([M.chipOfInstance(after, "omarchy.spacer", 2), M.chipOfInstance(after, "", 0)], [null, null])
})

test("what the rules see, in words, and a layout in a line", () => {
  eq(M.describeContext({ onBattery: true, externalScreen: false, fullscreen: true, appClass: "kitty" }),
     "On battery · laptop screen alone · fullscreen · kitty")
  eq(M.describeContext({}), "Plugged in · laptop screen alone")
  eq(M.summarizeLayout(M.snapshot(M.readBar(fixture()), "Now")), "11 widgets · top")
})

console.log(passed + " passed, " + failed + " failed")
process.exit(failed ? 1 : 0)
