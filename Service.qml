import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "Toggler.js" as Toggler

// Hot Apps service.
//
// Owns the two hotkeys (SUPER + SHIFT + comma / period) and the launch-or-
// toggle behavior for whatever app the user assigns to each slot. The keys
// are registered at runtime through Hyprland's Lua API and re-registered on
// every `configreloaded`, so this plugin needs no edits to bindings.lua.
//
// Slot settings live inline on this plugin's entry in shell.json:
//   { "id": "syndicalt.hot-apps",
//     "comma": { "desktopId": "discord", "special": "comma", "preload": true },
//     "period": { "desktopId": "org.mozilla.firefox" } }
//
// IPC (omarchy-shell hot-apps <method> ...):
//   toggle <comma|period>   run the hotkey action
//   set <slot> <desktopId>  assign an app to the slot
//   clear <slot>            unassign
//   list                    JSON view of both slots
//   apps [query]            JSON search of installed desktop entries
//   config <slot>           open the config picker for the slot
Item {
  id: service

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "syndicalt.hot-apps"
  readonly property string configPath: home + "/.config/omarchy/shell.json"

  property var settings: ({})
  property var pendingLaunch: ({})   // { slot, at } while waiting to learn a class
  property string pendingToggle: ""  // slot awaiting a fresh client list
  property var pendingTitleMoves: [] // generic terminal apps launched outside the hotkey
  property var lastRules: ({})       // slot -> class we have a window rule installed for
  property var dispatchQueue: []
  property var evalQueue: []
  property var persistQueue: []
  property int ruleVersion: 0

  readonly property int learnMs: 3500

  // ------------------------------------------------------------- settings

  function parseSettings(raw) {
    var cfg = null
    try { cfg = JSON.parse(raw || "{}") } catch (e) { return ({}) }
    var entries = Array.isArray(cfg.plugins) ? cfg.plugins : []
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      if (e && String(e.id || "") === service.pluginId) {
        var parsed = Toggler.slotSettings(e)
        var prev = service.settings
        for (var k in parsed) {
          if (prev[k] && !parsed[k].knownClass) {
            // shell.json does not carry knownClass until we persist it;
            // keep what we learned this session rather than dropping it.
            parsed[k].knownClass = prev[k].knownClass
          }
        }
        return parsed
      }
    }
    return Toggler.slotSettings({})
  }

  function applySettings(next) {
    var a = JSON.stringify(next)
    var b = JSON.stringify(service.settings)
    if (a === b) return
    var prev = service.settings
    for (var slot in next) {
      if (prev[slot] && prev[slot].desktopId !== next[slot].desktopId)
        service.disableRule(slot)
    }
    service.settings = next
    service.registerBinds()
    service.lastRules = ({})
    for (var ruleSlot in next)
      if (next[ruleSlot].knownClass) service.applyRule(ruleSlot, next[ruleSlot].knownClass)
    // Preload newly-assigned (or newly-known) apps so `preload: true` behaves
    // like the old autostart lines did.
    for (var slot in next) {
      var s = next[slot]
      if (s.preload && !service.findWindow(slot)) {
        var wasKnown = prev[slot] && (prev[slot].knownClass || prev[slot].desktopId)
        if (wasKnown) service.launchSlot(slot, true)
      }
    }
  }

  function settingsFor(slot) {
    return Toggler.slotSettings({ [slot]: service.settings[slot] })[slot]
  }

  // -------------------------------------------------------- Hyprland calls

  // Mutations that reach a Hyprland dispatcher (window.move, workspace
  // toggle, exec_cmd) must go through `hyprctl dispatch` — this Hyprland's
  // Lua shim applies `hl.dispatch` there, while `hyprctl eval "hl.dsp...."`
  // returns "ok" without actually executing window moves.
  function runDispatch(lua) {
    service.dispatchQueue = service.dispatchQueue.concat([lua])
    service.runNextDispatch()
  }

  function runNextDispatch() {
    if (dispatchProc.running || service.dispatchQueue.length === 0) return
    var next = service.dispatchQueue[0]
    service.dispatchQueue = service.dispatchQueue.slice(1)
    dispatchProc.command = ["hyprctl", "dispatch", next]
    dispatchProc.running = true
  }

  // Config-table helpers (hl.bind / hl.unbind / hl.window_rule) must go
  // through `hyprctl eval`: they are not dispatchers, so `hl.dispatch`'s
  // return wrapping rejects them after the side effect, or on unbind never
  // applies at all.
  function runEval(lua) {
    service.evalQueue = service.evalQueue.concat([lua])
    service.runNextEval()
  }

  function runNextEval() {
    if (evalProc.running || service.evalQueue.length === 0) return
    var next = service.evalQueue[0]
    service.evalQueue = service.evalQueue.slice(1)
    evalProc.command = ["hyprctl", "eval", next]
    evalProc.running = true
  }

  function luaQuote(value) {
    return '"' + String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
  }

  // Persist the plugin entry via the shell API. updateEntryInline replaces
  // the entry object; the shell preserves `id` and we must not drop fields.
  // Always refresh the menu row on top of the config write.
  function persistSettings() {
    var snapshot = JSON.stringify({
      comma: service.settings.comma,
      period: service.settings.period
    })
    service.persistQueue = service.persistQueue.concat([snapshot])
    service.persistNextSettings()
    service.syncMenu()
  }

  function persistNextSettings() {
    if (settingsProc.running || service.persistQueue.length === 0) return
    var snapshot = service.persistQueue[0]
    service.persistQueue = service.persistQueue.slice(1)
    var script = service.home + "/.config/omarchy/plugins/"
      + service.pluginId + "/bin/omarchy-hot-apps-persist"
    settingsProc.command = ["bash", script, service.pluginId, snapshot]
    settingsProc.running = true
  }

  // Update the Omarchy menu extension rows so each slot shows the assigned
  // app. The menu hot-reloads the extension file, so the row label/icon
  // reflect the assignment without a shell restart. Path is derived from
  // the plugin install directory (deterministic, no PATH dependence).
  function syncMenu() {
    // Small delay so the just-persisted settings are visible to the helper
    // before it reads current assignment state.
    menuSyncTimer.restart()
  }

  Timer {
    id: menuSyncTimer
    interval: 300
    repeat: false
    onTriggered: {
      var script = service.home + "/.config/omarchy/plugins/"
        + service.pluginId + "/bin/omarchy-hot-apps-menu"
      menuSyncProc.command = ["bash", script]
      menuSyncProc.running = true
    }
  }

  Process {
    id: menuSyncProc
    command: []
    stdout: StdioCollector {
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err && err !== "0" && err !== "ok") console.warn("hot-apps menu sync:", err)
      }
    }
  }

  Process {
    id: settingsProc
    command: []
    stdout: StdioCollector {
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err && err !== "ok") console.warn("hot-apps settings persist:", err)
      }
    }
    stderr: StdioCollector {
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err) console.warn("hot-apps settings persist:", err)
      }
    }
    onExited: service.persistNextSettings()
  }

  function registerBinds() {
    var lua = ""
    var slots = Toggler.slotKeys()
    for (var i = 0; i < slots.length; i++) {
      var slot = slots[i]
      var combo = Toggler.defaultCombo(slot)
      var desc = "Hot Apps: " + (slot === "comma" ? "Slot 1 (…)" : "Slot 2 (…)")
      lua += "hl.unbind(" + luaQuote(combo) + ");"
      lua += "hl.bind(" + luaQuote(combo) + ", hl.dsp.exec_cmd("
        + luaQuote("omarchy-shell hot-apps toggle " + slot) + "), { description = "
        + luaQuote(desc) + " });"
    }
    service.runEval(lua)
  }

  function unbindAll() {
    var lua = ""
    var slots = Toggler.slotKeys()
    for (var i = 0; i < slots.length; i++)
      lua += "hl.unbind(" + luaQuote(Toggler.defaultCombo(slots[i])) + ");"
    service.runEval(lua)
  }

  // Install the floating/centered/silent window rule for a slot's class so the
  // next launch of that app lands on its special workspace, exactly like the
  // old bindings.lua/hyprland.lua pair did.
  function applyRule(slot, classPattern) {
    if (!classPattern) return
    // Terminal applications inherit the terminal emulator's class. A class
    // rule here would move every foot/kitty window, including unrelated apps.
    if (service.isTerminalClass(classPattern)) return
    var s = service.settingsFor(slot)
    var special = s.special || slot
    var ruleName = "hot-apps-" + slot + "-" + (++service.ruleVersion)
    var lua = "_G.__hotAppsRules = _G.__hotAppsRules or {}; "
      + "local old = _G.__hotAppsRules[" + luaQuote(slot) + "]; "
      + "if old then old:set_enabled(false) end; "
      + "_G.__hotAppsRules[" + luaQuote(slot) + "] = hl.window_rule({ name = "
      + luaQuote(ruleName) + ", match = { class = " + luaQuote(classPattern) + " }, "
      + "workspace = " + luaQuote("special:" + special + " silent") + ", "
      + "float = true, center = true, no_initial_focus = true, "
      + "size = { \"monitor_w * 0.98\", \"monitor_h * 0.85\" } })"
    service.lastRules[slot] = classPattern
    service.runEval(lua)
  }

  function disableRule(slot) {
    var lua = "if _G.__hotAppsRules and _G.__hotAppsRules[" + luaQuote(slot) + "] then "
      + "_G.__hotAppsRules[" + luaQuote(slot) + "]:set_enabled(false); "
      + "_G.__hotAppsRules[" + luaQuote(slot) + "] = nil end"
    service.runEval(lua)
    var next = ({})
    for (var key in service.lastRules) if (key !== slot) next[key] = service.lastRules[key]
    service.lastRules = next
  }

  function reapplyRules() {
    for (var slot in service.lastRules) service.applyRule(slot, service.lastRules[slot])
  }

  // -------------------------------------------------------------- matching

  function escapeRegex(value) {
    return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  }

  function titleMatchesDesktopId(title, desktopId) {
    var value = String(title || "").toLowerCase()
    var id = String(desktopId || "").toLowerCase()
    return !!id && (value === id || value.endsWith(" | " + id)
      || value.endsWith(" - " + id) || value.endsWith(" — " + id))
  }

  function findWindow(slot) {
    if (service.clients.length === 0) return null
    var s = service.settingsFor(slot)
    if (!s.knownClass && !s.desktopId) return null
    var needle = s.knownClass || Toggler.normalizeDesktopId(s.desktopId)
    var re = new RegExp(service.escapeRegex(needle), "i")
    var lower = needle.toLowerCase()
    var desktopId = Toggler.normalizeDesktopId(s.desktopId).toLowerCase()
    var i, c, title
    // Terminal=true desktop entries appear as the terminal's class (for
    // Cliamp, `foot`) while the running app is identified by its title.
    // Prefer an exact title match so unrelated terminal windows are ignored.
    if (desktopId) {
      for (i = 0; i < service.clients.length; i++) {
        c = service.clients[i]
        title = String(c.title || "")
        if (service.titleMatchesDesktopId(title, desktopId)) return c
      }
    }
    if (service.isTerminalClass(s.knownClass)) return null
    // Exact class match wins over the loose pattern so a sibling app that
    // merely contains the id (code vs code-oss) is never picked when both run.
    // A shared terminal class is ambiguous; don't toggle an arbitrary shell.
    var exactClass = null
    var exactClassCount = 0
    for (i = 0; i < service.clients.length; i++) {
      c = service.clients[i]
      if (typeof c.class === "string" && c.class.toLowerCase() === lower) {
        exactClass = c
        exactClassCount++
      }
    }
    if (exactClassCount === 1) return exactClass
    if (exactClassCount > 1) return null
    for (i = 0; i < service.clients.length; i++) {
      c = service.clients[i]
      if (typeof c.class === "string" && re.test(c.class)) return c
    }
    return null
  }

  // Some desktop launchers (Docker Desktop and several small GUI apps) use a
  // window class that bears no relation to the desktop entry id. During a
  // cold launch, identify the new Hyprland client by comparing addresses with
  // the client list captured immediately before launch.
  function findPendingWindow(pending) {
    var matched = service.findWindow(pending.slot)
    if (matched) return matched
    var before = pending.existingAddresses || ({})
    var desktopId = service.settingsFor(pending.slot).desktopId.toLowerCase()
    for (var i = service.clients.length - 1; i >= 0; i--) {
      var c = service.clients[i]
      if (!c || !c.address || before[String(c.address)]) continue
      if (service.isTerminalClass(c.class)) {
        if (service.titleMatchesDesktopId(c.title, desktopId)) return c
        continue
      }
      return c
    }
    return null
  }

  function isTerminalClass(className) {
    return /^(foot|footclient|kitty|alacritty|wezterm|xterm|urxvt|st|gnome-terminal|konsole)$/i
      .test(String(className || ""))
  }

  // ------------------------------------------------------------ launch flow

  function specialVisible(special) {
    for (var i = 0; i < service.monitors.length; i++) {
      var sw = service.monitors[i].specialWorkspace || {}
      if (String(sw.name || "") === "special:" + special) return true
    }
    return false
  }

  function moveToSpecial(address, slot) {
    var s = service.settingsFor(slot)
    var special = s.special || slot
    service.runDispatch("hl.dsp.window.move({ workspace = " + luaQuote("special:" + special)
      + ", window = " + luaQuote("address:" + address) + ", follow = false })")
    service.runDispatch("hl.dsp.window.float({ window = " + luaQuote("address:" + address) + " })")
    service.runDispatch("hl.dsp.window.center({ window = " + luaQuote("address:" + address) + " })")
  }

  function queueAssignedWindowMove(address, slot) {
    if (address.indexOf("0x") !== 0) address = "0x" + address
    var pending = service.pendingTitleMoves.slice()
    for (var i = 0; i < pending.length; i++)
      if (pending[i].address === address && pending[i].slot === slot) return
    pending.push({ address: address, slot: slot })
    service.pendingTitleMoves = pending
    service.refreshState()
  }

  function onWindowTitleEvent(data) {
    var value = String(data || "")
    var comma = value.indexOf(",")
    if (comma <= 0) return
    var address = value.slice(0, comma).trim()
    var title = value.slice(comma + 1).trim().toLowerCase()
    var slots = Toggler.slotKeys()
    for (var i = 0; i < slots.length; i++) {
      var slot = slots[i]
      var s = service.settingsFor(slot)
      if (!s.desktopId || !service.titleMatchesDesktopId(title, s.desktopId)) continue
      service.queueAssignedWindowMove(address, slot)
    }
  }

  function onOpenWindowEvent(data) {
    var fields = String(data || "").split(",")
    if (fields.length < 3) return
    var address = fields[0].trim()
    var className = fields[2].trim().toLowerCase()
    var title = fields.length > 3 ? fields.slice(3).join(",").trim().toLowerCase() : ""
    var slots = Toggler.slotKeys()
    for (var i = 0; i < slots.length; i++) {
      var slot = slots[i]
      var id = service.settingsFor(slot).desktopId.toLowerCase()
      if (id && (service.titleMatchesDesktopId(title, id)
        || className === id || className.indexOf(id) !== -1))
        service.queueAssignedWindowMove(address, slot)
    }
  }

  // Called by the IPC handler; defers until a fresh client list is loaded so
  // findWindow() never races the async state refresh.
  function toggleSlot(slot) {
    if (!Toggler.slotInfo(slot)) return
    service.pendingToggle = slot
    service.refreshState()
  }

  // Runs after the state collector lands fresh clients/monitors.
  function toggleWithState(slot) {
    var s = service.settingsFor(slot)
    var special = s.special || slot
    if (!s.desktopId) {
      service.notify("Hot Apps: slot " + slot + " has no app assigned")
      service.openConfig(slot)
      return
    }
    var win = service.findWindow(slot)
    if (win) {
      // Learn the real class whenever we touch a window, so the next launch
      // can use the window-rule fast path.
      if (!s.knownClass || s.knownClass !== String(win.class || "")) {
        var next = Toggler.mergeSettings(service.settings, slot, {
          knownClass: String(win.class || "")
        })
        service.settings = next
        service.persistSettings()
        service.applyRule(slot, String(win.class || ""))
      }
      var onSpecial = String(win.workspace && win.workspace.name || "") === "special:" + special
      if (onSpecial) {
        // Window already lives on its special workspace: flip visibility.
        service.runDispatch("hl.dsp.workspace.toggle_special(" + luaQuote(special) + ")")
      } else {
        service.runDispatch("hl.dsp.window.move({ workspace = " + luaQuote("special:" + special)
          + ", window = " + luaQuote("address:" + win.address) + ", follow = false })")
        // Moving creates the special workspace if necessary. Reveal it only
        // after the move so the first keypress both initializes and summons.
        if (!service.specialVisible(special))
          service.runDispatch("hl.dsp.workspace.toggle_special(" + luaQuote(special) + ")")
      }
      service.runDispatch("hl.dsp.window.float({ window = " + luaQuote("address:" + win.address) + " })")
      service.runDispatch("hl.dsp.window.center({ window = " + luaQuote("address:" + win.address) + " })")
      return
    }
    // Cold start. If we already learned the window class (previous launch),
    // install the rule so the window lands on special:<name> silent directly.
    service.pendingLaunch = {
      slot: slot, at: Date.now(), reveal: true,
      existingAddresses: service.clientAddresses()
    }
    if (service.guessClass(slot)) service.applyRule(slot, service.guessClass(slot))
    service.runDispatch("hl.dsp.exec_cmd(" + luaQuote(service.launchCommand(s)) + ")")
    // Poll for the window (some apps open in an existing browser session and
    // never emit a usable openwindow event), then learn + move it.
    learnTimer.restart()
  }

  function launchCommand(s) {
    return Toggler.launchCommand(service.resolveDesktopId(s.desktopId))
  }

  // Resolve a typed desktop id to the exact installed entry name, so
  // "discord" finds Discord.desktop even though names differ in case.
  function resolveDesktopId(id) {
    var lib = service.shell && service.shell.appLibrary ? service.shell.appLibrary : null
    if (!id || !lib) return String(id || "")
    try {
      var rows = lib.sortedEntries("")
      var names = []
      for (var i = 0; i < rows.length; i++) names.push(String(rows[i].entry.id || ""))
      return Toggler.matchDesktopId(id, names)
    } catch (e) { return String(id || "") }
  }

  function guessClass(slot) {
    var s = service.settingsFor(slot)
    if (s.knownClass && !service.isTerminalClass(s.knownClass)) return s.knownClass
    // Cliamp is launched in a dedicated Foot app-id, so its future window
    // class is the desktop id rather than Foot's shared terminal class.
    if (Toggler.normalizeDesktopId(s.desktopId).toLowerCase() === "cliamp") return "cliamp"
    if (s.knownClass) return s.knownClass
    return ""
  }

  function clientAddresses() {
    var out = ({})
    for (var i = 0; i < service.clients.length; i++) {
      var address = String(service.clients[i].address || "")
      if (address) out[address] = true
    }
    return out
  }

  function launchSlot(slot, hidden) {
    var s = service.settingsFor(slot)
    if (!s.desktopId) return
    service.pendingLaunch = {
      slot: slot, at: Date.now(), reveal: !hidden,
      existingAddresses: service.clientAddresses()
    }
    if (service.guessClass(slot)) service.applyRule(slot, service.guessClass(slot))
    service.runDispatch("hl.dsp.exec_cmd(" + luaQuote(service.launchCommand(s)) + ")")
    learnTimer.restart()
  }

  // Poll-based learn: after launch, refreshState() updates `clients`; when a
  // window matching the slot's desktop id appears, learn its real class and
  // shepherd it onto the special workspace. Avoids relying on openwindow
  // event parsing, which is unreliable for webapps opening in an existing
  // browser session.
  function pollLearn() {
    var pending = service.pendingLaunch
    if (!pending.slot) return
    if (Date.now() - pending.at > service.learnMs + 5000) {
      service.pendingLaunch = ({})
      return
    }
    var win = service.findPendingWindow(pending)
    if (!win) return
    var cls = String(win.class || "")
    var addr = String(win.address || "")
    var slot = pending.slot
    var special = service.settingsFor(slot).special || slot
    service.pendingLaunch = ({})

    // Record the class so the next launch takes the fast rule path.
    var s = service.settingsFor(slot)
    if (!s.knownClass || s.knownClass !== cls) {
      var next = Toggler.mergeSettings(service.settings, slot, { knownClass: cls })
      service.settings = next
      service.persistSettings()
      service.applyRule(slot, cls)
    }

    // Moving creates the special workspace when needed; reveal it only after
    // the move, so cold start takes one hotkey press.
    var onSpecial = String(win.workspace && win.workspace.name || "") === "special:" + special
    var wasVisible = service.specialVisible(special)
    if (addr && !onSpecial) {
      service.runDispatch("hl.dsp.window.move({ workspace = " + luaQuote("special:" + special)
        + ", window = " + luaQuote("address:" + addr) + ", follow = false })")
      service.runDispatch("hl.dsp.window.float({ window = " + luaQuote("address:" + addr) + " })")
      service.runDispatch("hl.dsp.window.center({ window = " + luaQuote("address:" + addr) + " })")
    }
    if (pending.reveal && !wasVisible)
      service.runDispatch("hl.dsp.workspace.toggle_special(" + luaQuote(special) + ")")
  }

  function openConfig(slot) {
    if (!service.shell || typeof service.shell.summon !== "function") return
    service.shell.summon(service.pluginId, JSON.stringify({ slot: slot }))
  }

  function notify(message) {
    Quickshell.execDetached(["omarchy-notification-send", "-u", "low", message])
  }

  // ------------------------------------------------------------- IPC surface

  IpcHandler {
    target: "hot-apps"

    function toggle(slot: string): string {
      service.toggleSlot(String(slot || ""))
      return "ok"
    }

    function set(slot: string, desktopId: string): string {
      slot = String(slot || "")
      var id = Toggler.normalizeDesktopId(desktopId)
      if (!id) return "empty"
      if (!Toggler.slotInfo(slot)) return "unknown slot: " + slot
      var next = Toggler.mergeSettings(service.settings, slot, {
        desktopId: id,
        special: slot,
        knownClass: ""
      })
      service.disableRule(slot)
      service.settings = next
      service.persistSettings()
      var other = slot === "comma" ? "period" : "comma"
      var otherId = service.settingsFor(other).desktopId
      if (otherId && otherId.toLowerCase() === id.toLowerCase())
        service.notify("Hot Apps: " + other + " slot also has " + id + " — the two slots will fight over one window")
      service.notify("Hot Apps: " + slot + " → " + id)
      return "ok"
    }

    function clear(slot: string): string {
      slot = String(slot || "")
      var next = Toggler.mergeSettings(service.settings, slot, {
        desktopId: "",
        knownClass: ""
      })
      service.disableRule(slot)
      service.settings = next
      service.persistSettings()
      return "ok"
    }

    function state(): string {
      return JSON.stringify({
        clients: service.clients.length,
        monitors: service.monitors.length,
        pendingLaunch: service.pendingLaunch,
        pendingToggle: service.pendingToggle
      })
    }

    function config(slot: string): string {
      service.openConfig(String(slot || "comma"))
      return "ok"
    }

    function list(): string {
      var out = []
      var slots = Toggler.slotKeys()
      for (var i = 0; i < slots.length; i++) {
        var slot = slots[i]
        var s = service.settingsFor(slot)
        out.push({
          slot: slot,
          combo: Toggler.defaultCombo(slot),
          desktopId: s.desktopId,
          special: s.special || slot,
          knownClass: s.knownClass,
          preload: s.preload,
          running: !!service.findWindow(slot)
        })
      }
      return JSON.stringify(out)
    }

    function apps(query: string): string {
      // Enumerate the desktop application library directly. The shell proxy
      // appLibrary is not guaranteed for a service-plugin shell, but the
      // Quickshell DesktopEntries singleton is always available.
      var values = DesktopEntries.applications.values || []
      var q = String(query || "").toLowerCase()
      var out = []
      for (var i = 0; i < values.length; i++) {
        var e = values[i]
        var id = String(e.id || "")
        var name = String(e.name || id)
        if (!id) continue
        if (q && name.toLowerCase().indexOf(q) === -1
          && id.toLowerCase().indexOf(q) === -1) continue
        out.push({
          id: id,
          name: name,
          subtext: String(e.genericName || e.comment || ""),
          icon: String(e.icon || "")
        })
      }
      out.sort(function(a, b) { return a.name.localeCompare(b.name) })
      return JSON.stringify(out)
    }

    function ping(): string { return "ok" }
  }

  // ------------------------------------------------------------- data feeds

  property var clients: []
  property var monitors: []

  // One sequenced command: clients + monitors via jq --slurpfile so a toggle
  // never sees a half-updated view (clients up, monitors stale). Process
  // substitution is a bash-4 feature; the command runs under bash -c.
  Process {
    id: stateProc
    command: ["bash", "-c",
      "jq -n --slurpfile c <(hyprctl clients -j) --slurpfile m <(hyprctl monitors -j) "
      + "'{clients: $c[0], monitors: $m[0]}'"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var state = JSON.parse(String(text || "{}"))
          service.clients = Array.isArray(state.clients) ? state.clients : []
          service.monitors = Array.isArray(state.monitors) ? state.monitors : []
          var titleMoves = service.pendingTitleMoves
          service.pendingTitleMoves = []
          for (var i = 0; i < titleMoves.length; i++) {
            var move = titleMoves[i]
            if (service.pendingLaunch.slot === move.slot) continue
            var s = service.settingsFor(move.slot)
            for (var j = 0; j < service.clients.length; j++) {
              var c = service.clients[j]
              var id = s.desktopId.toLowerCase()
              var title = String(c.title || "").toLowerCase()
              var className = String(c.class || "").toLowerCase()
              if (String(c.address || "") === move.address
                && (service.titleMatchesDesktopId(title, id)
                  || className === id || className.indexOf(id) !== -1)) {
                var special = s.special || move.slot
                if (String(c.workspace && c.workspace.name || "") !== "special:" + special)
                  service.moveToSpecial(move.address, move.slot)
                break
              }
            }
          }
          service.pollLearn()
          if (service.pendingToggle) {
            var slot = service.pendingToggle
            service.pendingToggle = ""
            service.toggleWithState(slot)
          }
        } catch (e) {
          service.clients = []
          service.monitors = []
        }
      }
    }
  }

  Process {
    id: evalProc
    command: []
    stdout: StdioCollector {
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err && err !== "ok") console.warn("hot-apps eval:", err)
      }
    }
    onExited: service.runNextEval()
  }

  // Serialize dispatcher calls: special workspace creation/show must finish
  // before the new window is moved onto it. Reusing one Process without a
  // queue can replace its command while the previous hyprctl is still active.
  Process {
    id: dispatchProc
    command: []
    stdout: StdioCollector {
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err && err !== "ok") console.warn("hot-apps dispatch:", err)
      }
    }
    onExited: service.runNextDispatch()
  }

  FileView {
    id: shellConfig
    path: service.configPath
    watchChanges: true
    printErrors: false
    onLoaded: service.applySettings(service.parseSettings(text()))
    onFileChanged: reload()
  }

  // Re-register the hotkeys and re-apply window rules after any Hyprland
  // config reload. The static default SUPER+SHIFT+comma bind (Dismiss all
  // notifications) is re-created by the reload; ours must win, so re-register
  // slightly after the event — config parsing finishes after configreloaded.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String(event.name)
      if (name === "openwindow") service.onOpenWindowEvent(event.data)
      if (name === "windowtitlev2" || name === "windowtitle")
        service.onWindowTitleEvent(event.data)
      if (name === "configreloaded") {
        rebindTimer.restart()
        service.reapplyRules()
        return
      }
    }
  }

  Timer {
    id: rebindTimer
    interval: 1500
    repeat: false
    onTriggered: service.registerBinds()
  }

  Timer {
    id: learnTimer
    interval: 400
    repeat: true
    onTriggered: {
      if (!service.pendingLaunch.slot) { learnTimer.stop(); return }
      if (Date.now() - service.pendingLaunch.at > service.learnMs + 5000) {
        service.pendingLaunch = ({})
        learnTimer.stop()
        return
      }
      service.refreshState()
    }
  }
  // Safety net: re-register the hotkeys if they disappeared (e.g. Hyprland
  // config reload re-created the static default and our configreloaded event
  // was missed). Low-frequency poll keeps the keys ours without event
  // delivery guarantees.
  Timer {
    id: bindSafeTimer
    interval: 5000
    repeat: true
    running: true
    onTriggered: service.ensureBinds()
  }

  function ensureBinds() {
    bindsCheckProc.running = true
  }

  Process {
    id: bindsCheckProc
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var binds = JSON.parse(String(text || "[]"))
          var found = {}
          for (var i = 0; i < binds.length; i++) {
            var b = binds[i]
            if (b && String(b.description || "").indexOf("Hot Apps") === 0) {
              found[String(b.key || "")] = true
            }
          }
          var missing = false
          var slots = Toggler.slotKeys()
          for (var j = 0; j < slots.length; j++) {
            if (!found[Toggler.slotInfo(slots[j]).key]) missing = true
          }
          if (missing) service.registerBinds()
        } catch (e) {}
      }
    }
  }
  function refreshState() {
    stateProc.running = true
  }

  Component.onCompleted: {
    stateProc.running = true
    registerBinds()
  }

  Component.onDestruction: unbindAll()
}
