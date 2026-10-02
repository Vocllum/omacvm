// Derived from Omarchy's omarchy.bluetooth widget (MIT, see LICENSE). The
// helpers below map omacvm-bridge payloads (the Mac's Bluetooth) onto the same
// sections and row model the native widget uses.

// "unavailable" (no answer from the Mac), "off", "on".
function kindFor(available, bt) {
  if (!available || !bt || bt.available === false) return "unavailable"
  return bt.power ? "on" : "off"
}

function iconFor(kind, connectedCount) {
  if (kind === "off" || kind === "unavailable") return "󰂲"
  if (connectedCount > 0) return "󰂱"
  return "󰂯"
}

function deviceLabel(device) {
  if (!device) return ""
  return String(device.name || device.address || "").trim()
}

// Primitives only, as in the native widget: rows become list-model data.
function deviceRow(d) {
  if (!d) return null
  return {
    address: d.address || "",
    name: deviceLabel(d),
    kind: d.kind || "other",
    connected: !!d.connected,
    battery: d.battery || null
  }
}

function sortedByLabel(rows) {
  var list = rows.slice()
  list.sort(function(a, b) { return a.name.localeCompare(b.name) })
  return list
}

function deviceLists(bt) {
  var devices = bt && Array.isArray(bt.devices) ? bt.devices : []
  var connected = []
  var known = []
  for (var i = 0; i < devices.length; i++) {
    var row = deviceRow(devices[i])
    if (!row || row.address === "") continue
    if (row.connected) connected.push(row)
    else known.push(row)
  }
  return { connected: sortedByLabel(connected), known: sortedByLabel(known) }
}

// "85%", or "L 85% · R 90% · Case 40%" for earbuds.
function batteryText(battery) {
  if (!battery) return ""
  var parts = []
  if (typeof battery.left === "number") parts.push("L " + battery.left + "%")
  if (typeof battery.right === "number") parts.push("R " + battery.right + "%")
  if (typeof battery["case"] === "number") parts.push("Case " + battery["case"] + "%")
  if (parts.length === 0 && typeof battery.main === "number") parts.push(battery.main + "%")
  return parts.join(" · ")
}

function cloneMap(map) {
  var next = ({})
  for (var key in map || {}) next[key] = map[key]
  return next
}

function withEntry(map, key, value) {
  var next = cloneMap(map)
  if (!key) return next
  if (value) next[key] = value
  else delete next[key]
  return next
}

if (typeof module !== "undefined") {
  module.exports = {
    kindFor: kindFor,
    iconFor: iconFor,
    deviceLabel: deviceLabel,
    deviceRow: deviceRow,
    sortedByLabel: sortedByLabel,
    deviceLists: deviceLists,
    batteryText: batteryText,
    cloneMap: cloneMap,
    withEntry: withEntry
  }
}
