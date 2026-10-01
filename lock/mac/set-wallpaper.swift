// set-wallpaper <image>: set the desktop picture (and with it the macOS lock
// screen background) on every display, fill mode.
import AppKit
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let opts: [NSWorkspace.DesktopImageOptionKey: Any] = [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true]
var failed = false
for screen in NSScreen.screens {
  do { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: opts) }
  catch { print("set-wallpaper: \(screen.localizedName): \(error)"); failed = true }
}
exit(failed ? 1 : 0)
