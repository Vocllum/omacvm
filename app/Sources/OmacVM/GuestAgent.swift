import Darwin
import Foundation

/// The QEMU guest agent in the VM (virtio-serial). Only what the launcher needs.
enum GuestAgent {
    /// Asks the guest to power off; returns at once. Does nothing if no agent answers.
    static func shutdown(socketPath: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else { return }
        let msg = "{\"execute\":\"guest-shutdown\",\"arguments\":{\"mode\":\"powerdown\"}}\n"
        _ = msg.withCString { write(fd, $0, strlen($0)) }
        usleep(500_000)
    }
}
