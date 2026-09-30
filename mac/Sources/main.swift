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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
    private func evaluate() {
        let g = link.isConnected && stream.hasImage ? StripDetector.detect(vmOwner: settings.vmOwner) : nil
        if g != geometry {
            geometry = g
            if let g {
                showPanel(g)
                link.send("notch \(Int(g.notchLeft)) \(Int(g.notchRight))")
            } else {
                hidePanel()
            }
        }
        setParked(g != nil)
    }

    private func setParked(_ on: Bool) {
        guard on != parked else { return }
        parked = on
        link.send("park \(on ? 1 : 0)")
        Log.info(on ? "strip shown, guest bar parked" : "strip hidden, guest bar restored")
    }

    private func heartbeat() {
        if parked { link.send("beat") }
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

    func stripHoverChanged(_ inside: Bool) {
        if inside { link.send("targets") }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
app.delegate = controller
app.run()
