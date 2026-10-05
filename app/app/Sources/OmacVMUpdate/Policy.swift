import Foundation

/// When to check and what to offer. Pure, so update-tests covers it.
public enum UpdatePolicy {
    /// Once a week.
    public static let interval: TimeInterval = 7 * 24 * 3600

    /// A check is due a week after the last one; also when the last one lies
    /// in the future (the clock went back).
    public static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = interval) -> Bool {
        guard let last = lastCheck else { return true }
        return now.timeIntervalSince(last) >= interval || last.timeIntervalSince(now) > 24 * 3600
    }

    public enum Offer: Equatable, Sendable {
        case upToDate
        case newer
        /// The user skipped this version, or it failed to start here before.
        case skipped
        case needsMacOS(String)
    }

    public static func offer(_ feed: Appcast, current: Version, skipped: String?, os: Version) -> Offer {
        guard current < feed.version else { return .upToDate }
        if let s = skipped.flatMap(Version.init), !(s < feed.version) { return .skipped }
        if let m = feed.minimumMacOS, os < m { return .needsMacOS(m.description) }
        return .newer
    }
}

/// The one switch for update checks, shared with OmacVM's control centre
/// (the Bridge reads and writes the same file): `update_checks` in
/// ~/Library/Application Support/omacvm/settings.json. Missing or not a
/// JSON bool: on.
public struct SharedSettings: Sendable {
    public let file: URL

    public init(directory: URL) { file = directory.appendingPathComponent("settings.json") }

    /// OMACVM_SETTINGS_DIR (tests) or ~/Library/Application Support/omacvm.
    public static var standard: SharedSettings {
        if let d = ProcessInfo.processInfo.environment["OMACVM_SETTINGS_DIR"], !d.isEmpty {
            return SharedSettings(directory: URL(fileURLWithPath: d))
        }
        return SharedSettings(directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/omacvm"))
    }

    private func object() -> [String: Any] {
        guard let d = try? Data(contentsOf: file),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
        return o
    }

    public var updateChecks: Bool {
        guard let n = object()["update_checks"] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return true }
        return n.boolValue
    }

    /// Keeps the file's other keys.
    public func setUpdateChecks(_ on: Bool) throws {
        var o = object()
        o["update_checks"] = on
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
    }
}
