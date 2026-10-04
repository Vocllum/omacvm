// From try-omarchy (github.com/omacom/try-omarchy), MIT, (c) Try Omarchy contributors:
// macos/Sources/OmarchyVMHelper/NativeBatteryBridge.swift, for OmacVM's port.
import Darwin
import Foundation
import IOKit.ps

/// The Mac's battery to the VM over the virtio port org.omacvm.battery:
/// one JSON snapshot per line (HostBattery.swift) on every change of the
/// Mac's power sources and every 30 seconds. The VM's agent (omacvm-battery)
/// asks for one when it starts ({"type":"refresh"}); nothing is sent before
/// that, so a VM without the agent never fills the port. Any other line
/// from the VM is ignored: it cannot change anything on the Mac.
final class NativeBatteryBridge: @unchecked Sendable {
    static let heartbeatSeconds = 30.0
    static let maximumLineBytes = 4096

    private let descriptor: Int32
    private let stateQueue = DispatchQueue(label: "org.omacvm.battery-bridge")
    private let stopLock = NSLock()
    private var lastSent: HostBatterySnapshot?
    private var guestListening = false
    private var heartbeat: DispatchSourceTimer?
    private var powerSource: CFRunLoopSource?
    private var notificationRunLoop: CFRunLoop?
    private var stopped = false

    init(socketPath: String) throws {
        descriptor = try NativeBridgeSocket.connectSecure(path: socketPath, label: "battery bridge")
    }

    deinit { stop() }

    /// In its own autorelease pool: run() never returns to one, and every
    /// line that is not JSON leaves an autoreleased NSError behind.
    static func isRefreshRequest(_ line: Data) -> Bool {
        autoreleasepool {
            (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["type"] as? String == "refresh"
        }
    }

    func run() throws {
        startPowerNotifications()
        startHeartbeat()
        var lines = BatteryLines()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                lines.feed(chunk[0..<count]) { line in
                    // In step with the write, so a VM that floods requests
                    // waits for its answers instead of queueing work here.
                    if Self.isRefreshRequest(line) {
                        stateQueue.sync { guestListening = true; sendOnQueue(forced: true) }
                    }
                }
            } else if count == 0 {
                return
            } else if errno != EINTR {
                throw HelperError.io("cannot read the guest battery channel")
            }
        }
    }

    func stop() {
        stopLock.lock()
        guard !stopped else { stopLock.unlock(); return }
        stopped = true
        let source = powerSource, loop = notificationRunLoop
        powerSource = nil; notificationRunLoop = nil
        stopLock.unlock()
        heartbeat?.cancel()
        heartbeat = nil
        if let source, let loop { CFRunLoopRemoveSource(loop, source, .defaultMode) }
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func hasStopped() -> Bool {
        stopLock.lock(); defer { stopLock.unlock() }
        return stopped
    }

    private func registerPowerSource(_ source: CFRunLoopSource, on loop: CFRunLoop) -> Bool {
        stopLock.lock(); defer { stopLock.unlock() }
        guard !stopped else { return false }
        powerSource = source; notificationRunLoop = loop
        return true
    }

    /// IOKit's power notifications on a thread with its own run loop (run()
    /// blocks this one reading the port).
    private func startPowerNotifications() {
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            let context = Unmanaged.passUnretained(self).toOpaque()
            guard let source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                Unmanaged<NativeBatteryBridge>.fromOpaque(context).takeUnretainedValue().send(forced: false)
            }, context)?.takeRetainedValue() else {
                fputs("[battery-bridge] no IOKit power notifications; every 30 s only\n", stderr)
                return
            }
            let loop = CFRunLoopGetCurrent()!
            guard self.registerPowerSource(source, on: loop) else { return }
            CFRunLoopAddSource(loop, source, .defaultMode)
            while !self.hasStopped() { CFRunLoopRunInMode(.defaultMode, 1.0, false) }
        }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + Self.heartbeatSeconds, repeating: Self.heartbeatSeconds, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.sendOnQueue(forced: true) }   // already on stateQueue
        timer.resume()
        heartbeat = timer
    }

    private func send(forced: Bool) {
        stateQueue.async { [weak self] in self?.sendOnQueue(forced: forced) }
    }

    /// Only on stateQueue. Unchanged snapshots go only when forced.
    private func sendOnQueue(forced: Bool) {
        guard guestListening, !hasStopped() else { return }
        let snapshot = HostBatterySnapshot.capture()
        guard forced || snapshot != lastSent else { return }
        do {
            try NativeBridgeSocket.writeAll(snapshot.line, to: descriptor, label: "battery")
            lastSent = snapshot
        } catch {
            fputs("[battery-bridge] \(error.localizedDescription)\n", stderr)
            stop()
        }
    }
}

/// Splits what the VM sends into lines; a line over maximumLineBytes is
/// dropped (not fatal), up to its newline.
struct BatteryLines {
    private var line = Data(), skipping = false

    mutating func feed(_ chunk: ArraySlice<UInt8>, _ each: (Data) -> Void) {
        var start = chunk.startIndex
        for index in chunk.indices where chunk[index] == 0x0A {
            if !skipping {
                line.append(contentsOf: chunk[start..<index])
                each(line)
            }
            line.removeAll(keepingCapacity: true)
            skipping = false
            start = index + 1
        }
        if !skipping {
            line.append(contentsOf: chunk[start..<chunk.endIndex])
            if line.count > NativeBatteryBridge.maximumLineBytes { line.removeAll(); skipping = true }
        }
    }
}
