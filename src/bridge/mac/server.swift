// HTTP server (BSD sockets, one thread per request), auth, routing, and the
// hub that tracks state and pushes changes to Server-Sent Events clients.
import Foundation

struct APIError: Error {
  let status: Int, message: String
  init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}

func authorized(_ header: String?) -> Bool {
  guard let h = header, h.hasPrefix("Bearer ") else { return false }
  let given = Array(h.dropFirst(7).trimmingCharacters(in: .whitespaces).utf8)
  guard given.count == token.count else { return false }
  var diff: UInt8 = 0
  for i in 0..<given.count { diff |= given[i] ^ token[i] }   // constant time
  return diff == 0
}

// ---- sockets ----
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
  data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
    var off = 0
    while off < buf.count {
      let n = send(fd, buf.baseAddress! + off, buf.count - off, 0)
      if n <= 0 { return false }
      off += n
    }
    return true
  }
}

func setTimeout(_ fd: Int32, _ opt: Int32, _ seconds: Int) {
  var tv = timeval(tv_sec: seconds, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, opt, &tv, socklen_t(MemoryLayout<timeval>.size))
}

func ipv4String(_ a: in_addr) -> String {
  var a = a, buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
  inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
  return String(cString: buf)
}

// ---- state + SSE clients ----
/// One pushed state (Wi-Fi, audio): re-read on events and every tick, sent only when it changed.
final class Feed {
  let event: String, delay: Double
  let read: () -> [String: Any]
  let describe: (_ old: [String: Any], _ new: [String: Any]) -> String?   // log line for notable changes
  fileprivate var compare = Data(), state: [String: Any] = [:], seq = 0, pending = false

  init(event: String, delay: Double, read: @escaping () -> [String: Any],
       describe: @escaping ([String: Any], [String: Any]) -> String?) {
    self.event = event; self.delay = delay; self.read = read; self.describe = describe
  }
}

final class Hub {
  private let q = DispatchQueue(label: "omacvm-bridge.hub")
  private let feeds: [Feed]
  private var clients: [Int32: String] = [:]
  private var lastSend = Date()
  private var timer: DispatchSourceTimer?

  init(_ feeds: [Feed]) { self.feeds = feeds }

  func start() {
    let t = DispatchSource.makeTimerSource(queue: q)
    t.schedule(deadline: .now(), repeating: tickSeconds)
    t.setEventHandler { [self] in
      for f in feeds { refresh(f, "tick") }
      if Date().timeIntervalSince(lastSend) >= pingSeconds { write(": ping\n\n") }
    }
    t.resume()
    timer = t
  }

  private func feed(_ event: String) -> Feed { feeds.first { $0.event == event }! }

  // Events come in bursts; coalesce them per feed.
  func changed(_ event: String, why: String) {
    q.async { [self] in
      let f = feed(event)
      guard !f.pending else { return }
      f.pending = true
      q.asyncAfter(deadline: .now() + f.delay) { f.pending = false; self.refresh(f, why) }
    }
  }

  func current(_ event: String) -> [String: Any] { q.sync { let f = feed(event); refresh(f, "request"); return stamped(f) } }

  var hasClients: Bool { q.sync { !clients.isEmpty } }
  var clientCount: Int { q.sync { clients.count } }

  func send(_ event: String, _ obj: Any) { q.async { if !self.clients.isEmpty { self.broadcast(event, obj) } } }

  private func refresh(_ f: Feed, _ why: String) {
    let s = f.read(), cmp = jsonData(s)
    guard cmp != f.compare else { return }
    let old = f.state
    f.compare = cmp; f.state = s; f.seq += 1
    if let line = f.describe(old, s) { log("\(f.event) (\(why)): \(line)") }
    broadcast(f.event, stamped(f))
  }

  private func stamped(_ f: Feed) -> [String: Any] {
    var s = f.state; s["seq"] = f.seq; s["updated_at"] = isoFormat.string(from: Date()); return s
  }

  private func broadcast(_ event: String, _ obj: Any) { write("event: \(event)\ndata: \(jsonString(obj))\n\n") }

  private func write(_ msg: String) {
    lastSend = Date()
    let data = Data(msg.utf8)
    for (fd, peer) in clients where !writeAll(fd, data) {
      close(fd); clients[fd] = nil
      log("events: \(peer) disconnected (\(clients.count) left)")
    }
  }

  func addClient(_ fd: Int32, peer: String) {
    q.async { [self] in
      if clients.count >= maxClients { respond(fd, 503, ["error": "too many event clients"]); return }
      var first = "retry: 3000\n\n"
      for f in feeds { refresh(f, "events"); first += "event: \(f.event)\ndata: \(jsonString(stamped(f)))\n\n" }
      let head = httpHead(200, "text/event-stream", length: nil, extra: "X-Accel-Buffering: no\r\n")
      guard writeAll(fd, head + Data(first.utf8)) else { close(fd); return }
      clients[fd] = peer
      log("events: \(peer) connected (\(clients.count) client\(clients.count == 1 ? "" : "s"))")
    }
  }
}

