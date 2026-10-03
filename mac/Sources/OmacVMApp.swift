import CoreGraphics
import Darwin
import Foundation

/// OmacVM.app: its VM window belongs to the app's QEMU, whose process may carry
/// any name the user gave the app. Its executable is always
/// <app>/Contents/Resources/runtime/bin/OmacVM, so windows of that process
/// count as owner "OmacVM". Its VMs reach the Mac at 127.0.0.1 and must say
/// OmacVM's Bridge token first ("auth <token>"), since any Mac program can
/// connect there.
enum OmacVMApp {
    static let owner = "OmacVM"

    private static var cache: [pid_t: Bool] = [:]

    static func isQEMU(_ pid: pid_t) -> Bool {
        if let hit = cache[pid] { return hit }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        let hit = n > 0 && String(cString: buf).hasSuffix("/Contents/Resources/runtime/bin/OmacVM")
        if cache.count > 64 { cache.removeAll() }
        cache[pid] = hit
        return hit
    }

    /// The owner name of a window-list entry, OmacVM.app's QEMU as "OmacVM".
    static func ownerName(_ w: [String: Any]) -> String? {
        if let pid = w[kCGWindowOwnerPID as String] as? Int, isQEMU(pid_t(pid)) { return owner }
        return w[kCGWindowOwnerName as String] as? String
    }

    /// Compares a guest's "auth" with the Bridge's token, in constant time.
    static func tokenMatches(_ given: String) -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/omacvm-bridge/token").path
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        let want = Array(s.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let got = Array(given.trimmingCharacters(in: .whitespaces).utf8)
        guard want.count >= 32, got.count == want.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<want.count { diff |= want[i] ^ got[i] }
        return diff == 0
    }
}
