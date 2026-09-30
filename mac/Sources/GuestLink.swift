import Darwin
import Foundation
import Network

/// A host-side address of a VM network: the Mac's end of the network the
/// guest is on (Parallels: 10.211.55.2 on a vnic/bridge interface, UTM's
/// shared network: 192.168.64.1 on bridge100).
struct VMInterface: Hashable {
    let name: String
    let address: UInt32  // host byte order
    let netmask: UInt32

    var addressString: String {
        "\(address >> 24).\((address >> 16) & 255).\((address >> 8) & 255).\(address & 255)"
    }

    /// A peer in this network, other than the Mac's own address.
    func contains(_ ip: UInt32) -> Bool { ip & netmask == address & netmask && ip != address }

    static func parse(_ s: String) -> UInt32? {
        var a = in_addr()
        guard inet_pton(AF_INET, s, &a) == 1 else { return nil }
        return UInt32(bigEndian: a.s_addr)
    }

    /// "a.b.c.d/nn" → (network, mask).
    static func parseSubnet(_ s: String) -> (UInt32, UInt32)? {
        let parts = s.split(separator: "/")
        guard parts.count == 2, let net = parse(String(parts[0])), let bits = Int(parts[1]), (0 ... 32).contains(bits)
        else { return nil }
        let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << UInt32(32 - bits)
        return (net & mask, mask)
    }

    /// IPv4 addresses of the interfaces whose names start with one of the
    /// prefixes and whose network is one of `subnets` (VM shared networks;
    /// this keeps out Internet Sharing and Thunderbolt bridges), or the
    /// interface that carries `onlyAddress`.
    static func scan(prefixes: [String], subnets: [(UInt32, UInt32)], onlyAddress: UInt32?) -> [VMInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        let wanted = onlyAddress
        var out: [VMInterface] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), let nm = ifa.ifa_netmask,
                  ifa.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if let wanted {
                if addr == wanted { out.append(VMInterface(name: name, address: addr, netmask: mask)) }
            } else if prefixes.contains(where: { name.hasPrefix($0) }),
                      subnets.contains(where: { addr & $0.1 == $0.0 }) {
                out.append(VMInterface(name: name, address: addr, netmask: mask))
            }
        }
        return out
    }
}

/// TCP server the guest's `notchcast` connects to. Only one guest is served;
/// a new connection replaces the old one.
///
/// It listens only on the Mac's side of VM shared networks (never on Wi-Fi,
/// Ethernet, Internet Sharing or Thunderbolt bridges) and accepts a connection
/// only from an address inside that network. The interfaces come and go with
/// the VM apps, so they are re-scanned every few seconds.
final class GuestLink {
    var onMessages: (([GuestMessage]) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    private let port: UInt16
    private let prefixes: [String]
    private let subnets: [(UInt32, UInt32)]
    private let onlyAddress: UInt32?
    private let listenNowhere: Bool
    private let queue = DispatchQueue.main
    private var listeners: [VMInterface: NWListener] = [:]
    private var scanTimer: Timer?
    private var connection: NWConnection?
    private var connectionPeer: UInt32?
    private var connectionIface: VMInterface?
    private let stream: GuestStream

    private(set) var isConnected = false

    /// `onlyAddress`: listen on this one address instead of scanning.
    init(port: UInt16, interfacePrefixes: [String], subnets: [String], onlyAddress: String?, stream: GuestStream) {
        self.port = port
        self.prefixes = interfacePrefixes
        self.subnets = subnets.compactMap { VMInterface.parseSubnet($0.trimmingCharacters(in: .whitespaces)) }
        let raw = onlyAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.onlyAddress = raw.isEmpty ? nil : VMInterface.parse(raw)
        self.listenNowhere = !raw.isEmpty && self.onlyAddress == nil
        if listenNowhere { Log.info("listenHost '\(raw)' is not an IPv4 address: not listening") }
        self.stream = stream
    }

    func start() {
        rescan()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.rescan() }
    }

    private func rescan() {
        let now = listenNowhere ? [] : Set(VMInterface.scan(prefixes: prefixes, subnets: subnets, onlyAddress: onlyAddress))
        for (iface, l) in listeners where !now.contains(iface) {
            Log.info("VM network gone: \(iface.name) \(iface.addressString)")
            l.cancel()
            listeners[iface] = nil
        }
        // A guest whose network is gone (VM app quit) is gone too, even if
        // its connection never closed.
        if let iface = connectionIface, !now.contains(iface), let c = connection {
            Log.info("dropping the guest on \(iface.name): network gone")
            c.cancel()
            dropConnection(c)
        }
        for iface in now where listeners[iface] == nil {
            startListener(on: iface)
        }
    }

    private func startListener(on iface: VMInterface) {
        // Keepalive finds a guest that vanished without closing (a VM that was
        // suspended or force-stopped) within about ten seconds.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(iface.addressString),
                                                 port: NWEndpoint.Port(rawValue: port)!)
        guard let l = try? NWListener(using: params) else {
            Log.info("listener: cannot create on \(iface.addressString):\(port)")
            return
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c, via: iface) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            switch state {
            case .ready:
                Log.info("listening on \(iface.name) \(iface.addressString):\(self?.port ?? 0)")
            case .failed(let err):
                Log.info("listener on \(iface.addressString) failed: \(err)")
                l?.cancel()
                // Dropped from the table: the next scan starts it again.
                if let self, self.listeners[iface] === l { self.listeners[iface] = nil }
            default:
                break
            }
        }
        listeners[iface] = l
        l.start(queue: queue)
    }

    private func accept(_ c: NWConnection, via iface: VMInterface) {
        guard case let .hostPort(remoteHost, _) = c.endpoint,
              let ip = VMInterface.parse("\(remoteHost)".components(separatedBy: "%")[0]), iface.contains(ip)
        else {
            Log.info("rejecting connection from \(c.endpoint) on \(iface.name)")
            c.cancel()
            return
        }
        // One guest at a time, and the first one keeps the strip: another VM
        // running notchcast is turned away while this one is connected (TCP
        // keepalive and the network check in rescan() notice a dead one). The
        // same address may take over at once (a restarted notchcast or
        // rebooted VM).
        if connection != nil, isConnected, let current = connectionPeer, current != ip {
            Log.info("another guest is connected; turning away \(c.endpoint)")
            c.cancel()
            return
        }
        let takeover = connection != nil && isConnected
        connection?.cancel()
        connection = c
        connectionPeer = ip
        connectionIface = iface
        stream.reset()
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, c === self.connection else { return }
            switch state {
            case .ready:
                Log.info("guest connected: \(c.endpoint)")
                // Taking over from an old connection is a new session too.
                if takeover && self.isConnected { self.onConnectionChange?(true) } else { self.setConnected(true) }
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
        connectionPeer = nil
        connectionIface = nil
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
