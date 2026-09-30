#!/usr/bin/env python3
"""Patch a clone of Omarchy's bar (Bar.qml) for omarchy-notch-bar.

usage: apply-patch.py <Bar.qml>        (patches the file in place, idempotent)

What the patch adds:
  * A copy of the bar on any output whose name starts with NOTCH (the hidden
    output that feeds the macOS notch helper) lays out its centre widgets
    around the camera housing.
  * While the helper reports that the notch strip is showing ("parked"), the
    bar on the built-in display (Virtual-1 by default) is parked: it stays
    mapped just past the screen edge, reserves no space and uses the same
    notch layout as the NOTCH copy. The helper's clicks are pressed on this
    parked copy, so panels open on the visible display under the strip.
  * IPC target "notchbar" for the helper, and a watchdog that unparks the bar
    when the helper stops sending heartbeats.
"""
import sys

MARK = "omarchy-notch-bar"


def replace_once(text, old, new):
    count = text.count(old)
    if count != 1:
        sys.exit(f"apply-patch: expected exactly one match, found {count}:\n{old}")
    return text.replace(old, new)


def main():
    path = sys.argv[1]
    text = open(path).read()
    if MARK in text:
        print("already patched")
        return

    # 1. State and role helpers.
    text = replace_once(text, '  property string home: Quickshell.env("HOME")\n', '''  property string home: Quickshell.env("HOME")

  // --- omarchy-notch-bar ------------------------------------------------
  // A hidden output named NOTCH* renders this bar for the macOS notch helper.
  // While the helper shows the strip, the bar on notchParkedScreen is parked
  // (mapped off-screen, no exclusive zone) and takes the helper's clicks, so
  // panels open on the visible display right under the notch strip.
  property bool notchParked: false
  property string notchParkedScreen: "Virtual-1"
  // Camera housing in bar coordinates (logical px == macOS points).
  property real notchLeft: 918
  property real notchRight: 1138
  property real notchLastBeat: 0
  // Bumped by the helper's capture program: repaints every bar surface once,
  // so a new capture session gets a frame without waiting for a change.
  property int notchPokeSerial: 0
  function notchRoleFor(s) {
    var n = s && s.name ? String(s.name) : ""
    if (n.indexOf("NOTCH") === 0) return "notch"
    if (notchParked && n === notchParkedScreen) return "parked"
    return ""
  }
  function notchTargetAt(x, y) {
    for (var i = clickTargets.length - 1; i >= 0; i--) {
      var t = clickTargets[i]
      if (!moduleTargetClickable(t)) continue
      var w = targetWindow(t)
      if (!w || !w.screen || String(w.screen.name) !== notchParkedScreen) continue
      var p = t.mapToItem(w.contentItem, 0, 0)
      if (x >= p.x && x < p.x + t.width && y >= p.y && y < p.y + t.height) return t
    }
    return null
  }
  function notchTargetRects() {
    var out = []
    for (var i = 0; i < clickTargets.length; i++) {
      var t = clickTargets[i]
      if (!moduleTargetClickable(t)) continue
      var w = targetWindow(t)
      if (!w || !w.screen || String(w.screen.name).indexOf("NOTCH") !== 0) continue
      var p = t.mapToItem(w.contentItem, 0, 0)
      out.push([Math.round(p.x), Math.round(p.y), Math.round(t.width), Math.round(t.height)])
    }
    return out
  }
  // --- end omarchy-notch-bar --------------------------------------------
''')

    # 2. IPC target and watchdog, next to the existing omarchy.bar handler.
    text = replace_once(text, '''  Variants {
    model: Quickshell.screens

    delegate: Component {
      BarPanel {''', '''  // omarchy-notch-bar: control surface for the macOS notch helper.
  IpcHandler {
    target: "notchbar"

    function setParked(on: bool): string {
      root.notchLastBeat = Date.now()
      root.notchParked = on
      return root.notchParked ? "parked" : "unparked"
    }
    function setParkedScreen(name: string): string {
      root.notchParkedScreen = name
      return root.notchParkedScreen
    }
    function setNotch(left: real, right: real): string {
      root.notchLeft = left
      root.notchRight = right
      return left + "," + right
    }
    function poke(): string {
      root.notchPokeSerial++
      return String(root.notchPokeSerial)
    }
    function heartbeat(): string {
      root.notchLastBeat = Date.now()
      return root.notchParked ? "parked" : "unparked"
    }
    function click(x: real, y: real, button: int): string {
      var t = root.notchTargetAt(x, y)
      if (!t) return "miss"
      t.triggerPress(button === 3 ? Qt.MiddleButton : button === 2 ? Qt.RightButton : Qt.LeftButton)
      return "ok"
    }
    function wheel(x: real, y: real, delta: int): string {
      var t = root.notchTargetAt(x, y)
      if (!t || typeof t.wheelMoved !== "function") return "miss"
      t.wheelMoved(delta)
      return "ok"
    }
    function targets(): string {
      return JSON.stringify(root.notchTargetRects())
    }
    function state(): string {
      return JSON.stringify({ parked: root.notchParked, screen: root.notchParkedScreen,
                              notch: [root.notchLeft, root.notchRight], barSize: root.barSize,
                              beatAgeMs: root.notchLastBeat ? Date.now() - root.notchLastBeat : -1 })
    }
  }

  // Unpark when the helper goes quiet, so the built-in display never ends up
  // without a bar.
  Timer {
    interval: 1000
    repeat: true
    running: root.notchParked
    onTriggered: if (Date.now() - root.notchLastBeat > 5000) root.notchParked = false
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      BarPanel {''')

    # 3. Parking per window instead of only through the global bar-off flag.
    text = replace_once(text, '''    visible: !remapGuard.remapping
    exclusionMode: root.barHidden ? ExclusionMode.Ignore : ExclusionMode.Auto
''', '''    visible: !remapGuard.remapping
    // omarchy-notch-bar: role of this copy ("notch", "parked" or "").
    readonly property string notchRole: root.notchRoleFor(screen)
    readonly property bool parked: root.barHidden || notchRole === "parked"
    readonly property bool notchLayout: notchRole !== ""
    exclusionMode: barWindow.parked ? ExclusionMode.Ignore : ExclusionMode.Auto
''')
    text = replace_once(text, '''      top: root.barHidden && root.position === "top" ? -root.barSize : 0
      bottom: root.barHidden && root.position === "bottom" ? -root.barSize : 0
      left: root.barHidden && root.position === "left" ? -root.barSize : 0
      right: root.barHidden && root.position === "right" ? -root.barSize : 0''', '''      top: barWindow.parked && root.position === "top" ? -root.barSize : 0
      bottom: barWindow.parked && root.position === "bottom" ? -root.barSize : 0
      left: barWindow.parked && root.position === "left" ? -root.barSize : 0
      right: barWindow.parked && root.position === "right" ? -root.barSize : 0''')

    # 4. Pass the layout mode to the horizontal centre section.
    text = replace_once(text, '''      Item {
        anchors.fill: parent

        CenterModules { anchors.fill: parent }

        LeftModules {
          anchors.left: parent.left''', '''      Item {
        anchors.fill: parent

        CenterModules { anchors.fill: parent; notchLayout: barWindow.notchLayout }

        LeftModules {
          anchors.left: parent.left''')

    # 5. Centre widgets around the camera housing in notch layout.
    text = replace_once(text, '''    property var entries: root.layoutEntries("center")
    readonly property bool hasAnchor: root.entryIndex(entries, root.centerAnchor) !== -1''', '''    property var entries: root.layoutEntries("center")
    // omarchy-notch-bar: keep the camera housing free.
    property bool notchLayout: false
    readonly property bool hasAnchor: root.entryIndex(entries, root.centerAnchor) !== -1''')
    text = replace_once(text, '''        CenterGestureArea { anchors.fill: parent }

        HoverHandler {
          onHoveredChanged: root.setCenterSectionHovered(hovered)
        }

        ModuleList {
          visible: !centerRoot.hasAnchor
          entries: centerRoot.entries
          region: "center"
          anchors.centerIn: parent
        }

        ModuleList {
          visible: centerRoot.hasAnchor
          entries: root.entriesBefore(centerRoot.entries, root.centerAnchor)
          region: "center"
          anchors.right: centerAnchorModule.left
          anchors.verticalCenter: centerAnchorModule.verticalCenter
        }

        ModuleSlot {
          id: centerAnchorModule
          visible: centerRoot.hasAnchor
          entry: centerRoot.anchorEntry
          region: "center"
          anchors.centerIn: parent
        }
''', '''        CenterGestureArea { anchors.fill: parent }

        HoverHandler {
          onHoveredChanged: root.setCenterSectionHovered(hovered)
        }

        // omarchy-notch-bar: edges of the camera housing plus a small gap.
        Item { id: notchLeftEdge; x: root.notchLeft - Style.space(6); width: 0; height: parent.height }
        Item { id: notchRightEdge; x: root.notchRight + Style.space(6); width: 0; height: parent.height }

        ModuleList {
          visible: !centerRoot.hasAnchor
          entries: centerRoot.entries
          region: "center"
          anchors.centerIn: centerRoot.notchLayout ? undefined : parent
          anchors.left: centerRoot.notchLayout ? notchRightEdge.left : undefined
          anchors.verticalCenter: centerRoot.notchLayout ? parent.verticalCenter : undefined
        }

        ModuleList {
          visible: centerRoot.hasAnchor
          entries: root.entriesBefore(centerRoot.entries, root.centerAnchor)
          region: "center"
          anchors.right: centerRoot.notchLayout ? notchLeftEdge.left : centerAnchorModule.left
          anchors.verticalCenter: centerAnchorModule.verticalCenter
        }

        ModuleSlot {
          id: centerAnchorModule
          visible: centerRoot.hasAnchor
          entry: centerRoot.anchorEntry
          region: "center"
          anchors.centerIn: centerRoot.notchLayout ? undefined : parent
          anchors.left: centerRoot.notchLayout ? notchRightEdge.left : undefined
          anchors.verticalCenter: centerRoot.notchLayout ? parent.verticalCenter : undefined
        }
''')

    # 6. One-pixel repaint trigger (pixel value unchanged) for notchcast.
    text = replace_once(text, '''    WlrLayershell.namespace: "omarchy-bar"
    WlrLayershell.layer: WlrLayer.Top
''', '''    WlrLayershell.namespace: "omarchy-bar"
    WlrLayershell.layer: WlrLayer.Top

    // omarchy-notch-bar: repaint trigger, see notchPokeSerial.
    Rectangle {
      x: 0; y: 0; width: 1; height: 1; z: -1
      color: root.transparent ? "transparent" : root.background
      opacity: root.notchPokeSerial % 2 ? 0.999 : 1
    }
''')

    open(path, "w").write(text)
    print("patched")


if __name__ == "__main__":
    main()
