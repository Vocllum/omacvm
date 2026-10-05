// The control centre's requests (docs/adr/0031): the fixed list, checked
// before anything runs. Pure (no Bridge state), so tests/control_tests.swift
// covers every accepted shape and every refusal. The guest is untrusted:
// nothing it sends reaches a command line except feature names that are in
// the Mac's own features.tsv.
import CryptoKit
import Foundation

let controlProto = 1, controlProtoMin = 1
let controlBodyMax = 4096
let controlFeaturesMax = 16
let jobsPerHour = 20

enum ControlAction: String { case enable, disable, reinstall, update }

struct JobRequest: Equatable { let action: ControlAction; let features: [String] }

enum ControlRoute: Equatable {
  case hello, status, updates, updatesCheck
  case setUpdateChecks(Bool)
  case startJob(JobRequest)
  case job(String)
}

struct PolicyError: Error, Equatable {
  let status: Int, code: String, message: String
  init(_ status: Int, _ code: String, _ message: String) { self.status = status; self.code = code; self.message = message }
}

/// The names the control centre may send (as features.tsv's own rule).
func validFeatureName(_ s: String) -> Bool {
  guard (2...32).contains(s.utf8.count), let f = s.utf8.first, (97...122).contains(f) else { return false }
  return s.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
}

func validJobID(_ s: String) -> Bool {
  s.utf8.count == 16 && s.utf8.allSatisfy { (97...102).contains($0) || (48...57).contains($0) }
}

/// A JSON object with only `allowed` keys, or nil for no body.
func strictObject(_ body: Data, allowed: Set<String>) throws -> [String: Any]? {
  if body.isEmpty { return nil }
  guard body.count <= controlBodyMax else { throw PolicyError(413, "too-large", "body over \(controlBodyMax) bytes") }
  guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
    throw PolicyError(400, "bad-json", "body must be a JSON object")
  }
  if let extra = obj.keys.first(where: { !allowed.contains($0) }) {
    throw PolicyError(400, "unknown-key", "unknown key '\(extra.prefix(32))'")
  }
  return obj
}

/// JSON true/false only (JSONSerialization also turns 0 and 1 into NSNumber).
func strictBool(_ v: Any?) -> Bool? {
  guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
  return n.boolValue
}

/// Method + path + body -> one of the allowed requests, or why not.
func controlRoute(method: String, path: String, body: Data, known: Set<String>) -> Result<ControlRoute, PolicyError> {
  do {
    guard path.hasPrefix("/omacvm/") else { throw PolicyError(404, "not-found", "not found") }
    let sub = String(path.dropFirst("/omacvm/".count))
    switch (method, sub) {
    case ("GET", "hello"), ("GET", "status"), ("GET", "updates"):
      guard body.isEmpty else { throw PolicyError(400, "body", "no body for GET") }
      return .success(sub == "hello" ? .hello : sub == "status" ? .status : .updates)
    case ("POST", "updates/check"):
      if let o = try strictObject(body, allowed: []), !o.isEmpty { throw PolicyError(400, "unknown-key", "no keys") }
      return .success(.updatesCheck)
    case ("POST", "settings/update-checks"):
      guard let o = try strictObject(body, allowed: ["enabled"]), let b = strictBool(o["enabled"]) else {
        throw PolicyError(400, "bad-body", "send {\"enabled\": true|false}")
      }
      return .success(.setUpdateChecks(b))
    case ("POST", "jobs"):
      guard let o = try strictObject(body, allowed: ["action", "features"]),
            let a = o["action"] as? String, let action = ControlAction(rawValue: a) else {
        throw PolicyError(400, "bad-action", "action: enable, disable, reinstall or update")
      }
      if action == .update {
        guard o["features"] == nil else { throw PolicyError(400, "bad-body", "update takes no features") }
        return .success(.startJob(JobRequest(action: .update, features: [])))
      }
      guard let list = o["features"] as? [Any], (1...controlFeaturesMax).contains(list.count) else {
        throw PolicyError(400, "bad-features", "features: 1 to \(controlFeaturesMax) names")
      }
      var names: [String] = []
      for item in list {
        guard let n = item as? String, validFeatureName(n) else { throw PolicyError(400, "bad-features", "not a feature name") }
        guard known.contains(n) else { throw PolicyError(400, "unknown-feature", "'\(n)' is not a feature of this Mac's OmacVM") }
        guard !names.contains(n) else { throw PolicyError(400, "bad-features", "'\(n)' twice") }
        names.append(n)
      }
      return .success(.startJob(JobRequest(action: action, features: names)))
    case ("GET", let s) where s.hasPrefix("jobs/"):
      let id = String(s.dropFirst(5))
      guard validJobID(id), body.isEmpty else { throw PolicyError(404, "not-found", "no such job") }
      return .success(.job(id))
    case (_, "hello"), (_, "status"), (_, "updates"), (_, "updates/check"), (_, "settings/update-checks"), (_, "jobs"):
      throw PolicyError(405, "method", "method not allowed")
    default:
      throw PolicyError(404, "not-found", "not found")
    }
  } catch let e as PolicyError {
    return .failure(e)
  } catch {
    return .failure(PolicyError(400, "bad-request", "bad request"))
  }
}

