import AppKit

/// Omanotch, the macOS side.
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
        FileHandle.standardError.write(Data("\(ts) omanotch: \(message)\n".utf8))
    }
}

struct Settings {
    let defaults = UserDefaults.standard  // domain ch.gillesgoetsch.omanotch (bundle id)

    /// Listen on this one address instead of every VM network interface.
    var listenHost: String? { defaults.string(forKey: "listenHost") }
    var port: UInt16 { UInt16(defaults.integer(forKey: "port")).nonZero ?? 47811 }
    /// Interfaces that carry VM networks: Parallels and UTM (vmnet) use
    /// bridgeNNN, older Parallels versions vnicN.
    var interfacePrefixes: [String] { defaults.stringArray(forKey: "vmInterfacePrefixes") ?? ["bridge", "vnic"] }
    /// The VM shared networks: UTM (vmnet), Parallels shared and host-only.
    var vmSubnets: [String] {
        defaults.stringArray(forKey: "vmSubnets") ?? ["192.168.64.0/24", "10.211.55.0/24", "10.37.129.0/24"]
    }
    /// Owner names (app names) of the VM windows: Parallels Desktop and UTM.
    var vmOwners: Set<String> {
        if let list = defaults.stringArray(forKey: "vmOwners"), !list.isEmpty { return Set(list) }
        if let one = defaults.string(forKey: "vmOwner") { return [one] }
        return ["Parallels Desktop", "UTM"]
    }
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
    /// The VM's full-screen window on the built-in display, tracked across Spaces.
    private var vmWindow: CGWindowID?
    private var misses = 0
    /// Set when the pointer left the strip; the guest cursor is shown again
    /// where the pointer lands in a VM window.
    private var pendingGuestCursor = false
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
        cursorHider = VMCursorHider(vmOwners: settings.vmOwners, ownOwner: "Omanotch")
        cursorHider.onEnterVM = { [weak self] point, rect in self?.pointerEnteredVM(at: point, window: rect) }
        cursorHider.start()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.cursorHider.stop() }
        link = GuestLink(port: settings.port, interfacePrefixes: settings.interfacePrefixes,
                         subnets: settings.vmSubnets, onlyAddress: settings.listenHost, stream: stream)
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
        // apps' windows; a cheap once-a-second poll covers it (Space, app and
        // screen changes are handled at once through the notifications above).
        // Timer tolerance lets macOS batch the wake-ups with others.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.evaluate() }
        pollTimer?.tolerance = 0.2
        // The guest notices a vanished helper through the connection itself;
        // this only has to beat its watchdog (15 s) comfortably.
        beatTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.heartbeat() }
        beatTimer?.tolerance = 0.5
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
        // Only the connected guest's own VM app counts, once it has said which.
        let owners = guestOwner.map { settings.vmOwners.contains($0) ? [$0] : settings.vmOwners } ?? settings.vmOwners
        let visibleNow = ready ? StripDetector.detect(vmOwners: owners) : nil

        if let g = visibleNow {
            misses = 0
            vmWindow = g.windowID
            if g != geometry || panel?.isVisible != true || panel?.isOnActiveSpace != true {
                showPanel(g)
                sendGeometry(g)
            }
            geometry = g
        } else if ready, let id = vmWindow, let g = geometry,
                  StripDetector.stillFullScreen(id, stripHeight: g.frame.height) {
            // The VM's Space is not in front (or is sliding): keep everything as
            // is, so the panel moves with that Space.
            misses = 0
        } else if !ready {
            vmWindow = nil
            geometry = nil
            hidePanel()
        } else if vmWindow != nil || geometry != nil {
            // Gone or no longer full screen; require two checks in a row.
            misses += 1
            if misses >= 2 {
                vmWindow = nil
                geometry = nil
                hidePanel()
            }
        }
        setParked(ready && vmWindow != nil)
        // The macOS cursor is only hidden over the app whose VM feeds the strip.
        cursorHider?.activeOwner = parked ? geometry?.owner : nil
        view?.activeOwner = parked ? geometry?.owner : nil
    }

    private func setParked(_ on: Bool) {
        guard on != parked else { return }
        parked = on
        link.send("park \(on ? 1 : 0)")
        Log.info(on ? "strip shown, guest bar parked" : "strip hidden, guest bar restored")
    }

    private var beats = 0

    /// Tells the guest where the camera housing is and how tall the strip is,
    /// so the hidden output (and the bar in it) fill the strip exactly.
    private func sendGeometry(_ g: StripGeometry) {
        // In guest logical px, which differ from points when the guest display
        // does not match the Mac point for point.
        // Points and the strip's width: notchcast converts with the guest
        // display's own width (robust while its hidden output is resized).
        link.send(String(format: "geom %.1f %.1f %.1f %.1f", g.notchLeft, g.notchRight, g.frame.height, g.frame.width))
        // Older notchcast builds only know these, converted here.
        let k = view?.guestPerPoint ?? 1
        link.send("notch \(Int((g.notchLeft * k).rounded())) \(Int((g.notchRight * k).rounded()))")
        link.send("strip \(Int((g.frame.height * k).rounded()))")
    }

    /// Re-asserts the parked state every two seconds. notchcast turns this
    /// into a heartbeat file for the bar and re-parks a restarted Omarchy
    /// shell (which starts unparked). The notch geometry is refreshed too;
    /// notchcast only passes it on when it changed.
    private func heartbeat() {
        guard parked else { return }
        link.send("park 1")
        beats += 1
        if beats % 5 == 0, let g = geometry {
            sendGeometry(g)
        }
    }

    private func connectionChanged(_ connected: Bool) {
        parked = false
        guestOwner = nil
        guestLocked = false
        view?.locked = false
        if connected {
            link.send("targets")
            if let g = geometry { sendGeometry(g) }
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
            showFrame()
        }
    }

    /// Since when frames have had a shape that does not fit the strip.
    private var misfitSince: Date?

    /// Shows the latest frame. While the guest's hidden output is being
    /// resized (a display change, a Hyprland reload), frames can briefly have
    /// a shape that does not fit the strip; the last good frame stays up for
    /// up to two seconds instead, so the strip does not visibly jump.
    private func showFrame(force: Bool = false) {
        guard let view, let image = stream.makeImage() else { return }
        if !force, view.bounds.width > 0, view.bounds.height > 0, view.hasImage {
            // In guest logical px: the strip's height at this image's width,
            // against the image's height. A few px off is whole-pixel rounding
            // of the hidden output (fractional scales), not a resize.
            let w = CGFloat(image.width) / stream.scale, h = CGFloat(image.height) / stream.scale
            let expected = view.bounds.height * w / view.bounds.width
            if abs(h - expected) > max(4, expected * 0.03) {
                let since = misfitSince ?? Date()
                if misfitSince == nil {
                    misfitSince = since
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.05) { [weak self] in
                        guard let self, self.misfitSince == since else { return }
                        self.showFrame(force: true)  // it is how the guest looks now
                    }
                }
                if Date().timeIntervalSince(since) < 2 { return }
            } else {
                misfitSince = nil
            }
        }
        let bg = stream.backgroundColor()
        view.show(image: image, scale: stream.scale, background: bg == lastBackground ? nil : bg)
        lastBackground = bg
    }

    private var cursorImages: [String: (CGImage, CGPoint)] = [:]
    /// The guest is on its lock screen (see StripView.locked).
    private var guestLocked = false
    /// The app whose VM the connected guest runs in, from its "hello"
    /// (nil: not said, any VM app).
    private var guestOwner: String?
    private var arrowCursor: NSCursor?
    private var pointerCursor: NSCursor?

    /// Guest cursors are sized for its display (e.g. 48 px for 24 pt at 2x).
    private func setCursor(name: String, image: CGImage, hotSpot: CGPoint, nominal: Int) {
        Log.info("guest cursor \(name): \(image.width)x\(image.height) px")
        cursorImages[name] = (image, hotSpot)
        buildCursor(name)
    }

    /// The guest cursor as it looks in the VM window: N px at guest scale S
    /// are N/S guest logical px, which are N/(S*k) strip points.
    private func buildCursor(_ name: String) {
        guard let (image, hotSpot) = cursorImages[name] else { return }
        let d = stream.scale * (view?.guestPerPoint ?? 1)
        let cursor = NSCursor(image: NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / d,
                                                                          height: CGFloat(image.height) / d)),
                              hotSpot: NSPoint(x: hotSpot.x / d, y: hotSpot.y / d))
        switch name {
        case "arrow": arrowCursor = cursor; view?.arrowCursor = cursor
        case "pointer": pointerCursor = cursor; view?.pointerCursor = cursor
        default: break
        }
    }

    private func handleText(_ text: String) {
        if text == "lock 1" || text == "lock 0" {
            guestLocked = text == "lock 1"
            view?.locked = guestLocked
            Log.info(guestLocked ? "guest session locked: strip blank" : "guest session unlocked")
        } else if text.hasPrefix("hello ") {
            let hv = text.dropFirst("hello ".count)
            guestOwner = hv == "parallels" ? "Parallels Desktop" : hv == "qemu" ? "UTM" : nil
            Log.info("guest runs in \(hv) (\(guestOwner ?? "any VM app"))")
            evaluate()
        } else if text.hasPrefix("targets ") {
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
            v.vmOwners = settings.vmOwners
            v.locked = guestLocked
            v.onGuestScaleChange = { [weak self] in
                guard let self else { return }
                Log.info(String(format: "guest bar: %.3f logical px per strip point", self.view?.guestPerPoint ?? 1))
                // Cursors first: they must follow even while the strip is hidden.
                for name in self.cursorImages.keys { self.buildCursor(name) }
                if let g = self.geometry { self.sendGeometry(g) }
            }
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
            pendingGuestCursor = false
            link.send("cursor 0")
            cursorHider.pointerOnStrip(showAfter: 0.045)
            link.send("targets")
        } else if exit != nil {
            // Show the guest cursor once the pointer lands in a VM window (at
            // that exact spot, see pointerEnteredVM). If it lands elsewhere,
            // show it anyway after a moment so it is never left hidden.
            pendingGuestCursor = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.pendingGuestCursor else { return }
                self.pendingGuestCursor = false
                self.link.send("cursor 1")
            }
        } else {
            pendingGuestCursor = false
            link.send("cursor 1")
        }
    }

    /// The pointer arrived over a full-screen VM window (CG coordinates).
    private func pointerEnteredVM(at p: CGPoint, window: CGRect) {
        guard pendingGuestCursor, let screen = StripDetector.builtinScreen(),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return }
        pendingGuestCursor = false
        let builtin = CGDisplayBounds(number.uint32Value)
        let x = p.x - builtin.minX
        // In guest logical px: the guest may not match the Mac point for point.
        let k = view?.guestPerPoint ?? 1
        if window.maxY == builtin.maxY {
            // Back into the built-in display's VM window, below the strip.
            link.send(String(format: "cursor 1 down %.1f %.1f", x * k, (p.y - window.minY) * k))
        } else if window.maxY <= builtin.minY {
            // Up to the display above.
            link.send(String(format: "cursor 1 up %.1f %.1f", x * k, window.maxY - p.y))
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
