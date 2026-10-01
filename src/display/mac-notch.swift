// Print "notch" if this Mac's built-in display has a camera notch, else "none".
// build.sh offers Omanotch (Omarchy's bar beside the notch) only where it fits.
import AppKit
let builtin = NSScreen.screens.first { s in
  (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) != 0 } ?? false
}
print(builtin?.auxiliaryTopLeftArea != nil ? "notch" : "none")