/// The protocol both sides speak: the guest's (X-OmacVM-Proto, 1 when
/// missing) capped at ours; below our minimum nothing runs.
func negotiateProto(_ header: String?) -> Result<Int, PolicyError> {
  let guest = header.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1
  let p = min(guest, controlProto)
  return p >= controlProtoMin ? .success(p)
    : .failure(PolicyError(409, "proto", "this VM's control centre is too old for the Mac (protocol \(guest)): update the VM"))
}

/// A VM as `omacvm vms --json` lists it.
struct VMEntry: Equatable {
  let name: String, type: String, state: String, ip: String, omacvm: String, setup: Bool
}

/// The VM a request came from: exactly one running VM OmacVM set up at the
/// peer's address. The guest never names a VM. Its key (verifyControlAuth) proves
/// it is that VM and not one that took its address.
func vmForPeer(_ peer: String, _ vms: [VMEntry]) -> Result<VMEntry, PolicyError> {
  if peer.hasPrefix("127.") {
    return .failure(PolicyError(403, "app-vm", "OmacVM.app's VMs ask through the app's control port: update OmacVM.app"))
  }
  let hits = vms.filter { $0.state == "running" && $0.setup && $0.ip == peer }
  switch hits.count {
  case 1: return .success(hits[0])
  case 0: return .failure(PolicyError(409, "unknown-vm", "no running VM that OmacVM set up has this address"))
  default: return .failure(PolicyError(409, "ambiguous-vm", "more than one VM has this address: nothing runs"))
  }
}

/// An OmacVM.app VM, named by the app (which knows which VM's control port a
/// request came through; the guest never names it): running and set up.
func vmForApp(_ name: String, _ vms: [VMEntry]) -> Result<VMEntry, PolicyError> {
  let hits = vms.filter { $0.type == "app" && $0.name == name }
  guard let v = hits.first, hits.count == 1 else { return .failure(PolicyError(409, "unknown-vm", "no such OmacVM.app VM")) }
  guard v.state == "running", v.setup else {
    return .failure(PolicyError(409, "unknown-vm", "this VM is not running, or OmacVM did not set it up"))
  }
  return .success(v)
}

