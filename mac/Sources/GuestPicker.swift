import Foundation

/// A connected guest, as far as picking the one for the strip goes.
struct GuestCandidate: Equatable {
    let id: Int
    /// The VM app it runs in ("Parallels Desktop", "UTM", "VMware Fusion");
    /// nil: not said or unknown, could be any.
    var owner: String?
    /// The VM's name in its app (from "vmname"); nil: not said (older guests).
    var name: String?
}

/// The full-screen VM window on the built-in display.
struct FrontWindow: Equatable {
    /// The app that owns it.
    let owner: String
    /// Its title (Accessibility); nil when unknown.
    let title: String?
}

/// Picks the guest whose VM is in the full-screen window on the built-in
/// display. VM apps put the VM's name in the window title: Parallels and
/// VMware Fusion "NAME", UTM "UTM – NAME" or "NAME".
enum GuestPicker {
    /// `guests` in connection order (first connected first). Returns nil when
    /// no guest can run in the window's app.
    ///
    /// The name that is the title wins, else the longest name that is a part
    /// of it ("UTM – Omarchy 2": "Omarchy 2", not "Omarchy"). Without a match,
    /// a guest that has not said its name may be the one, one that has is
    /// not. Ties (and no title): the current guest if it runs in the front
    /// app, else the first one that does, else the current one, else the
    /// first connected.
    static func pick(_ guests: [GuestCandidate], front: FrontWindow, current: Int?) -> Int? {
        let fits = guests.filter { $0.owner == nil || $0.owner == front.owner }
        guard !fits.isEmpty else { return nil }
        if let title = front.title, !title.isEmpty {
            let exact = fits.filter { $0.name == title }
            if !exact.isEmpty { return choose(exact, front: front, current: current) }
            let inTitle = fits.filter { g in g.name.map { !$0.isEmpty && isPart($0, of: title) } ?? false }
            if let longest = inTitle.map({ $0.name!.count }).max() {
                return choose(inTitle.filter { $0.name!.count == longest }, front: front, current: current)
            }
            let unnamed = fits.filter { $0.name == nil }
            if !unnamed.isEmpty { return choose(unnamed, front: front, current: current) }
        }
        return choose(fits, front: front, current: current)
    }

    /// Whether the window title can change the pick: two or more guests can
    /// run in the front app and one of them has a name. Otherwise no title
    /// (and no Accessibility permission) is needed.
    static func needsTitle(_ guests: [GuestCandidate], front owner: String) -> Bool {
        let fits = guests.filter { $0.owner == nil || $0.owner == owner }
        return fits.count > 1 && fits.contains { !($0.name ?? "").isEmpty }
    }

    /// `name` is the title, or a part of it between separators ("UTM – NAME",
    /// "NAME - App", "App (NAME)"); "Omarchy" is not a part of "Omarchy 2".
    static func isPart(_ name: String, of title: String) -> Bool {
        if title == name || title.contains("(\(name))") { return true }
        return [" – ", " — ", " - ", ": "].contains { sep in
            title.hasSuffix(sep + name) || title.hasPrefix(name + sep) || title.contains(sep + name + sep)
        }
    }

    private static func choose(_ set: [GuestCandidate], front: FrontWindow, current: Int?) -> Int {
        let cur = set.first { $0.id == current }
        if let cur, cur.owner == front.owner { return cur.id }
        if let g = set.first(where: { $0.owner == front.owner }) { return g.id }
        return cur?.id ?? set[0].id
    }

    /// The VM app for the hypervisor in a guest's "hello" (first word).
    static func owner(hello: String) -> String? {
        switch hello.split(separator: " ").first {
        case "parallels": return "Parallels Desktop"
        case "qemu": return "UTM"
        case "vmware": return "VMware Fusion"
        default: return nil
        }
    }

    /// The VM name from "vmname <base64>": UTF-8, at most 255 bytes, one line.
    static func vmName(base64: String) -> String? {
        let s = base64.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.count <= 400, let data = Data(base64Encoded: s), !data.isEmpty, data.count <= 255,
              let name = String(data: data, encoding: .utf8), !name.contains(where: { $0.isNewline })
        else { return nil }
        return name
    }
}

/// Which guest is served and whether its bar is parked, as commands for the
/// guests. Only the served guest is ever parked: switching guests brings the
/// old one's bar back before the new one is parked.
struct ParkState {
    private(set) var active: Int?
    private(set) var parked = false

    /// Serve `guest` (nil: none).
    mutating func activate(_ guest: Int?) -> [(guest: Int, line: String)] {
        guard guest != active else { return [] }
        var out: [(guest: Int, line: String)] = []
        if let old = active, parked {
            // The guest hides its cursor while the pointer is over the strip.
            out = [(old, "park 0"), (old, "cursor 1")]
        }
        active = guest
        parked = false
        return out
    }

    mutating func setParked(_ on: Bool) -> [(guest: Int, line: String)] {
        guard on != parked, let a = active else { return [] }
        parked = on
        return [(a, "park \(on ? 1 : 0)")]
    }

    /// The guest's session started over (it starts unparked) or ended.
    mutating func reset(_ guest: Int, gone: Bool) {
        guard guest == active else { return }
        parked = false
        if gone { active = nil }
    }
}
