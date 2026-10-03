import AppKit
import Foundation

/// Runs one VM: QEMU with its own Cocoa window (VirGL), a QMP socket for
/// power and pause, and the Mac's sleep and wake.
@MainActor
final class Runner {
    let config: VMConfig
    private(set) var process: Process?
    private let sleep = VMHostSleepCoordinator()
    private var observers: [NSObjectProtocol] = []
    var onExit: ((Int32) -> Void)?

    init(config: VMConfig) { self.config = config }

    var isRunning: Bool { process?.isRunning ?? false }

    func arguments() -> [String] {
        let c = config
        var a: [String] = [
            "-name", c.name,
            "-machine", "virt,gic-version=3",
            "-accel", "hvf",
            // HVF has no usable guest PMU on Apple Silicon.
            "-cpu", "host,pmu=off",
            "-smp", "\(c.cpus),sockets=1,cores=\(c.cpus),threads=1",
            "-m", "\(c.memoryMB)M",
            "-nodefaults",
            "-action", "reboot=reset,shutdown=poweroff",
            // UEFI firmware (read-only) and this VM's own boot variables.
            "-drive", "if=pflash,format=raw,readonly=on,file=\(Paths.firmware.path)",
            "-drive", "if=pflash,format=raw,file=\(c.efiVars.path)",
            "-drive", "if=none,id=disk,file=\(c.disk.path),format=raw,cache=writeback,discard=unmap",
            "-device", "nvme,serial=omacvm,drive=disk,bootindex=0",
            // QEMU's user network: the Mac is 10.0.2.2 for the VM; SSH from the Mac on 127.0.0.1.
            "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:\(c.sshPort)-:22",
            "-device", "virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56,romfile=",
            "-device", "virtio-gpu-gl-pci,max_outputs=1,xres=1920,yres=1080,romfile=",
            "-display", "cocoa,gl=on,show-cursor=on,zoom-to-fit=on,full-screen=\(Settings.startFullScreen ? "on" : "off"),full-grab=on,immersive=on,swap-opt-cmd=off",
            "-device", "virtio-keyboard-pci,romfile=",
            "-device", "virtio-tablet-pci,romfile=",
            "-object", "rng-random,id=rng0,filename=/dev/urandom",
            "-device", "virtio-rng-pci,rng=rng0",
            // Linux reports free memory, so the Mac gets it back.
            "-device", "virtio-balloon-pci,free-page-reporting=on",
            "-audiodev", "sdl,id=snd0,timer-period=1000,out.buffer-count=8",
            "-device", "intel-hda,id=hda0,romfile=",
            "-device", "hda-micro,bus=hda0.0,audiodev=snd0",
            "-serial", "none",
            "-monitor", "none",
            "-qmp", "unix:\(c.qmpSocket.path),server=on,wait=off",
        ]
        // Notch mode: the guest learns the strip's height (OEM strings, omacvm-app-host).
        if Settings.useNotch, let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            let k = s.backingScaleFactor
            let rows = Int((s.safeAreaInsets.top * k).rounded(.up))
            let size = "\(Int(s.frame.width * k))x\(Int(s.frame.height * k))"
            a += ["-smbios", "type=11,value=omacvm.notch=\(rows),value=omacvm.screen=\(size)"]
        }
        let console = c.folder.appendingPathComponent("logs/console.log").path
        a += ["-device", "virtio-serial-pci,id=vser0",
              "-chardev", "file,id=hvc0,path=\(console.replacingOccurrences(of: ",", with: ",,"))",
              "-device", "virtconsole,bus=vser0.0,nr=0,chardev=hvc0",
              // QEMU guest agent: a clean shutdown even when the power key is ignored.
              "-chardev", "socket,id=qga0,path=\(c.agentSocket.path),server=on,wait=off",
              "-device", "virtserialport,bus=vser0.0,nr=1,chardev=qga0,name=org.qemu.guest_agent.0"]
        return a
    }

    func start() throws {
        let c = config
        try FileManager.default.createDirectory(at: c.folder.appendingPathComponent("logs"),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: c.qmpSocket)
        let p = Process()
        p.executableURL = Paths.qemu
        p.arguments = arguments()
        var env = ProcessInfo.processInfo.environment
        env["OMACVM_PRODUCT_NAME"] = Product.name
        if let icon = Paths.icon { env["OMACVM_ICON"] = icon.path }
        env["OMACVM_NOTCH"] = Settings.useNotch && Mac.hasNotch ? "1" : "0"
        p.environment = env
        let logURL = c.folder.appendingPathComponent("logs/qemu.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                self?.stopObserving()
                self?.onExit?(status)
            }
        }
        try p.run()
        process = p
        observeSleep()
    }

    /// Asks the guest to shut down: the power button, then the guest agent
    /// if Omarchy is still up after 20 seconds.
    func powerDown() {
        let qmpPath = config.qmpSocket.path, agentPath = config.agentSocket.path
        Task.detached {
            if let qmp = try? QMPConnection(socketPath: qmpPath, identifierPrefix: "omacvm-power") {
                _ = try? qmp.execute("system_powerdown")
                qmp.close()
            }
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            GuestAgent.shutdown(socketPath: agentPath)
        }
    }

    /// Stops QEMU at once (the guest gets no chance to save anything).
    func forceStop() { process?.terminate() }

    // MARK: Mac sleep: pause the VM before, resume after (from try-omarchy).

    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        })
        // The socket appears a moment after QEMU starts.
        Task { [weak self] in
            for _ in 0..<50 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                if FileManager.default.fileExists(atPath: self.config.qmpSocket.path) {
                    if (try? self.sleep.connect(to: self.config.qmpSocket.path)) != nil { return }
                }
            }
        }
    }

    private func willSleep() {
        try? sleep.prepareForHostSleep(vmIsRunning: isRunning, isStopping: false)
    }

    private func didWake() {
        do {
            try sleep.resumeAfterHostWake(vmIsRunning: isRunning, isStopping: false)
        } catch {
            sleep.scheduleWakeRetry { [weak self] in self?.didWake() }
        }
    }

    private func stopObserving() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        sleep.disconnect()
    }
}