/// The file name of a VM's control key (lib/mac.sh vm_key_file): the first
/// 32 hex digits of SHA-256("<type>/<name>").
func vmKeyName(type: String, name: String) -> String {
  String(SHA256.hash(data: Data("\(type)/\(name)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
}

// ---- the VM's key: requests signed with it, answers too ----
// The key itself never crosses the network: every VM has the Bridge token, so
// a VM that answers for the Mac's address passes /proof and would learn
// anything sent after it. Each request carries
//   X-OmacVM-Auth: 1 <unix time> <nonce, 32 hex> <HMAC-SHA256(key, request text), hex>
// and each answer to a signed request
//   X-OmacVM-Answer: <HMAC-SHA256(key, answer text), hex>
// so the VM only believes answers from the Mac that has its key.

let authWindow: Double = 300          // seconds a request is good for, either way
let authKeyMin = 32

func hexSHA256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

func hmacHex(_ key: String, _ text: String) -> String {
  HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: Data(key.utf8)))
    .map { String(format: "%02x", $0) }.joined()
}

/// What a request's signature covers: method, path, time, nonce, protocol
/// header and the body's hash.
func requestMAC(key: String, method: String, path: String, time: Int64, nonce: String, proto: String, body: Data) -> String {
  hmacHex(key, ["omacvm-control-request 1", method, path, String(time), nonce, proto, hexSHA256(body)].joined(separator: "\n"))
}

/// What an answer's signature covers: the request's nonce, the status and the body.
func answerMAC(key: String, nonce: String, status: Int, body: Data) -> String {
  hmacHex(key, ["omacvm-control-answer 1", nonce, String(status), hexSHA256(body)].joined(separator: "\n"))
}

func sameText(_ a: String, _ b: String) -> Bool {
  let x = Array(a.utf8), y = Array(b.utf8)
  guard x.count == y.count else { return false }
  var diff: UInt8 = 0
  for i in 0..<x.count { diff |= x[i] ^ y[i] }   // constant time
  return diff == 0
}

/// Nonces seen in the window: each signed request is taken once.
struct NonceCache {
  private var seen: [String: Date] = [:]
  let limit: Int
  init(limit: Int = 20000) { self.limit = limit }
  /// False when it was seen already (or the cache is full of fresh ones).
  mutating func take(_ nonce: String, now: Date) -> Bool {
    if seen.count >= limit / 2 { seen = seen.filter { now.timeIntervalSince($0.value) < 2 * authWindow } }
    if seen[nonce] != nil || seen.count >= limit { return false }
    seen[nonce] = now
    return true
  }
}

/// A refused signed request. `nonce` is set when the signature itself was
/// right (the answer may then be signed too: clock, replay); `macTime` for
/// a clock that is off.
struct AuthFailure: Error, Equatable {
  let error: PolicyError, nonce: String?, macTime: Int64?
}

func noVMKey() -> PolicyError {
  PolicyError(403, "no-vm-key", "the Mac has no control centre key for this VM yet: omacvm apply on the Mac")
}

/// Checks X-OmacVM-Auth against the key the Mac keeps for the VM (made by
/// omacvm apply). Success: the request's nonce (the answer is signed with it).
func verifyControlAuth(header: String?, key stored: String?, method: String, path: String, proto: String,
                       body: Data, now: Date, nonces: inout NonceCache) -> Result<String, AuthFailure> {
  guard let key = stored?.trimmingCharacters(in: .whitespacesAndNewlines), key.utf8.count >= authKeyMin else {
    return .failure(AuthFailure(error: noVMKey(), nonce: nil, macTime: nil))
  }
  let bad = AuthFailure(error: PolicyError(403, "vm-key", "this VM's control centre key does not match: omacvm apply on the Mac"),
                        nonce: nil, macTime: nil)
  let f = (header ?? "").split(separator: " ").map(String.init)
  guard f.count == 4, f[0] == "1", let t = Int64(f[1]), f[2].utf8.count == 32, f[3].utf8.count == 64,
        f[2].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return .failure(bad) }
  guard sameText(requestMAC(key: key, method: method, path: path, time: t, nonce: f[2], proto: proto, body: body), f[3]) else {
    return .failure(bad)
  }
  let mac = Int64(now.timeIntervalSince1970)
  let off = abs(Double(t) - Double(mac))   // no Int64 overflow for a far-off time
  guard off <= authWindow else {
    return .failure(AuthFailure(error: PolicyError(403, "clock", "this VM's clock is \(off < 1e9 ? String(Int(off)) : "far") s off the Mac's"),
                                nonce: f[2], macTime: mac))
  }
  guard nonces.take(f[2], now: now) else {
    return .failure(AuthFailure(error: PolicyError(403, "replay", "this request was sent before: not run again"), nonce: f[2], macTime: nil))
  }
  return .success(f[2])
}

/// Text from a request for the Bridge's log: no control characters (a
/// %0A in a path must not write a line of its own), at most 200 characters.
func logSafe(_ s: String) -> String {
  let control: (Unicode.Scalar) -> Bool = { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029 }
  return String(String(s.unicodeScalars.map { control($0) ? "?" : Character($0) }).prefix(200))
}

