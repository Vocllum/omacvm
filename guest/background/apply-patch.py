#!/usr/bin/env python3
"""Patch a clone of Omarchy's background plugin (Background.qml) for Omanotch.

usage: apply-patch.py <Background.qml>        (patches the file in place)

Omarchy draws the wallpaper separately on every output, cropped to that
output. On the hidden NOTCH output (the strip beside the camera) that is a
thin, heavily zoomed slice of the middle of the image, which shows whenever
the bar is hidden (Super+Shift+Space). The patch lays the wallpaper out once
over the notch strip and the built-in display together, the way macOS lays out
a full-screen app that uses the notch area: the strip shows the top rows and
the built-in display the rest, so the image runs through behind the bar.

The built-in display is the output that shares its top-left corner with the
NOTCH output (both sit at the same position in Hyprland's layout). Without a
NOTCH output every screen draws the wallpaper exactly as before.

The patch is versioned like the bar patch; an older version is restored from
<Background.qml>.before-notchbar (kept by install.sh) and patched again.
"""
import os
import shutil
import sys

MARK = "omarchy-notch-bar"
VERSION = 2
VERSION_LINE = f"// omarchy-notch-bar background patch v{VERSION}"


def replace_once(text, old, new):
    count = text.count(old)
    if count != 1:
        sys.exit(f"apply-patch: expected exactly one match, found {count}:\n{old}")
    return text.replace(old, new)


def main():
    path = sys.argv[1]
    text = open(path).read()
    if VERSION_LINE in text:
        print(f"already patched (v{VERSION})")
        return
    if MARK in text:
        backup = path + ".before-notchbar"
        if not os.path.exists(backup) or MARK in open(backup).read():
            sys.exit(f"apply-patch: {path} carries an older patch and no clean backup exists; "
                     "re-clone the background (omarchy plugin clone omarchy.background) and run install.sh again")
        shutil.copyfile(backup, path)
        text = open(path).read()
        print("replacing an older patch version")

    # 1. Helpers that pair the NOTCH output with the built-in display.
    text = replace_once(text, '  function imageUrl(path) {\n', f'''  // --- omarchy-notch-bar ------------------------------------------------
  {VERSION_LINE}
  // The wallpaper spans the NOTCH strip and the built-in display as one
  // image; see notchCanvas below.
  function notchIsStrip(s) {{
    return !!s && String(s.name || "").indexOf("NOTCH") === 0
  }}
  function notchPeerOf(s) {{
    if (!s) return null
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {{
      var o = screens[i]
      if (o === s || notchIsStrip(o) === notchIsStrip(s)) continue
      if (o.x === s.x && o.y === s.y && o.width === s.width) return o
    }}
    return null
  }}
  // --- end omarchy-notch-bar --------------------------------------------

  function imageUrl(path) {{
''')

    # 2. On the strip the wallpaper sits on the overlay layer (ordered below the
    #    bar, above notification popups by notchbar.lua): with the bar hidden
    #    it covers the popups' top edge, which would otherwise show in the strip.
    text = replace_once(text, "      WlrLayershell.layer: WlrLayer.Background\n",
                        "      WlrLayershell.layer: root.notchIsStrip(panel.modelData) ? WlrLayer.Overlay : WlrLayer.Background\n")

    # 3. The shared canvas: the strip on top, the built-in display below it.
    text = replace_once(text, '''      Image {
        id: base
        anchors.fill: parent
''', '''      // omarchy-notch-bar: strip + built-in display as one area. On the
      // strip the canvas extends below the surface, on the built-in display
      // above it; the surface clips the rest.
      Item {
        id: notchCanvas
        readonly property var peer: root.notchPeerOf(panel.modelData)
        readonly property bool strip: root.notchIsStrip(panel.modelData)
        x: 0
        y: peer && !strip ? -peer.height : 0
        width: parent.width
        height: parent.height + (peer ? peer.height : 0)
      }

      Image {
        id: base
        anchors.fill: notchCanvas
''')
    text = replace_once(text, '''        id: oldFrame
        anchors.fill: parent
''', '''        id: oldFrame
        anchors.fill: notchCanvas
''')
    text = replace_once(text, '''        id: incomingLayer
        anchors.fill: parent
''', '''        id: incomingLayer
        anchors.fill: notchCanvas
''')
    text = replace_once(text, '''        id: revealMask
        anchors.fill: parent
''', '''        id: revealMask
        anchors.fill: notchCanvas
''')

    open(path, "w").write(text)
    print(f"patched (v{VERSION})")


if __name__ == "__main__":
    main()
