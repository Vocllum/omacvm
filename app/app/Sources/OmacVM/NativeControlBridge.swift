import Darwin
import Foundation

/// The control centre for this app's VMs (docs/adr/0031): the virtio port
/// org.omacvm.control carries the VM's requests, one JSON line each
/// ({"id", "method", "path", "body", "proto", "version"}), and the answers
/// back ({"id", "status", "body"}). Each request goes on to OmacVM Bridge on
/// this Mac, which decides what is allowed (the same fixed list as for the
/// other routes). The app names the VM: it knows whose port this is, and a
/// guest cannot name another VM (its guests all reach the Mac from
/// 127.0.0.1, so the Bridge cannot tell them apart by address). The relay key
/// proves to the Bridge that the app sent it; no VM ever gets that key.
///
/// The guest is untrusted: lines over 8 KB are dropped, only GET and POST to
/// /omacvm/... with a JSON object body go on, at most 4 requests at a time.
/// Status 0 in an answer: the Bridge did not answer.
final class NativeControlBridge: @unchecked Sendable {
    static let maximumLineBytes = 8192
    /// The Bridge's port (OMACVM_BRIDGE_PORT as for the Bridge itself: tests).
    static let bridgePort = Int(ProcessInfo.processInfo.environment["OMACVM_BRIDGE_PORT"] ?? "").flatMap { (1...65535).contains($0) ? $0 : nil } ?? 47831

    private let descriptor: Int32
    private let vmName: String
    private let writeLock = NSLock()
    private let slots = DispatchSemaphore(value: 4)
    private let stopLock = NSLock()
    private var stopped = false

    init(socketPath: String, vmName: String) throws {
        descriptor = try NativeBridgeSocket.connectSecure(path: socketPath, label: "control port")
        self.vmName = vmName
    }

    deinit { stop() }

    func run() throws {
        var line = Data(), skipping = false
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                var start = 0
                for index in 0..<count where chunk[index] == 0x0A {
                    if !skipping {
                        line.append(contentsOf: chunk[start..<index])
                        handle(line)
                    }
                    line.removeAll(keepingCapacity: true)
                    skipping = false
                    start = index + 1
                }
                if !skipping {
                    line.append(contentsOf: chunk[start..<count])
                    if line.count > Self.maximumLineBytes { line.removeAll(); skipping = true }
                }
            } else if count == 0 {
                return
            } else if errno != EINTR {
                throw HelperError.io("cannot read the guest control port")
            }
        }
    }

    func stop() {
        stopLock.lock()
        guard !stopped else { stopLock.unlock(); return }
        stopped = true
        stopLock.unlock()
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    /// A request the app passes on, or nil (dropped: not one of ours).
    struct Request: Equatable {
        let id: String, method: String, path: String, body: Data?, proto: Int, version: String
    }

    static func parse(_ line: Data) -> Request? {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let id = o["id"] as? String, id.count <= 32, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              let method = o["method"] as? String, method == "GET" || method == "POST",
              let path = o["path"] as? String, path.hasPrefix("/omacvm/"), path.utf8.count <= 128,
              path.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { return nil }
        var body: Data?
        if let b = o["body"], !(b is NSNull) {
            guard b is [String: Any], let d = try? JSONSerialization.data(withJSONObject: b), d.count <= 4096 else { return nil }
            body = d
        }
        let proto = (o["proto"] as? Int).map { min(max($0, 0), 99) } ?? 1
        var version = (o["version"] as? String) ?? ""
        if version.count > 32 || !version.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) { version = "" }
        return Request(id: id, method: method, path: path, body: body, proto: proto, version: version)
    }

    private func handle(_ line: Data) {
        guard let r = Self.parse(line) else { return }
        slots.wait()   // in step with the reads: a VM that floods waits for its answers
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { slots.signal() }
            let (status, body) = relay(r)
            var answer = Data((try? JSONSerialization.data(withJSONObject: ["id": r.id, "status": status, "body": body])) ?? Data("{}".utf8))
            answer.append(0x0A)
            writeLock.lock(); defer { writeLock.unlock() }
            do { try NativeBridgeSocket.writeAll(answer, to: descriptor, label: "control") }
            catch { fputs("[control] \(error.localizedDescription)\n", stderr) }
        }
    }

    private static func secret(_ name: String) -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/omacvm-bridge/\(name)").path
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= 32 ? t : nil
    }

    /// The request to the Bridge on 127.0.0.1, with the app's headers only.
    private func relay(_ r: Request) -> (Int, [String: Any]) {
        guard let token = Self.secret("token"), let relayKey = Self.secret("relay-key"),
              let url = URL(string: "http://127.0.0.1:\(Self.bridgePort)\(r.path)") else {
            return (0, ["error": "OmacVM Bridge is not set up on this Mac (or is older): omacvm update on the Mac"])
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 75)
        req.httpMethod = r.method
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue(relayKey, forHTTPHeaderField: "X-OmacVM-Relay")
        req.setValue(Data(vmName.utf8).base64EncodedString(), forHTTPHeaderField: "X-OmacVM-App-VM")
        req.setValue(String(r.proto), forHTTPHeaderField: "X-OmacVM-Proto")
        if !r.version.isEmpty { req.setValue(r.version, forHTTPHeaderField: "X-OmacVM-Version") }
        if let b = r.body { req.httpBody = b; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        var result: (Int, [String: Any]) = (0, ["error": "OmacVM Bridge does not answer on this Mac"])
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, response, _ in
            if let h = response as? HTTPURLResponse {
                let o = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
                result = (h.statusCode, o)
            }
            done.signal()
        }.resume()
        done.wait()
        return result
    }
}