// ---- HTTP ----
let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed",
               409: "Conflict", 413: "Payload Too Large", 500: "Internal Server Error", 501: "Not Implemented", 503: "Service Unavailable"]

func httpHead(_ code: Int, _ type: String, length: Int?, extra: String = "") -> Data {
  var h = "HTTP/1.1 \(code) \(reasons[code] ?? "Error")\r\nContent-Type: \(type)\r\nCache-Control: no-store\r\n"
  if let length { h += "Content-Length: \(length)\r\nConnection: close\r\n" } else { h += "Connection: keep-alive\r\n" }
  return Data((h + extra + "\r\n").utf8)
}

func respond(_ fd: Int32, _ code: Int, _ obj: Any, extra: String = "") {
  let body = jsonData(obj) + Data("\n".utf8)
  _ = writeAll(fd, httpHead(code, "application/json", length: body.count, extra: extra) + body)
  close(fd)
}

/// POST /audio/*: applies the change, returns a log line.
func audioControl(_ path: String, _ body: [String: Any]) throws -> String {
  let input = (body["scope"] as? String) == "input"
  switch path {
  case "/audio/volume":
    let absolute = (body["volume"] as? NSNumber)?.doubleValue, delta = (body["delta"] as? NSNumber)?.doubleValue
    guard absolute != nil || delta != nil else { throw APIError(400, "send {\"volume\": 0..1} or {\"delta\": -1..1}") }
    let r = try audio.setVolume(input: input, absolute: absolute, delta: delta, unmute: !input && (delta ?? 0) > 0)
    if !input { osdEvents.volumeSet(kind: "volume", source: "api") }
    return "\(input ? "input" : "output") volume \(r.volume)\(r.muted ? " (muted)" : "")"
  case "/audio/mute":
    let muted: Bool?
    switch body["muted"] {
    case let b as Bool: muted = b
    case let s as String where s == "toggle": muted = nil
    default: throw APIError(400, "send {\"muted\": true|false|\"toggle\"}")
    }
    let r = try audio.setMute(input: input, muted: muted)
    if !input { osdEvents.volumeSet(kind: "mute", source: "api") }
    return "\(input ? "input" : "output") muted=\(r.muted)"
  case "/audio/output", "/audio/input":
    guard let uid = body["uid"] as? String else { throw APIError(400, "send {\"uid\": \"<device uid>\"}") }
    let output = path == "/audio/output"
    return "default \(output ? "output" : "input") -> \(try audio.setDefault(uid: uid, output: output))"
  default:
    throw APIError(404, "not found")
  }
}

