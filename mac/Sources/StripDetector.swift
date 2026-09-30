import AppKit

/// Where the notch strip is, when the VM is full screen on the built-in display.
struct StripGeometry: Equatable {
    /// Panel frame in Cocoa screen coordinates (origin bottom-left).
    var frame: NSRect
    /// Camera housing, as x offsets from the left edge of the display.
    var notchLeft: CGFloat
    var notchRight: CGFloat
    /// The VM's full-screen window on the built-in display.
    var windowID: CGWindowID
}

/// Finds the notch strip above a full-screen VM window using public APIs only.
///
/// The VM counts as full screen on the built-in display when a normal-layer
/// window of the VM app spans the display's full width, reaches its bottom
/// edge and covers at least 90 % of its height. The strip is the gap between
/// the top of the display and the top of that window (43 pt with Parallels).
enum StripDetector {
    static func builtinScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayIsBuiltin(n.uint32Value) != 0
        }
    }

    /// `onScreenOnly: false` also finds the VM's full-screen window while its
    /// Space is not the active one.
    static func detect(vmOwner: String, onScreenOnly: Bool = true) -> StripGeometry? {
        guard let screen = builtinScreen(),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
        else { return nil }
        let display = CGDisplayBounds(number.uint32Value)  // top-left origin
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements]
                                                       : [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list {
            guard (w[kCGWindowOwnerName as String] as? String) == vmOwner,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict)
            else { continue }
            guard r.minX == display.minX, r.width == display.width, r.maxY == display.maxY,
                  r.height >= display.height * 0.9, r.minY > display.minY
            else { continue }
            let height = r.minY - display.minY
            let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - height,
                               width: screen.frame.width, height: height)
            return StripGeometry(frame: frame,
                                 notchLeft: left.maxX - screen.frame.minX,
                                 notchRight: right.minX - screen.frame.minX,
                                 windowID: CGWindowID((w[kCGWindowNumber as String] as? Int) ?? 0))
        }
        return nil
    }

    /// Whether the window is still the VM's full-screen window on the built-in
    /// display, wherever its Space currently is. Only its size is compared: the
    /// origin moves while a Space slides in or out.
    static func stillFullScreen(_ id: CGWindowID) -> Bool {
        guard let screen = builtinScreen(),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: dict)
        else { return false }
        let display = CGDisplayBounds(number.uint32Value)
        return r.width == display.width && r.height >= display.height * 0.9
    }
}
