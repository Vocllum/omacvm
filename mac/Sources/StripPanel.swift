import AppKit
import QuartzCore

/// Borderless panel over the notch strip. It never becomes key or main, so the
/// VM keeps keyboard focus when the strip is clicked.
final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        worksWhenModal = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isMovable = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        // Parallels keeps an invisible window over the strip at level 26 and the
        // menu bar sits at 24, so the panel must be at 27 or above.
        level = NSWindow.Level(27)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
                              .fullScreenDisallowsTiling]
    }
}

/// Input from the strip, in bar coordinates (logical guest px == macOS points).
protocol StripInputDelegate: AnyObject {
    func stripClicked(x: CGFloat, y: CGFloat, button: Int)
    func stripScrolled(x: CGFloat, y: CGFloat, steps: Int)
    func stripHoverChanged(_ inside: Bool)
}

/// Draws the mirrored bar and turns mouse events into bar coordinates.
final class StripView: NSView {
    weak var input: StripInputDelegate?
    private let barLayer = CALayer()
    /// Height of the bar image in points (26 for Omarchy's default bar).
    private var barHeight: CGFloat = 26
    private var barWidth: CGFloat = 0
    /// Clickable rectangles in bar coordinates, reported by the guest.
    var targets: [CGRect] = []
    /// The guest's cursors, so the strip shows the same cursor as the VM.
    var arrowCursor: NSCursor = .arrow
    var pointerCursor: NSCursor = .pointingHand
    private(set) var isHovered = false
    private var scrollAccumulator: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = NSColor.black.cgColor
        barLayer.contentsGravity = .resize
        barLayer.magnificationFilter = .nearest
        barLayer.minificationFilter = .linear
        barLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(barLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    /// Shows a new bar image. `scale` is the guest output scale.
    func show(image: CGImage, scale: CGFloat, background: CGColor?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barWidth = CGFloat(image.width) / scale
        barHeight = CGFloat(image.height) / scale
        barLayer.contents = image
        barLayer.contentsScale = scale
        if let background { layer?.backgroundColor = background }
        layoutBar()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutBar()
        CATransaction.commit()
    }

    /// Vertical offset of the bar image inside the strip (bar centred).
    private var barTop: CGFloat { ((bounds.height - barHeight) / 2).rounded(.down) }

    private func layoutBar() {
        // Layer geometry is bottom-left based even in a flipped view.
        let y = bounds.height - barTop - barHeight
        barLayer.frame = CGRect(x: 0, y: y, width: barWidth > 0 ? barWidth : bounds.width, height: barHeight)
    }

    // MARK: input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited,
                                                          .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func barPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let y = min(max(p.y - barTop, 0.5), barHeight - 0.5)
        return CGPoint(x: p.x, y: y)
    }

    private func updateCursor(_ event: NSEvent) {
        let p = barPoint(event)
        if targets.contains(where: { $0.contains(p) }) {
            pointerCursor.set()
        } else {
            arrowCursor.set()
        }
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(event) }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        input?.stripHoverChanged(true)
        updateCursor(event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        input?.stripHoverChanged(false)
        // Leaving into a VM window: show nothing, like Parallels does there
        // (the guest draws its own cursor). Parallels does not reliably reset
        // the cursor when the pointer comes from another app's window, which
        // would leave a macOS arrow on top of the guest cursor.
        if let screenPoint = window?.convertPoint(toScreen: event.locationInWindow),
           StripView.isOverVMWindow(screenPoint, vmOwner: vmOwner) {
            BackgroundCursor.transparent.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// Owner name of the VM windows (set by the controller).
    var vmOwner = "Parallels Desktop"

    /// Whether a point just outside the strip (Cocoa screen coordinates) lies
    /// on a normal-layer window of the VM app.
    static func isOverVMWindow(_ cocoaPoint: NSPoint, vmOwner: String) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let cg = CGPoint(x: cocoaPoint.x, y: primary.frame.maxY - cocoaPoint.y)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer >= 0, layer < 1000,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict), r.insetBy(dx: 0, dy: -2).contains(cg)
            else { continue }
            if (w[kCGWindowAlpha as String] as? Double ?? 1) == 0 { continue }
            if w[kCGWindowOwnerName as String] as? String == "Omarchy Notch Bar" { continue }
            return w[kCGWindowOwnerName as String] as? String == vmOwner && layer == 0
        }
        return false
    }

    /// Called when the panel hides while the pointer may still be over it.
    func resetHover() {
        guard isHovered else { return }
        isHovered = false
        input?.stripHoverChanged(false)
    }

    override func mouseDown(with event: NSEvent) { click(event, button: 1) }
    override func rightMouseDown(with event: NSEvent) { click(event, button: 2) }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { click(event, button: 3) }
    }

    private func click(_ event: NSEvent, button: Int) {
        let p = barPoint(event)
        input?.stripClicked(x: p.x, y: p.y, button: button)
    }

    override func scrollWheel(with event: NSEvent) {
        // Convert to physical wheel direction (positive = away from the user),
        // which is what Qt's angleDelta uses, regardless of natural scrolling.
        var dy = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { dy = -dy }
        if event.phase == .began || event.phase == .mayBegin { scrollAccumulator = 0 }
        let stepSize: CGFloat = event.hasPreciseScrollingDeltas ? 24 : 1
        scrollAccumulator += dy
        let steps = Int((scrollAccumulator / stepSize).rounded(.towardZero))
        if steps != 0 {
            scrollAccumulator -= CGFloat(steps) * stepSize
            let p = barPoint(event)
            input?.stripScrolled(x: p.x, y: p.y, steps: steps)
        }
    }
}
