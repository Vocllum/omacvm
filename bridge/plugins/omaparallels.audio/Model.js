// Derived from Omarchy's omarchy.audio widget (MIT, see LICENSE). The
// helpers below map omaparallels-bridge audio payloads (the Mac's CoreAudio devices)
// onto the native widget's labels and glyphs.

function outputVolumeName(volume, muted) {
  if (muted) return "Muted"
  var p = Math.round(volume * 100)
  if (p === 0) return "Silenced"
  if (p >= 100) return "Concert hall"
  if (p >= 85) return "Party mode"
  if (p >= 70) return "Cranked up"
  if (p >= 50) return "Steady groove"
  if (p >= 30) return "Easy listening"
  if (p >= 15) return "Murmur"
  return "Whisper"
}

function deviceBlob(device) {
  if (!device) return ""
  return String([device.name, device.transport, device.uid].join(" ")).toLowerCase()
}

function isHeadphones(device) {
  var blob = deviceBlob(device)
  return blob.indexOf("headphone") !== -1
    || blob.indexOf("headset") !== -1
    || blob.indexOf("earbud") !== -1
    || blob.indexOf("earphone") !== -1
    || blob.indexOf("airpod") !== -1
    || blob.indexOf("beats") !== -1
}

function sinkGlyph(device) {
  if (!device) return "󰓃"
  if (isHeadphones(device)) return "󰋋"
  var blob = deviceBlob(device)
  if (blob.indexOf("bluetooth") !== -1) return "󰂯"
  if (blob.indexOf("hdmi") !== -1 || blob.indexOf("displayport") !== -1 || blob.indexOf("display") !== -1 || blob.indexOf("airplay") !== -1) return "󰍹"
  return "󰓃"
}

function sourceGlyph(device) {
  if (!device) return "󰍬"
  var blob = deviceBlob(device)
  if (blob.indexOf("headset") !== -1 || isHeadphones(device)) return "󰋋"
  if (blob.indexOf("bluetooth") !== -1) return "󰂯"
  if (blob.indexOf("webcam") !== -1 || blob.indexOf("camera") !== -1) return "󰄀"
  return "󰍬"
}

function deviceLabel(device) {
  if (!device) return "Unknown"
  return String(device.name || device.uid || "Unknown")
}

// Primitives only: rows become Repeater model data.
function deviceRows(audio, wantOutput) {
  var devices = audio && Array.isArray(audio.devices) ? audio.devices : []
  var rows = []
  for (var i = 0; i < devices.length; i++) {
    var d = devices[i]
    if (!d) continue
    if (wantOutput ? !d.has_output : !d.has_input) continue
    rows.push({
      uid: String(d.uid || ""),
      name: deviceLabel(d),
      transport: String(d.transport || ""),
      active: wantOutput ? !!d.default_output : !!d.default_input
    })
  }
  return rows
}

function clamp01(v) {
  var n = Number(v)
  if (!isFinite(n)) return 0
  return Math.max(0, Math.min(1, n))
}

if (typeof module !== "undefined") {
  module.exports = {
    outputVolumeName: outputVolumeName,
    isHeadphones: isHeadphones,
    sinkGlyph: sinkGlyph,
    sourceGlyph: sourceGlyph,
    deviceLabel: deviceLabel,
    deviceRows: deviceRows,
    clamp01: clamp01
  }
}
