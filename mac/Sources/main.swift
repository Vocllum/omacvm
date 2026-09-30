import AppKit

/// omarchy-notch-bar macOS helper.
///
/// Shows the real Omarchy bar, streamed from the VM, in the MacBook notch strip
/// while the VM is full screen on the built-in display, and sends clicks and
/// scrolling back. While the strip is shown the guest hides its own bar on the
/// built-in display ("park"); a heartbeat keeps it hidden, so the guest shows
/// its bar again by itself if this helper stops.
enum Log {
    static func info(_ message: String) {
        let ts = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                             formatOptions: [.withTime, .withColonSeparatorInTime])
        FileHandle.standardError.write(Data("\(ts) notchbar: \(message)\n".utf8))
    }
}

struct Settings {
    let defaults = UserDefaults.standard  // domain ch.gillesgoetsch.notchbar (bundle id)

    /// Host side of the Parallels shared network (the guest connects here).
    var listenHost: String { defaults.string(forKey: "listenHost") ?? "10.211.55.2" }
    var port: UInt16 { UInt16(defaults.integer(forKey: "port")).nonZero ?? 47811 }
    /// Only guests whose address starts with this are accepted.
    var guestPrefix: String { defaults.string(forKey: "guestPrefix") ?? "10.211.55." }
    /// Owner name of the VM's full-screen window.
    var vmOwner: String { defaults.string(forKey: "vmOwner") ?? "Parallels Desktop" }
}

extension UInt16 {
    var nonZero: UInt16? { self == 0 ? nil : self }
}

