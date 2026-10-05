import AppKit
import OmacVMUpdate
import SwiftUI

/// The launcher: sets up the VM, starts it and steps aside. QEMU shows the VM
/// in its own window with the app's name and icon; when QEMU ends, so does this.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    var window: NSWindow?
    var runner: Runner?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Scripted install: --install-as NAME [--into FOLDER]
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--install-as"), i + 1 < args.count {
            let folder = args.firstIndex(of: "--into").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
            do {
                let app = try Installer.install(name: args[i + 1], into: folder ?? Installer.defaultFolder)
                print("installed \(app.path)")
                exit(0)
            } catch {
                FileHandle.standardError.write("install failed: \(error.localizedDescription)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        // Started by update-swap.sh after an update: check that this build
        // works (else the previous version goes back), then start as usual.
        if let i = args.firstIndex(of: "--update-check"), i + 1 < args.count {
            Updater.launchCheck(token: args[i + 1])
            // The update went in after the user quit or shut the VM down:
            // no window now. The next launch reads the result and says so.
            if args.contains("--update-quiet") {
                Updater.shared.log("started after the update (quiet: no window), quitting")
                exit(0)
            }
        }
        // One launcher at a time: a second one hands over to the first (a
        // start request too: `open -n ... --args --start --vm NAME`). The
        // copy that just installed this one is quitting: it does not count.
        let me = NSRunningApplication.current
        let installer = args.firstIndex(of: "--installed-by").flatMap { $0 + 1 < args.count ? pid_t(args[$0 + 1]) : nil }
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: {
               $0 != me && !$0.isTerminated && $0.processIdentifier != installer
           }) {
            if args.contains("--update-now") {
                DistributedNotificationCenter.default().postNotificationName(
                    Self.updateRequest, object: nil, userInfo: nil, deliverImmediately: true)
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--start") {
                let vm = args.firstIndex(of: "--vm").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ""
                DistributedNotificationCenter.default().postNotificationName(
                    Self.startRequest, object: vm, userInfo: nil, deliverImmediately: true)
            }
            (Self.qemuApp ?? other).activate()
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Self.startRequest, object: nil, queue: .main) { [weak self] note in
            let name = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.startRequested(name) }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Self.updateRequest, object: nil, queue: .main) { _ in
            // From `--update-now` of a second launcher: this one stays open.
            Task { @MainActor in await Updater.shared.runScripted(quitWhenDone: false) }
        }
        state.startVM = { [weak self] in self?.startVM() }
        Updater.shared.busyReason = { [weak self] in
            guard let self else { return nil }
            if self.runner?.isRunning == true { return "The VM runs" }
            if self.state.screen == .building { return "A VM is being built" }
            if self.quitting { return "Quitting" }
            return nil
        }
        let starting = state.config.isReady && args.contains("--start")
        Updater.shared.start(pending: args.contains("--update-now") || args.contains("--update-check") ? .leave
                             : starting ? .waitUntilIdle : .installNow)
        buildMenu()
        // Scripted update: --update-now (no window; update.log says what happened).
        if args.contains("--update-now") {
            Task { await Updater.shared.runScripted(quitWhenDone: true) }
            return
        }
        if starting {
            startVM()
        } else {
            showWindow()
        }
    }

    /// Per bundle id: a test build (build-app.sh --id) does not take the
    /// installed app's start requests.
    static let startRequest = Notification.Name("\(Bundle.main.bundleIdentifier ?? "org.omacvm.app").start")
    static let updateRequest = Notification.Name("\(Bundle.main.bundleIdentifier ?? "org.omacvm.app").update-now")
    /// The VM's window belongs to QEMU's process: the one from this app
    /// (another copy of OmacVM may run a VM of its own).
    static var qemuApp: NSRunningApplication? {
        let mine = Running.realPath(Bundle.main.bundleURL) + "/"
        return NSWorkspace.shared.runningApplications.first {
            guard let p = $0.executableURL.map(Running.realPath) else { return false }
            return p.hasPrefix(mine) && p.hasSuffix("/runtime/bin/OmacVM")
        }
    }

    /// Another launcher (or `omacvm`) asks to start a VM.
    private func startRequested(_ name: String) {
        if runner?.isRunning == true { Self.qemuApp?.activate(); return }
        if !name.isEmpty, let c = VMConfig.named(name) { state.config = c; state.screen = c.isReady ? .ready : .setup }
        if state.config.isReady { startVM() } else { showWindow() }
    }

    private var quitting = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if runner?.isRunning == true {
            // Quit, logout and restart shut the VM down first and wait for it
            // (QEMU waits the same way); a VM that hangs is stopped after 90 s.
            quitting = true
            runner?.powerDown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
                guard let self, self.quitting else { return }
                self.runner?.forceStop()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        if state.screen == .building {
            state.creator.cancel()
        }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if runner?.isRunning == true { Self.qemuApp?.activate() } else { showWindow() }
        return true
    }

    /// The VM's settings as vm.env has them now (`omacvm resources` may have
    /// changed them while the app ran).
    private func reloadConfig() {
        guard state.screen == .ready, let c = VMConfig.load(from: state.config.folder) else { return }
        if c != state.config { state.config = c }
    }

    private func showWindow() {
        reloadConfig()
        // Tests: the app and its VM stay out of sight (QEMU reads the same).
        if ProcessInfo.processInfo.environment["OMACVM_COCOA_HIDDEN"] != nil { return }
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = Product.name
            w.contentViewController = NSHostingController(rootView: RootView(state: state))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func startVM() {
        reloadConfig()
        let r = Runner(config: state.config)
        r.onExit = { [weak self] status in
            guard let self else { return }
            self.runner = nil
            if self.quitting {
                self.quitting = false
                // An update asked for while the VM ran goes in now, quietly:
                // the user is quitting.
                if Updater.shared.installWhenIdle { Updater.shared.install(quit: false, quiet: true) }
                NSApp.reply(toApplicationShouldTerminate: true)
            } else if status == 0 {
                // Shut down from the guest: the app quits, so no window
                // after the update either.
                if Updater.shared.installWhenIdle { Updater.shared.install(quiet: true) }
                NSApp.terminate(nil)
            } else {
                self.state.message = "The VM stopped unexpectedly (QEMU exit \(status)). Log: \(self.state.config.folder.path)/logs/qemu.log"
                // A waiting update goes in after a crash too (if a QEMU of
                // this app still runs, it keeps waiting).
                if Updater.shared.installWhenIdle { Updater.shared.install() }
                self.showWindow()
            }
        }
        do {
            try r.start()
            runner = r
            state.message = nil
            window?.orderOut(nil)
            // QEMU's window carries the app's name and icon in the Dock.
            NSApp.setActivationPolicy(.accessory)
        } catch {
            state.message = "Could not start the VM: \(error.localizedDescription)"
            showWindow()
        }
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.delegate = self
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        let back = appMenu.addItem(withTitle: "Go Back…", action: #selector(goBack(_:)), keyEquivalent: "")
        back.tag = Self.goBackTag
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(Product.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}

// MARK: - updates (Updater.swift)

extension AppDelegate: NSMenuDelegate {
    static let goBackTag = 7301

    /// "Go Back to OmacVM 2.7.0…" only while that older version is kept.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let item = menu.item(withTag: Self.goBackTag) else { return }
        let prev = Updater.shared.previousVersion
        item.isHidden = prev == nil
        item.title = Self.goBackTitle(prev ?? "")
    }

    static func goBackTitle(_ version: String) -> String { "Go Back to \(Product.name) \(version)…" }

    @objc func checkForUpdates(_ sender: Any?) {
        let u = Updater.shared
        Task { @MainActor in
            let outcome = await u.check(manual: true)
            let alert = Self.checkAlert(outcome, current: u.currentVersion, busy: u.busyNow)
            if alert.runModal() == .alertFirstButtonReturn, case .ready = outcome { u.install() }
        }
    }

    /// What Check for Updates… says. busy: why the app cannot be replaced
    /// right now (a VM runs from it): the update then waits for it.
    static func checkAlert(_ outcome: Updater.Outcome, current: String, busy: String?) -> NSAlert {
        let alert = NSAlert()
        switch outcome {
        case .ready(let v):
            alert.messageText = "\(Product.name) \(v) is ready to install"
            if let busy {
                alert.informativeText = "You have \(current). \(busy), so \(v) goes in once it has shut down. Your VMs are not changed."
                alert.addButton(withTitle: "Update After Shutdown")
            } else {
                alert.informativeText = "You have \(current). \(Product.name) restarts with the new version; your VMs are not changed. If it does not start, \(current) comes back by itself."
                alert.addButton(withTitle: "Update and Relaunch")
            }
            alert.addButton(withTitle: "Later")
        case .upToDate:
            alert.messageText = "\(Product.name) is up to date"
            alert.informativeText = "\(current) is the newest version."
        case .skipped(let v):
            alert.messageText = "\(Product.name) \(v) is skipped"
        case .needsMacOS(let v, let m):
            alert.messageText = "\(Product.name) \(v) needs macOS \(m)"
            alert.informativeText = "This Mac stays on \(current). Update macOS to get \(v)."
        case .failed(let why):
            alert.messageText = "Could not check for updates"
            // The reasons are log lines ("no connection to ..."): as a sentence.
            alert.informativeText = why.prefix(1).uppercased() + why.dropFirst() + (why.hasSuffix(".") ? "" : ".")
        }
        return alert
    }

    @objc func goBack(_ sender: Any?) {
        let u = Updater.shared
        guard let prev = u.previousVersion else { return }
        if Self.goBackAlert(prev, current: u.currentVersion).runModal() == .alertFirstButtonReturn { u.goBack() }
        // The ready window shows the notice itself (UpdateSection).
        if let n = u.notice, state.screen != .ready { state.message = n }
    }

    static func goBackAlert(_ prev: String, current: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Go back to \(Product.name) \(prev)?"
        alert.informativeText = "\(Product.name) restarts as \(prev). \(current) is skipped until a later version comes out. Your VMs are not changed."
        alert.addButton(withTitle: "Go Back")
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