/// The exact command for a job: a fixed argv, no shell. `commit` only for
/// update, from the manifest the Mac verified itself. reinstall repairs the
/// named features only.
func jobArgv(cli: String, _ r: JobRequest, vm: String, commit: String?) -> [String] {
  switch r.action {
  case .enable, .disable:
    return [cli, r.action.rawValue] + r.features + ["--vm", vm, "--yes", "--transaction"]
  case .reinstall:
    return [cli, "apply", "--vm", vm, "--transaction", "--yes"] + r.features.flatMap { ["--reinstall", $0] }
  case .update:
    return [cli, "update", "--vm", vm, "--transaction", "--yes"] + (commit.map { ["--commit", $0] } ?? [])
  }
}

/// A job's state from its exit code (nil: not ended): apply and update end
/// with 4 when they went back to what the VM had (--transaction).
func jobState(rc: Int32?, alive: Bool) -> String {
  switch rc {
  case nil: return alive ? "running" : "failed"
  case 0: return "done"
  case 4: return "rolled-back"
  default: return "failed"
  }
}

struct Progress: Equatable { let n: Int, of: Int, text: String }

/// What failed in a job (apply's {"omacvm_failed": 1, "part", "text"} line).
struct Failed: Equatable { let part: String, text: String }

/// The CLI's progress lines (OMACVM_PROGRESS=json: {"omacvm_progress": 1,
/// "step", "n", "of", "text"}) and failure lines: the last of each, and the
/// other lines without them.
func progress(_ lines: [String]) -> (Progress?, [String], Failed?) {
  var last: Progress?, failed: Failed?, rest: [String] = []
  for l in lines {
    if l.hasPrefix("{\"omacvm_progress\""), let o = (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any],
       let n = o["n"] as? Int, let of = o["of"] as? Int, let t = o["text"] as? String,
       (0...99).contains(n), (0...99).contains(of) {
      last = Progress(n: n, of: max(of, n), text: String(t.prefix(120)))
    } else if l.hasPrefix("{\"omacvm_failed\""), let o = (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any],
              let t = o["text"] as? String {
      let p = o["part"] as? String ?? ""
      failed = Failed(part: validFeatureName(p) ? p : "", text: String(t.prefix(160)))
    } else {
      rest.append(l)
    }
  }
  return (last, rest, failed)
}

/// With update checks off, an update installs only from a check the person
/// asked for in the last hour (never from an old cached result).
func updateGate(checksEnabled: Bool, checkedAt: Date?, now: Date = Date()) -> PolicyError? {
  if checksEnabled { return nil }
  guard let at = checkedAt, now.timeIntervalSince(at) < 3600, now >= at.addingTimeInterval(-60) else {
    return PolicyError(409, "stale-update", "update checks are off and the last result may be old: check for updates first")
  }
  return nil
}

/// One job per VM at a time, at most `jobsPerHour` per VM per hour.
struct JobLimiter {
  private var started: [String: [Date]] = [:]
  private var running: Set<String> = []

  mutating func admit(_ vm: String, now: Date = Date()) -> PolicyError? {
    if running.contains(vm) { return PolicyError(409, "busy", "a job runs for this VM: wait for it") }
    let recent = (started[vm] ?? []).filter { now.timeIntervalSince($0) < 3600 }
    started[vm] = recent
    if recent.count >= jobsPerHour { return PolicyError(429, "rate", "\(jobsPerHour) jobs in the last hour: try later") }
    started[vm] = recent + [now]
    running.insert(vm)
    return nil
  }

  mutating func finished(_ vm: String) { running.remove(vm) }
}

/// "2.9.1" -> [2, 9, 1]; nil for anything else.
func versionParts(_ v: String) -> [Int]? {
  let p = v.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
  guard (1...4).contains(p.count), p.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
  return p.map { $0! }
}

/// a < b as versions (nil when either is not one).
func versionLess(_ a: String, _ b: String) -> Bool? {
  guard var x = versionParts(a), var y = versionParts(b) else { return nil }
  while x.count < y.count { x.append(0) }
  while y.count < x.count { y.append(0) }
  return x.lexicographicallyPrecedes(y)
}

