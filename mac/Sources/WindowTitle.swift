import AppKit

/// Window titles through Accessibility. VM apps put the VM's name in the
/// title; the window list only gives names with Screen Recording permission.
enum WindowTitle {
    /// The title of the app's window at `rect` (CG coordinates), else of its
    /// focused or main window. nil without Accessibility permission.
    static func title(pid: pid_t, rect: CGRect) -> String? {
        guard pid > 0, AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // A busy VM app must not stall the main thread.
        AXUIElementSetMessagingTimeout(app, 0.2)
        // The window at that spot. More than one (two full-screen VMs while a
        // Space slides): the focused one decides.
        var titles: [String] = []
        for w in value(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            AXUIElementSetMessagingTimeout(w, 0.2)
            if let frame = frame(w), abs(frame.minX - rect.minX) < 2, abs(frame.minY - rect.minY) < 2,
               abs(frame.width - rect.width) < 2, abs(frame.height - rect.height) < 2,
               let t = value(w, kAXTitleAttribute) as? String {
                titles.append(t)
            }
        }
        if titles.count == 1 { return titles[0] }
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            guard let v = value(app, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { continue }
            let w = v as! AXUIElement
            AXUIElementSetMessagingTimeout(w, 0.2)
            if let t = value(w, kAXTitleAttribute) as? String { return t }
        }
        return nil
    }

    private static var asked = false

    /// Asks for Accessibility permission once per run (macOS shows its dialog).
    static func askOnce() {
        guard !asked, !AXIsProcessTrusted() else { return }
        asked = true
        Log.info("several guests connected: Accessibility permission is needed to tell their windows apart")
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static func value(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
        return v
    }

    private static func frame(_ w: AXUIElement) -> CGRect? {
        guard let p = value(w, kAXPositionAttribute), let s = value(w, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