func handle(_ fd: Int32, peer: String) {
  var one: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
  _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)   // BSD: accept() inherits O_NONBLOCK
  setTimeout(fd, SO_RCVTIMEO, 5)
  setTimeout(fd, SO_SNDTIMEO, 2)

  var buf = Data(), chunk = [UInt8](repeating: 0, count: 4096)
  let end = Data("\r\n\r\n".utf8)
  func readMore() -> Bool {
    let n = read(fd, &chunk, chunk.count)
    if n > 0 { buf.append(contentsOf: chunk[0..<n]) }
    return n > 0
  }
  while buf.count < 16384, buf.range(of: end) == nil, readMore() {}
  guard let headEnd = buf.range(of: end) else { close(fd); return }
  let lines = String(decoding: buf[..<headEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
  let parts = lines[0].split(separator: " ")
  guard parts.count == 3 else { respond(fd, 400, ["error": "bad request"]); return }
  var headers: [String: String] = [:]
  for l in lines.dropFirst() {
    if let c = l.firstIndex(of: ":") {
      headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
    }
  }
  let method = String(parts[0]), url = URLComponents(string: String(parts[1]))
  let path = url?.path ?? "", query = url?.queryItems ?? []

  guard authorized(headers["authorization"]) else {
    log("401 \(method) \(path) from \(peer)")
    respond(fd, 401, ["error": "missing or wrong bearer token"], extra: "WWW-Authenticate: Bearer\r\n")
    return
  }
  // Bodies are small JSON, except a wallpaper image (read only after the token checked out).
  let wanted = Int(headers["content-length"] ?? "") ?? 0
  let limit = path == "/wallpaper" ? 48 << 20 : 65536
  guard wanted <= limit else { respond(fd, 413, ["error": "body too large"]); return }
  if path == "/wallpaper" { setTimeout(fd, SO_RCVTIMEO, 30) }
  while buf.count - headEnd.upperBound < wanted, readMore() {}
  let body = buf[headEnd.upperBound...].prefix(wanted)
  switch (method, path) {
  case ("GET", "/state"):
    respond(fd, 200, hub.current("wifi"))
  case ("GET", "/scan"):
    let cached = query.contains { $0.name == "cached" && $0.value != "0" }
    let (code, body) = scanner.scan(cached: cached)
    respond(fd, code, body)
  case ("GET", "/audio"):
    respond(fd, 200, hub.current("audio"))
  case ("GET", "/display"):
    respond(fd, 200, hub.current("display"))
  case ("GET", "/wifi/password"):
    let ssid = query.first { $0.name == "ssid" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    do { respond(fd, 200, try wifiPassword(ssid: ssid, peer: peer)) }
    catch let e as APIError { respond(fd, e.status, ["error": e.message]) }
    catch { respond(fd, 500, ["error": "\(error)"]) }
  case ("GET", "/events"):
    hub.addClient(fd, peer: peer)
  case ("POST", let p) where p.hasPrefix("/audio/") || p.hasPrefix("/display/"):
    guard let obj = (body.isEmpty ? [:] : try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
      respond(fd, 400, ["error": "body must be a JSON object"]); return
    }
    do {
      let audioPath = p.hasPrefix("/audio/")
      log("\(p) from \(peer): \(try audioPath ? audioControl(p, obj) : displayControl(p, obj))")
      respond(fd, 200, hub.current(audioPath ? "audio" : "display"))   // also pushes the change to /events clients
    } catch let e as APIError {
      log("\(p) from \(peer) failed: \(e.message)")
      respond(fd, e.status, ["error": e.message])
    } catch {
      respond(fd, 500, ["error": "\(error)"])
    }
  case ("POST", "/wallpaper"):
    do {
      let theme = headers["x-omarchy-theme"] ?? ""
      log("/wallpaper from \(peer): \(try setWallpaper(Data(body), theme: theme))")
      respond(fd, 200, ["ok": true])
    } catch let e as APIError {
      log("/wallpaper from \(peer) failed: \(e.message)")
      respond(fd, e.status, ["error": e.message])
    } catch {
      respond(fd, 500, ["error": "\(error)"])
    }
  case ("POST", "/power"), ("POST", "/join"), ("POST", "/disconnect"):
    respond(fd, 501, ["error": "Wi-Fi control is not implemented yet (stage 2)"])
  case (_, "/state"), (_, "/scan"), (_, "/audio"), (_, "/display"), (_, "/wifi/password"), (_, "/events"):
    respond(fd, 405, ["error": "method not allowed"])
  default:
    respond(fd, 404, ["error": "not found"])
  }
}

// Listens on one address only. The VM network's bridge interface appears when
// Parallels or UTM starts and can be recreated, so the listener follows it.
final class Server {
  private let q = DispatchQueue(label: "omacvm-bridge.listen")
  private var source: DispatchSourceRead?
  private var boundInterface: String?
  private var waitingLogged = false
  let onConnection: (Int32, String) -> Void
  let listenAddr: String

  init(addr: String, onConnection: @escaping (Int32, String) -> Void) {
    self.listenAddr = addr; self.onConnection = onConnection
  }

  func check(rebind: Bool = false) { q.async { self.checkLocked(rebind: rebind) } }

  var status: String {
    q.sync { boundInterface.map { "Listening on \(listenAddr):\(listenPort) (\($0))" } ?? "Waiting for \(listenAddr) (VM network not up)" }
  }

  private func interfaceOwningAddress() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return nil }
    defer { freeifaddrs(list) }
    var p = list
    while let a = p?.pointee {
      if let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
        let sin = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee
        if ipv4String(sin.sin_addr) == listenAddr { return String(cString: a.ifa_name) }
      }
      p = a.ifa_next
    }
    return nil
  }

  private func checkLocked(rebind: Bool) {
    let owner = interfaceOwningAddress()
    if source != nil, rebind || owner != boundInterface {
      log("listener: re-binding (\(listenAddr) on \(boundInterface ?? "-") -> \(owner ?? "gone"))")
      source?.cancel(); source = nil; boundInterface = nil
    }
    guard source == nil else { return }
    guard let owner else {
      if !waitingLogged { log("listener: waiting for \(listenAddr) to appear (VM network not up yet)"); waitingLogged = true }
      return
    }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var sin = sockaddr_in()
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_port = listenPort.bigEndian
    inet_pton(AF_INET, listenAddr, &sin.sin_addr)
    let ok = withUnsafePointer(to: &sin) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    } == 0 && listen(fd, 16) == 0
    guard ok else {
      log("listener: cannot listen on \(listenAddr):\(listenPort): \(String(cString: strerror(errno)))")
      close(fd); return
    }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
    src.setEventHandler { [onConnection] in
      while true {
        var peer = sockaddr_in(), len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let c = withUnsafeMutablePointer(to: &peer) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
        }
        if c < 0 { break }
        let who = ipv4String(peer.sin_addr)
        DispatchQueue.global(qos: .utility).async { onConnection(c, who) }
      }
    }
    src.setCancelHandler { close(fd) }
    src.resume()
    source = src; boundInterface = owner; waitingLogged = false
    log("listener: http://\(listenAddr):\(listenPort) on \(owner)")
  }
}
