import AppKit
import SwiftUI

/// First start from a download or build folder: the app installs itself under
/// the name the user picks (OmacVM, Omarchy or their own) and opens from there.
enum Installer {
    static var isInstalled: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return path == "/Applications" || path == home
            || UserDefaults.standard.bool(forKey: "skipInstall")
            || ProcessInfo.processInfo.environment["OMACVM_RESOURCES"] != nil
    }

    /// /Applications when this user may write there, else ~/Applications.
    static var defaultFolder: URL {
        FileManager.default.isWritableFile(atPath: "/Applications")
            ? URL(fileURLWithPath: "/Applications")
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    }

    static func validName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        // No "," either: QEMU shows the name, and its options split at commas.
        return !n.isEmpty && n.count <= 40 && !n.contains("/") && !n.contains(":") && !n.contains(",") && !n.hasPrefix(".")
    }

    /// Copies this app to FOLDER/NAME.app with NAME as its name, signs it again
    /// (ad hoc) and returns the new app.
    static func install(name: String, into folder: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("\(name).app")
        guard target.standardizedFileURL.path != Bundle.main.bundleURL.standardizedFileURL.path else {
            throw HelperError.io("this app is already there under that name")
        }
        if fm.fileExists(atPath: target.path) {
            try fm.trashItem(at: target, resultingItemURL: nil)
        }
        try fm.copyItem(at: Bundle.main.bundleURL, to: target)
        let plist = target.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plist)
        guard var info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw HelperError.io("Info.plist is unreadable")
        }
        info["CFBundleName"] = name
        info["CFBundleDisplayName"] = name
        let out = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try out.write(to: plist)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--identifier", "org.omacvm.app",
                          "-r=designated => identifier \"org.omacvm.app\"", target.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw HelperError.io("could not sign \(target.path)") }
        return target
    }
}

struct InstallView: View {
    var onDone: () -> Void
    @State private var choice = 0
    @State private var custom = ""
    @State private var folder = Installer.defaultFolder
    @State private var error: String?

    private var name: String {
        switch choice {
        case 0: "OmacVM"
        case 1: "Omarchy"
        default: custom.trimmingCharacters(in: .whitespaces)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install").font(.title2.bold())
            Text("Pick the app's name. It shows in the Dock and the menu bar while Omarchy runs.")
                .foregroundStyle(.secondary)
            Picker("Name", selection: $choice) {
                Text("OmacVM").tag(0)
                Text("Omarchy").tag(1)
                Text("Your own").tag(2)
            }
            .pickerStyle(.radioGroup)
            if choice == 2 {
                TextField("Name", text: $custom)
            }
            HStack {
                Text("Folder")
                Spacer()
                Text(folder.path).foregroundStyle(.secondary)
                Button("Change…") { pick() }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Run Without Installing") {
                    UserDefaults.standard.set(true, forKey: "skipInstall")
                    onDone()
                }
                Spacer()
                Button("Install") { install() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!Installer.validName(name))
            }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    private func install() {
        do {
            let app = try Installer.install(name: name, into: folder)
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
                DispatchQueue.main.async {
                    if let error {
                        self.error = "Installed to \(app.path), but it did not open: \(error.localizedDescription)"
                    } else {
                        NSApp.terminate(nil)
                    }
                }
            }
        } catch {
            self.error = "Could not install: \(error.localizedDescription)"
        }
    }
}

/// Where VM disks may go: APFS or Mac OS Extended (sparse files), 30 GB free.
enum VolumeCheck {
    static func problem(with folder: URL) -> String? {
        var st = statfs()
        let existing = sequence(first: folder) { $0.deletingLastPathComponent() }
            .first { FileManager.default.fileExists(atPath: $0.path) } ?? folder
        guard statfs(existing.path, &st) == 0 else { return "That folder cannot be read." }
        let type = withUnsafeBytes(of: st.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard type == "apfs" || type == "hfs" else {
            return "That drive is \(type.uppercased()). The VM's disk needs APFS or Mac OS Extended."
        }
        let free = Double(st.f_bavail) * Double(st.f_bsize) / 1e9
        if free < 30 { return "That drive has \(Int(free)) GB free; the VM needs at least 30 GB." }
        return nil
    }
}