final class Controller: NSObject, NSApplicationDelegate, StripInputDelegate {
    private let settings = Settings()
    private let stream = GuestStream()
    private var link: GuestLink!
    private var panel: StripPanel?
    private var view: StripView?
    private var geometry: StripGeometry?
    private var parked = false
    private var pollTimer: Timer?
    private var beatTimer: Timer?
    private var lastBackground: CGColor?
    private var cursorHider: VMCursorHider!
    /// Keeps timers running on schedule (App Nap would stretch the 1 s
    /// heartbeat past the guest's 5 s watchdog).
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = BackgroundCursor.enabled
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Mirrors the VM bar into the notch strip")
        cursorHider = VMCursorHider(vmOwner: settings.vmOwner, ownOwner: "Omarchy Notch Bar")
        cursorHider.start()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.cursorHider.stop() }
        link = GuestLink(host: settings.listenHost, port: settings.port, allowedPrefix: settings.guestPrefix,
                         stream: stream)
        link.onMessages = { [weak self] in self?.handle($0) }
        link.onConnectionChange = { [weak self] connected in self?.connectionChanged(connected) }
        link.start()

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.evaluate() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.evaluate() }
        // Entering and leaving full screen has no public notification for other
        // apps' windows; a cheap poll covers it.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.evaluate() }
        beatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.heartbeat() }
        evaluate()
        Log.info("started")
    }

    // MARK: state

    /// Decides whether the strip is shown, and tells the guest.
    ///
    /// The panel lives on the VM's full-screen Space: it is ordered in while
    /// that Space is active and then left alone, so it moves with the Space
    /// when switching. It is only removed when the VM leaves full screen on the
    /// built-in display (or the guest goes away). The guest bar stays parked
    /// meanwhile, so the VM does not re-layout on every Space switch.
    private func evaluate() {
        cursorHider?.refresh()
        let ready = link.isConnected && stream.hasImage
        let visibleNow = ready ? StripDetector.detect(vmOwner: settings.vmOwner) : nil
        let anySpace = ready ? (visibleNow ?? StripDetector.detect(vmOwner: settings.vmOwner, onScreenOnly: false)) : nil

        if let g = visibleNow {
            if g != geometry || panel?.isVisible != true || panel?.isOnActiveSpace != true {
                showPanel(g)
                link.send("notch \(Int(g.notchLeft)) \(Int(g.notchRight))")
            }
            geometry = g
        } else if anySpace == nil, geometry != nil {
            geometry = nil
            hidePanel()
        }
        setParked(anySpace != nil)
    }

    private func setParked(_ on: Bool) {
        guard on != parked else { return }
        parked = on
        link.send("park \(on ? 1 : 0)")
        Log.info(on ? "strip shown, guest bar parked" : "strip hidden, guest bar restored")
    }

    private var beats = 0

    /// Re-asserts the parked state every second rather than only sending a
    /// heartbeat, so a restarted Omarchy shell (which starts unparked) is
    /// parked again within a second. The notch geometry is refreshed as well.
    private func heartbeat() {
        guard parked else { return }
        link.send("park 1")
        beats += 1
        if beats % 5 == 0, let g = geometry {
            link.send("notch \(Int(g.notchLeft)) \(Int(g.notchRight))")
        }
    }

    private func connectionChanged(_ connected: Bool) {
        parked = false
        if connected {
            link.send("targets")
        }
        evaluate()
    }

    private func handle(_ messages: [GuestMessage]) {
        var gotFrame = false
        for m in messages {
            switch m {
            case .frame:
                gotFrame = true
            case .text(let text):
                handleText(text)
            case let .cursor(name, image, hotSpot, nominal):
                setCursor(name: name, image: image, hotSpot: hotSpot, nominal: nominal)
            }
        }
        if gotFrame {
            if panel == nil || geometry == nil { evaluate() }
            guard let view, let image = stream.makeImage() else { return }
            let bg = stream.backgroundColor()
            view.show(image: image, scale: stream.scale, background: bg == lastBackground ? nil : bg)
            lastBackground = bg
        }
    }

    private var arrowCursor: NSCursor?
    private var pointerCursor: NSCursor?

    /// Guest cursors are sized for its display (e.g. 48 px for 24 pt at 2x).
    private func setCursor(name: String, image: CGImage, hotSpot: CGPoint, nominal: Int) {
        // A guest cursor of nominal size N px at output scale S is N/S points.
        let points = NSSize(width: CGFloat(image.width) / stream.scale, height: CGFloat(image.height) / stream.scale)
        let cursor = NSCursor(image: NSImage(cgImage: image, size: points),
                              hotSpot: NSPoint(x: hotSpot.x / stream.scale, y: hotSpot.y / stream.scale))
        Log.info("guest cursor \(name): \(image.width)x\(image.height) px")
        switch name {
        case "arrow": arrowCursor = cursor; view?.arrowCursor = cursor
        case "pointer": pointerCursor = cursor; view?.pointerCursor = cursor
        default: break
        }
    }

    private func handleText(_ text: String) {
        if text.hasPrefix("targets ") {
            let json = Data(text.dropFirst("targets ".count).utf8)
            if let arr = try? JSONSerialization.jsonObject(with: json) as? [[Double]] {
                view?.targets = arr.filter { $0.count == 4 }.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
            }
        }
    }

    // MARK: panel

    private func showPanel(_ g: StripGeometry) {
        if panel == nil {
            let p = StripPanel(frame: g.frame)
            let v = StripView(frame: NSRect(origin: .zero, size: g.frame.size))
            v.autoresizingMask = [.width, .height]
            v.input = self
            v.vmOwner = settings.vmOwner
            if let arrowCursor { v.arrowCursor = arrowCursor }
            if let pointerCursor { v.pointerCursor = pointerCursor }
            p.contentView = v
            panel = p
            view = v
            if let image = stream.makeImage() {
                v.show(image: image, scale: stream.scale, background: stream.backgroundColor())
            }
            link.send("targets")
        }
        panel?.setFrame(g.frame, display: true)
        panel?.orderFrontRegardless()
    }

    private func hidePanel() {
        view?.resetHover()
        panel?.orderOut(nil)
    }

    // MARK: StripInputDelegate

    func stripClicked(x: CGFloat, y: CGFloat, button: Int) {
        link.send(String(format: "click %.1f %.1f %d", x, y, button))
        // Widgets can change size after a click (e.g. a panel toggles an icon).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.link.send("targets") }
    }

    func stripScrolled(x: CGFloat, y: CGFloat, steps: Int) {
        link.send(String(format: "wheel %.1f %.1f %d", x, y, steps * 120))
    }

    func stripHoverChanged(_ inside: Bool, exit: (direction: String, x: CGFloat)?) {
        // Only one cursor at a time: the guest hides its own while the pointer
        // is over the strip, where the helper shows the guest's cursor images.
        if inside {
            cursorHider.pointerOnStrip()
            link.send("cursor 0")
            link.send("targets")
        } else if let exit {
            // Put the guest cursor where the pointer leaves, then show it.
            link.send(String(format: "cursor 1 %@ %.1f", exit.direction, exit.x))
        } else {
            link.send("cursor 1")
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
app.delegate = controller
app.run()
