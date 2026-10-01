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
  property var lastRules: ({})       // slot -> class we have a window rule installed for

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
    service.settings = next
    service.registerBinds()
    service.reapplyRules()
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

  // All Hyprland mutations go through `hyprctl dispatch` with a Lua
  // expression. This Hyprland's Lua shim makes `hyprctl eval "hl.dsp...."`
  // return "ok" while silently NOT executing window moves; only dispatch
  // actually applies them.
  // Mutations that reach a Hyprland dispatcher (window.move, workspace
  // toggle, exec_cmd) go through `hyprctl dispatch` — the Lua-shim's
  // `hl.dispatch` actually applies them, where `hyprctl eval` silently
  // returns "ok" without executing.
  function runDispatch(lua) {
    evalProc.command = ["hyprctl", "dispatch", lua]
    evalProc.running = true
  }

  // Config-table helpers (hl.bind / hl.unbind / hl.window_rule) must go
  // through `hyprctl eval`: they are not dispatchers, so `hl.dispatch`'s
  // return wrapping rejects them after the side effect, or on unbind never
  // applies at all.
  function runEval(lua) {
    evalProc.command = ["hyprctl", "eval", lua]
    evalProc.running = true
  }

  function luaQuote(value) {
    return '"' + String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
  }

  // Persist the plugin entry via the shell API. updateEntryInline replaces
  // the entry object; the shell preserves `id` and we must not drop fields.
  // Always refresh the menu row on top of the config write.
  function persistSettings() {
    if (service.shell && typeof service.shell.updateEntryInline === "function") {
      service.shell.updateEntryInline(service.pluginId, {
        comma: service.settings.comma,
        period: service.settings.period
      })
    }
    service.syncMenu()
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
    var s = service.settingsFor(slot)
    var special = s.special || slot
    var lua = "hl.window_rule({ match = { class = " + luaQuote(classPattern) + " }, "
      + "workspace = " + luaQuote("special:" + special + " silent") + ", "
      + "float = true, center = true, no_initial_focus = true, "
      + "size = { \"monitor_w * 0.98\", \"monitor_h * 0.85\" } })"
    service.lastRules[slot] = classPattern
    service.runEval(lua)
  }

  function reapplyRules() {
    for (var slot in service.lastRules) service.applyRule(slot, service.lastRules[slot])
  }

  // -------------------------------------------------------------- matching

  function escapeRegex(value) {
    return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  }

  function knownClassPattern(slot) {
    var s = service.settingsFor(slot)
    if (s.knownClass) return s.knownClass
    if (!s.desktopId) return ""
    // Loose substring: a webapp launched from a desktop entry gets a
    // URL-derived class (chrome-discord.com__...-Default) that contains the
    // desktop id but does not start with it. Matching is case-insensitive.
    return service.escapeRegex(Toggler.normalizeDesktopId(s.desktopId))
  }

  function findWindow(slot) {
    var pattern = service.knownClassPattern(slot)
    if (!pattern.length || service.clients.length === 0) return null
    var re = new RegExp(pattern, "i")
    for (var i = 0; i < service.clients.length; i++) {
      var c = service.clients[i]
      if (typeof c.class === "string" && re.test(c.class)) return c
    }
    return null
  }

  // ------------------------------------------------------------ launch flow

  // Toggle the special workspace into view, creating it if needed. A nested
  // `hyprctl dispatch` (through exec_cmd) is required: this Hyprland's Lua
  // shim toggle_special does not create a workspace that does not exist yet.
  function showSpecial(special) {
    if (service.specialVisible(special)) return
    service.runDispatch("hl.dsp.exec_cmd(" + luaQuote(
      "hyprctl dispatch hl.dsp.workspace.toggle_special(" + luaQuote(special) + ")"
    ) + ")")
  }

  function specialVisible(special) {
    for (var i = 0; i < service.monitors.length; i++) {
      var sw = service.monitors[i].specialWorkspace || {}
      if (String(sw.name || "") === "special:" + special) return true
    }
    return false
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
      }
      var onSpecial = String(win.workspace && win.workspace.name || "") === "special:" + special
      if (onSpecial) {
        // Window already lives on its special workspace: flip visibility.
        service.runDispatch("hl.dsp.workspace.toggle_special(" + luaQuote(special) + ")")
      } else {
        // A special workspace must exist before a window can move onto it.
        service.showSpecial(special)
        service.runDispatch("hl.dsp.window.move({ workspace = " + luaQuote("special:" + special)
          + ", window = " + luaQuote("address:" + win.address) + ", follow = false })")
      }
      return
    }
    // Cold start. If we already learned the window class (previous launch),
    // install the rule so the window lands on special:<name> silent directly.
    service.pendingLaunch = { slot: slot, at: Date.now(), reveal: true }
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
    if (s.knownClass) return s.knownClass
    return ""
  }

  function launchSlot(slot, hidden) {
    var s = service.settingsFor(slot)
    if (!s.desktopId) return
    service.pendingLaunch = { slot: slot, at: Date.now(), reveal: !hidden }
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
    var win = service.findWindow(pending.slot)
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
    }

    // The workspace must exist first. `showSpecial` creates it via the nested
    // dispatcher; then move/float/center the real window.
    service.showSpecial(special)
    if (addr) {
      service.runDispatch("hl.dsp.window.move({ workspace = " + luaQuote("special:" + special)
        + ", window = " + luaQuote("address:" + addr) + ", follow = false })")
      service.runDispatch("hl.dsp.window.float({ window = " + luaQuote("address:" + addr) + " })")
      service.runDispatch("hl.dsp.window.center({ window = " + luaQuote("address:" + addr) + " })")
    }
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
      service.settings = next
      service.persistSettings()
      service.notify("Hot Apps: " + slot + " → " + id)
      return "ok"
    }

    function clear(slot: string): string {
      slot = String(slot || "")
      var next = Toggler.mergeSettings(service.settings, slot, {
        desktopId: "",
        knownClass: ""
      })
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
      if (name === "configreloaded") {
        service.rebindTimer.restart()
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
