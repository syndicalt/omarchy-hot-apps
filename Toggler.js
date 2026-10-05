.pragma library

// Pure logic for Hot Apps: slot settings normalization and merge, plus
// shell-quoting and command construction. No QML state lives here so every
// function is testable from plain JS.

var SLOT_KEYS = ["comma", "period"]

var SLOT_INFO = {
  comma: { combo: "SUPER + SHIFT + comma", key: "comma", label: "Slot 1 (…)" },
  period: { combo: "SUPER + SHIFT + period", key: "period", label: "Slot 2 (…)" }
}

function slotKeys() {
  return SLOT_KEYS.slice()
}

function slotInfo(slot) {
  return SLOT_INFO[slot] || null
}

function defaultCombo(slot) {
  return (SLOT_INFO[slot] || {}).combo || ""
}

// Normalize an app entry name ("Discord", "discord.desktop", "org.foo.Bar")
// to the canonical form used as the desktop-id key in settings.
function normalizeDesktopId(id) {
  var value = String(id || "").trim()
  if (value.slice(-8) === ".desktop") value = value.slice(0, -8)
  return value
}

// gtk-launch resolves <id>.desktop exactly; installed names may differ in
// case (Discord.desktop). Desktop ids are matched case-insensitively, so we
// store what the user typed but resolve against the real installed name.
function matchDesktopId(id, installedNames) {
  var needle = String(id || "").toLowerCase()
  installedNames = installedNames || []
  for (var i = 0; i < installedNames.length; i++) {
    var name = String(installedNames[i] || "").replace(/\.desktop$/i, "")
    if (name.toLowerCase() === needle) return name
  }
  return String(id || "")
}

// Normalize one slot's stored entry into the settings shape the service
// works with. Every field has a default; nothing unknown is carried over.
function normalizeSlot(raw) {
  raw = raw || {}
  return {
    desktopId: normalizeDesktopId(raw.desktopId || ""),
    special: String(raw.special || ""),
    preload: raw.preload !== false,
    // Learned from Hyprland after first launch. Persisted so a restart
    // never has to guess from the desktop id again.
    knownClass: String(raw.knownClass || "")
  }
}

// Build the complete settings object from a raw shell.json plugin entry
// (which holds `comma`/`period` inline keys next to `id`).
function slotSettings(entry) {
  entry = entry || {}
  var out = {}
  for (var i = 0; i < SLOT_KEYS.length; i++) {
    var key = SLOT_KEYS[i]
    out[key] = normalizeSlot(entry[key])
  }
  return out
}

// Merge a per-slot patch into settings. Missing absolute fields keep their
// current value; `desktopId: ""` clears the assignment.
function mergeSettings(settings, slot, patch) {
  var next = {}
  for (var k in settings) next[k] = settings[k]
  var base = normalizeSlot(settings[slot])
  for (var key in (patch || {})) base[key] = patch[key]
  next[slot] = base
  return next
}

function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'"
}

// Launches via the desktop entry, the same resolver Omarchy's AppLibrary
// uses (supports ids with spaces and entries UWSM rejects).
function launchCommand(desktopId) {
  // Cliamp is a Terminal=true desktop entry, so gtk-launch opens it in Foot
  // with Foot's shared class. Give hot-app launches a dedicated app id so the
  // window rule can place it on its special workspace before it is shown.
  if (String(desktopId || "").replace(/\.desktop$/i, "").toLowerCase() === "cliamp")
    return "foot --app-id=cliamp --title=cliamp cliamp"
  return "gtk-launch " + shellQuote(String(desktopId || "") + ".desktop")
}