/// Toggles install the Mac's copy of OmacVM into the VM, so they only run
/// when both have the same version (otherwise a toggle would update the VM in
/// passing). Update is the way out. A VM whose update went back (the Mac kept
/// the newer OmacVM) is never locked: turning a feature off and a repair still
/// run, and bring the VM to the Mac's version without that feature or with it
/// installed again. A VM newer than the Mac: the Mac is updated first.
func versionGate(_ r: JobRequest, mac: String, vm: String) -> PolicyError? {
  if r.action == .update || mac == vm { return nil }
  if versionLess(mac, vm) == true {
    return PolicyError(409, "mac-older", "this VM has OmacVM \(vm), the Mac \(mac): update the Mac first (omacvm update on the Mac)")
  }
  if r.action == .disable || r.action == .reinstall { return nil }
  return PolicyError(409, "update-first", "the Mac has OmacVM \(mac), this VM \(vm.isEmpty ? "none" : vm): update first")
}

/// An update job only goes forward: never to a release older than the Mac's
/// OmacVM, and only when it brings this VM something newer.
func forwardGate(release: String, mac: String, vm: String) -> PolicyError? {
  guard versionLess(release, mac) == false else {
    return PolicyError(409, "not-newer", "the Mac has OmacVM \(mac), newer than the release \(release): nothing to install")
  }
  if versionLess(release, vm) == true {
    return PolicyError(409, "not-newer", "this VM has OmacVM \(vm), newer than the release \(release): nothing to install")
  }
  if versionLess(mac, release) == false && versionLess(vm, release) == false {
    return PolicyError(409, "not-newer", "the Mac and this VM have OmacVM \(release) already")
  }
  return nil
}

/// The manifest's fields that are used, checked after its signature.
struct Manifest: Equatable {
  let version: String, commit: String, date: String, notesURL: String, proto: Int, protoMin: Int
  let parts: [String: [String: String]]   // name -> digest, release, note
}

func parseManifest(_ data: Data) -> Result<Manifest, PolicyError> {
  func bad(_ m: String) -> Result<Manifest, PolicyError> { .failure(PolicyError(502, "bad-manifest", m)) }
  guard data.count <= 256 << 10, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return bad("not JSON") }
  guard (o["schema"] as? Int) == 1 else { return bad("unknown schema") }
  // One release key signs this feed and OmacVM.app's (kind "app-feed"): a
  // signed document of the other kind is no manifest.
  guard (o["kind"] as? String) == "control-manifest" else { return bad("not a control centre manifest") }
  guard let v = o["version"] as? String, v.range(of: #"^\d{1,4}\.\d{1,4}\.\d{1,6}$"#, options: .regularExpression) != nil else { return bad("version") }
  guard let c = o["commit"] as? String, c.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { return bad("commit") }
  let date = (o["date"] as? String).flatMap { $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? $0 : nil } ?? ""
  let notes = (o["notes_url"] as? String).flatMap { $0.hasPrefix("https://github.com/gillesgoetsch/omacvm/") && $0.count < 200 ? $0 : nil } ?? ""
  guard let raw = o["parts"] as? [String: Any], raw.count <= 64 else { return bad("parts") }
  var parts: [String: [String: String]] = [:]
  for (name, value) in raw {
    guard validFeatureName(name), let p = value as? [String: Any],
          let d = p["digest"] as? String, d.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil,
          let r = p["release"] as? String, r.range(of: #"^\d{1,4}\.\d{1,4}\.\d{1,6}$"#, options: .regularExpression) != nil else {
      return bad("part '\(name.prefix(32))'")
    }
    var entry = ["digest": d, "release": r]
    if let n = p["note"] as? String { entry["note"] = String(n.prefix(120)).filter { !$0.isNewline } }
    parts[name] = entry
  }
  return .success(Manifest(version: v, commit: c, date: date, notesURL: notes,
                           proto: o["proto"] as? Int ?? 1, protoMin: o["proto_min"] as? Int ?? 1, parts: parts))
}

/// The manifest's Ed25519 signature (base64 in the .sig file) under the
/// release key (base64 of the raw 32-byte public key). Checked before any
/// field of the manifest is read.
func manifestSigned(_ data: Data, sig: Data, key: String) -> Bool {
  guard let k = Data(base64Encoded: key.trimmingCharacters(in: .whitespacesAndNewlines)),
        let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: k),
        let s = Data(base64Encoded: String(decoding: sig, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
        s.count == 64 else { return false }
  return pub.isValidSignature(s, for: data)
}
