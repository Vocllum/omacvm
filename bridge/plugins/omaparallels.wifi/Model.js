// Derived from Omarchy's omarchy.network widget (MIT, see LICENSE). The
// helpers below map omaparallels-bridge payloads (the Mac's Wi-Fi) onto the same row
// and icon model the native widget uses.

function wifiIconFor(strength) {
  var icons = ["󰤯", "󰤟", "󰤢", "󰤥", "󰤨"]
  var index = Math.max(0, Math.min(4, Math.ceil(strength / 20) - 1))
  return icons[index]
}

// "unavailable" (no helper), "off" (radio off), "disconnected", "wifi".
function kindFor(available, wifi) {
  if (!available || !wifi) return "unavailable"
  if (wifi.power === false) return "off"
  if (!wifi.connected) return "disconnected"
  return "wifi"
}

function connectionIcon(kind, quality) {
  if (kind === "wifi") return wifiIconFor(quality)
  return "󰤮"
}

function bandLabel(band) {
  return String(band || "").toLowerCase()
}

function formatChannel(channel) {
  if (!channel || !channel.number) return "--"
  var text = String(channel.number)
  if (channel.width_mhz) text += " · " + channel.width_mhz + " MHz"
  return text
}

function formatDbm(value) {
  return typeof value === "number" ? value + " dBm" : "--"
}

function formatRate(mbps) {
  var v = parseInt(mbps, 10)
  if (!v || v < 0) return "--"
  return v + " Mbit/s"
}

var securityLabels = {
  "none": "Open",
  "open": "Open",
  "owe": "Enhanced Open",
  "owe-transition": "Enhanced Open",
  "wep": "WEP",
  "wpa-personal": "WPA",
  "wpa-personal-mixed": "WPA/WPA2",
  "wpa2-personal": "WPA2",
  "wpa2-wpa3-personal": "WPA2/WPA3",
  "wpa3-personal": "WPA3",
  "wpa3-transition": "WPA2/WPA3",
  "wpa-enterprise": "WPA Enterprise",
  "wpa-enterprise-mixed": "WPA Enterprise",
  "wpa2-enterprise": "WPA2 Enterprise",
  "wpa3-enterprise": "WPA3 Enterprise",
  "dynamic-wep": "Dynamic WEP"
}

function securityLabel(security) {
  var key = String(security || "")
  if (!key) return "--"
  return securityLabels[key] || key
}

function isSecure(network) {
  if (!network) return false
  if (typeof network.secure === "boolean") return network.secure
  var s = String(network.security || "")
  return s !== "" && s !== "none" && s !== "open"
}

// OWE encrypts without credentials, so it gets no lock, matching the native
// widget's credentials-required affordance.
function needsCredentials(network) {
  if (!isSecure(network)) return false
  return String(network.security || "").indexOf("owe") !== 0
}

// Primitives only, same as the native widget: rows become list-model data.
function wifiRow(network) {
  if (!network) return null
  return {
    connected: !!network.current,
    known: !!network.known,
    ssid: network.ssid || "",
    signal: Math.max(0, Math.min(100, parseInt(network.quality, 10) || 0)),
    locked: needsCredentials(network),
    bands: Array.isArray(network.bands) ? network.bands.join(" · ") : ""
  }
}

function wifiRows(scan) {
  var networks = scan && Array.isArray(scan.networks) ? scan.networks : []
  var rows = []
  var seen = {}
  for (var i = 0; i < networks.length; i++) {
    var row = wifiRow(networks[i])
    if (!row) continue
    // One row per name; a hidden network has none to merge on.
    var key = row.ssid
    if (key !== "" && seen[key] !== undefined) {
      var existing = rows[seen[key]]
      if (row.connected || (!existing.connected && row.signal > existing.signal)) rows[seen[key]] = row
      continue
    }
    if (key !== "") seen[key] = rows.length
    rows.push(row)
  }
  return sortWifiRows(rows)
}

function sortWifiRows(rows) {
  var nets = Array.isArray(rows) ? rows.slice() : []
  nets.sort(function(a, b) {
    if (a.connected !== b.connected) return a.connected ? -1 : 1
    if (a.known !== b.known) return a.known ? -1 : 1
    return b.signal - a.signal
  })
  return nets
}

function wifiSectionTitle(wifiNetworks, index) {
  var networks = Array.isArray(wifiNetworks) ? wifiNetworks : []
  if (index < 0 || index >= networks.length) return ""

  var net = networks[index]
  if (!net) return ""

  if (net.known && index === 0) return "KNOWN NETWORKS"
  if (!net.known && (index === 0 || (networks[index - 1] && networks[index - 1].known))) return "OTHER NETWORKS"
  return ""
}

if (typeof module !== "undefined") {
  module.exports = {
    wifiIconFor: wifiIconFor,
    kindFor: kindFor,
    connectionIcon: connectionIcon,
    bandLabel: bandLabel,
    formatChannel: formatChannel,
    formatDbm: formatDbm,
    formatRate: formatRate,
    securityLabel: securityLabel,
    isSecure: isSecure,
    needsCredentials: needsCredentials,
    wifiRow: wifiRow,
    wifiRows: wifiRows,
    sortWifiRows: sortWifiRows,
    wifiSectionTitle: wifiSectionTitle
  }
}
