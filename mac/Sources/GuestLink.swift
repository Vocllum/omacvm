import Foundation
import Network

/// TCP server the guest's `notchcast` connects to. Only one guest is served;
/// a new connection replaces the old one. The listener binds to the host side
/// of the Parallels shared network only, and retries while that interface is
/// missing (Parallels not running).
final class GuestLink {
    var onMessages: (([GuestMessage]) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    private let host: String
    private let port: UInt16
    private let allowedPrefix: String
    private let queue = DispatchQueue.main
    private var listener: NWListener?
    private var connection: NWConnection?
    private let stream: GuestStream

    private(set) var isConnected = false

    init(host: String, port: UInt16, allowedPrefix: String, stream: GuestStream) {
        self.host = host
        self.port = port
        self.allowedPrefix = allowedPrefix
        self.stream = stream
    }

    func start() {
        startListener()
    }

    private func startListener() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        guard let l = try? NWListener(using: params) else {
            Log.info("listener: cannot create on \(host):\(port), retrying")
            retryListener()
            return
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Log.info("listening on \(self?.host ?? ""):\(self?.port ?? 0)")
            case .failed(let err):
                Log.info("listener failed: \(err), retrying")
                l.cancel()
                self?.retryListener()
            default:
                break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    private func retryListener() {
        listener = nil
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.startListener() }
    }

    private func accept(_ c: NWConnection) {
        if case let .hostPort(remoteHost, _) = c.endpoint, !"\(remoteHost)".hasPrefix(allowedPrefix) {
            Log.info("rejecting connection from \(remoteHost)")
            c.cancel()
            return
        }
        connection?.cancel()
        connection = c
        stream.reset()
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, c === self.connection else { return }
            switch state {
            case .ready:
                Log.info("guest connected: \(c.endpoint)")
                self.setConnected(true)
                self.receive(on: c)
            case .failed, .cancelled:
                self.dropConnection(c)
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, c === self.connection else { return }
            if let data, !data.isEmpty {
                do {
                    let messages = try self.stream.feed(data)
                    if !messages.isEmpty { self.onMessages?(messages) }
                } catch {
                    Log.info("\(error); dropping guest connection")
                    c.cancel()
                    return
                }
            }
            if isComplete || error != nil {
                c.cancel()
                return
            }
            self.receive(on: c)
        }
    }

    private func dropConnection(_ c: NWConnection) {
        guard c === connection else { return }
        connection = nil
        Log.info("guest disconnected")
        setConnected(false)
    }

    private func setConnected(_ v: Bool) {
        guard v != isConnected else { return }
        isConnected = v
        onConnectionChange?(v)
    }

    /// Sends one command line to the guest (fire and forget).
    func send(_ line: String) {
        guard let c = connection, isConnected else { return }
        c.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
    }
}
