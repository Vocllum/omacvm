// The Mac's Night Shift in Omarchy's bar, with Omarchy's own night light icon:
// lit while Night Shift is on, dimmed while it is off; a click switches it
// (the same as Super+Ctrl+N, which OmacVM points at the Mac). The state comes
// live from omacvm-bridge's event stream ("display" events), so a change made
// on the Mac shows here at once.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

BarWidget {
  id: root
  moduleName: "omacvm.nightshift"

  property bool available: false
  property bool enabled: false
  property string currentEvent: ""
  property real lastSeen: 0

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // SplitParser hands the blank line that ends an SSE event over as a leading
  // "\n" on the next field, so trim before matching.
  function handleLine(raw) {
    var line = String(raw).replace(/^\s+|\r$/g, "")
    if (line.indexOf(":") === 0) { lastSeen = Date.now(); return }
    if (line.indexOf("event:") === 0) { currentEvent = line.substring(6).trim(); return }
    if (line.indexOf("data:") !== 0) return
    lastSeen = Date.now()
    if (currentEvent !== "display") return
    try {
      var d = JSON.parse(line.substring(5))
      if (d && d.night_shift) {
        enabled = !!d.night_shift.enabled
        available = true
      }
    } catch (e) {
    }
  }

  function reconnect() {
    available = false
    if (stream.running) stream.running = false
    if (!restart.running) restart.start()
  }

  Process {
    id: stream
    command: ["omacvm-bridge", "events"]
    running: true
    onStarted: root.lastSeen = Date.now()
    onExited: root.reconnect()
    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
  }

  Timer {
    id: restart
    interval: 3000
    onTriggered: if (!stream.running) stream.running = true
  }

  // The helper pushes Wi-Fi every few seconds: silence means the Mac is asleep
  // or the VM network is gone; reconnect once it answers again.
  Timer {
    interval: 5000
    repeat: true
    running: stream.running
    onTriggered: if (Date.now() - root.lastSeen > 20000) root.reconnect()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰔎"
    active: root.enabled
    dimmed: !root.enabled
    opacity: root.available ? 1.0 : 0.5
    tooltipText: !root.available ? "Night Shift (the Mac does not answer)"
      : (root.enabled ? "Night Shift on (Mac)" : "Night Shift off (Mac)")
    onPressed: function(b) {
      // The bridge's answer and its event set the state; show it at once.
      if (root.available) root.enabled = !root.enabled
      Quickshell.execDetached(["omacvm-bridge", "night-shift", "toggle"])
    }
  }
}
