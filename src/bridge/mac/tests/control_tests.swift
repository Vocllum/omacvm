// Tests for control_policy.swift: every accepted request shape and every
// refusal. Run: src/bridge/mac/tests/run.sh (CI runs it too).
import CryptoKit
import Foundation

var failures = 0, passed = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
  if ok { passed += 1 } else { failures += 1; print("FAIL line \(line): \(what)") }
}

let known: Set<String> = ["bridge", "gestures", "scroll-momentum", "mac-clock", "control-centre"]
func route(_ m: String, _ p: String, _ body: String = "") -> Result<ControlRoute, PolicyError> {
  controlRoute(method: m, path: p, body: Data(body.utf8), known: known)
}
func ok(_ r: Result<ControlRoute, PolicyError>) -> ControlRoute? { if case .success(let v) = r { return v }; return nil }
func err(_ r: Result<ControlRoute, PolicyError>) -> PolicyError? { if case .failure(let e) = r { return e }; return nil }

@main struct ControlTests {
  static func main() {
    // ---- accepted ----
    expect(ok(route("GET", "/omacvm/hello")) == .hello, "hello")
    expect(ok(route("GET", "/omacvm/status")) == .status, "status")
    expect(ok(route("GET", "/omacvm/updates")) == .updates, "updates")
    expect(ok(route("POST", "/omacvm/updates/check")) == .updatesCheck, "check, no body")
    expect(ok(route("POST", "/omacvm/updates/check", "{}")) == .updatesCheck, "check, {}")
    expect(ok(route("POST", "/omacvm/settings/update-checks", #"{"enabled": false}"#)) == .setUpdateChecks(false), "silence")
    expect(ok(route("POST", "/omacvm/settings/update-checks", #"{"enabled": true}"#)) == .setUpdateChecks(true), "checks on")
    expect(ok(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": ["scroll-momentum", "gestures"]}"#))
           == .startJob(JobRequest(action: .enable, features: ["scroll-momentum", "gestures"])), "enable two")
    expect(ok(route("POST", "/omacvm/jobs", #"{"action": "disable", "features": ["mac-clock"]}"#))
           == .startJob(JobRequest(action: .disable, features: ["mac-clock"])), "disable")
    expect(ok(route("POST", "/omacvm/jobs", #"{"action": "reinstall", "features": ["bridge"]}"#))
           == .startJob(JobRequest(action: .reinstall, features: ["bridge"])), "reinstall")
    expect(ok(route("POST", "/omacvm/jobs", #"{"action": "update"}"#)) == .startJob(JobRequest(action: .update, features: [])), "update")
    expect(ok(route("GET", "/omacvm/jobs/0123456789abcdef")) == .job("0123456789abcdef"), "job")

    // ---- refused ----
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "run", "features": ["bridge"]}"#))?.code == "bad-action", "unknown action")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": ["rm"]}"#))?.code == "unknown-feature", "unknown feature")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": ["bridge; rm -rf ~"]}"#))?.code == "bad-features", "shell metacharacters")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": ["$(id)"]}"#))?.code == "bad-features", "substitution")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": ["--vm"]}"#))?.code == "bad-features", "an option as a name")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": ["Bridge"]}"#))?.code == "bad-features", "upper case")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": [1]}"#))?.code == "bad-features", "a number")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": []}"#))?.code == "bad-features", "no features")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": ["bridge", "bridge"]}"#))?.code == "bad-features", "twice")
    let many = (0..<17).map { "\"f\($0)x\"" }.joined(separator: ",")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": [\#(many)]}"#))?.code == "bad-features", "17 features")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": ["bridge"], "vm": "Other"}"#))?.code == "unknown-key", "naming a VM")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "update", "features": ["bridge"]}"#))?.code == "bad-body", "update with features")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "update", "commit": "abc"}"#))?.code == "unknown-key", "update picking a commit")
    expect(err(route("POST", "/omacvm/jobs", #"["enable"]"#))?.code == "bad-json", "not an object")
    expect(err(route("POST", "/omacvm/jobs", "{"))?.code == "bad-json", "broken JSON")
    expect(err(route("POST", "/omacvm/jobs", "{\"action\": \"enable\", \"features\": [\"bridge\"], \"x\": \"" + String(repeating: "a", count: 5000) + "\"}"))?.status == 413, "oversized body")
    expect(err(route("POST", "/omacvm/settings/update-checks", #"{"enabled": 1}"#))?.code == "bad-body", "1 is not true")
    expect(err(route("POST", "/omacvm/settings/update-checks", #"{"enabled": "false"}"#))?.code == "bad-body", "a string is not a bool")
    expect(err(route("POST", "/omacvm/updates/check", #"{"url": "http://evil"}"#))?.code == "unknown-key", "check from another feed")
    expect(err(route("GET", "/omacvm/jobs/../../etc"))?.status == 404, "job path")
    expect(err(route("GET", "/omacvm/jobs/ABCDEF0123456789"))?.status == 404, "job id upper case")
    expect(err(route("GET", "/omacvm/run"))?.status == 404, "no other requests")
    expect(err(route("DELETE", "/omacvm/jobs"))?.status == 405, "method")
    expect(err(route("GET", "/omacvm/hello", "{}"))?.code == "body", "GET with a body")
    expect(err(route("GET", "/state"))?.status == 404, "outside /omacvm/")

    // ---- protocol ----
    if case .success(let p) = negotiateProto(nil) { expect(p == 1, "no header: 1") } else { expect(false, "no header") }
    if case .success(let p) = negotiateProto("7") { expect(p == controlProto, "newer guest: ours") } else { expect(false, "newer guest") }
    if case .failure(let e) = negotiateProto("0") { expect(e.code == "proto", "older than min") } else { expect(false, "proto 0") }

    // ---- which VM ----
    let appA = VMEntry(name: "Omarchy", type: "app", state: "running", ip: "127.0.0.1:2222", omacvm: "2.9.0", setup: true)
    let a = VMEntry(name: "A", type: "parallels", state: "running", ip: "10.211.55.5", omacvm: "2.9.0", setup: true)
    let b = VMEntry(name: "B", type: "parallels", state: "running", ip: "10.211.55.6", omacvm: "2.9.0", setup: true)
    let stranger = VMEntry(name: "C", type: "utm", state: "running", ip: "10.211.55.7", omacvm: "", setup: false)
    let stopped = VMEntry(name: "D", type: "parallels", state: "stopped", ip: "10.211.55.8", omacvm: "2.9.0", setup: true)
    if case .success(let v) = vmForPeer("10.211.55.6", [a, b]) { expect(v == b, "peer B") } else { expect(false, "peer B") }
    if case .failure(let e) = vmForPeer("10.211.55.7", [a, stranger]) { expect(e.code == "unknown-vm", "not set up") } else { expect(false, "stranger") }
    if case .failure(let e) = vmForPeer("10.211.55.8", [stopped]) { expect(e.code == "unknown-vm", "stopped") } else { expect(false, "stopped") }
    let twin = VMEntry(name: "A2", type: "utm", state: "running", ip: "10.211.55.5", omacvm: "2.9.0", setup: true)
    if case .failure(let e) = vmForPeer("10.211.55.5", [a, twin]) { expect(e.code == "ambiguous-vm", "two VMs on one address") } else { expect(false, "twin") }
    if case .failure(let e) = vmForPeer("127.0.0.1", [a]) { expect(e.status == 403, "127.0.0.1") } else { expect(false, "loopback") }
    if case .failure(let e) = vmForPeer("127.0.0.1", [appA]) { expect(e.code == "app-vm", "an app VM's address is no identity") } else { expect(false, "app loopback") }

    // ---- argv ----
    expect(jobArgv(cli: "/c/omacvm", JobRequest(action: .enable, features: ["gestures"]), vm: "My VM", commit: nil)
           == ["/c/omacvm", "enable", "gestures", "--vm", "My VM", "--yes", "--transaction"], "enable argv")
    expect(jobArgv(cli: "/c/omacvm", JobRequest(action: .update, features: []), vm: "V", commit: String(repeating: "a", count: 40))
           == ["/c/omacvm", "update", "--vm", "V", "--transaction", "--yes", "--commit", String(repeating: "a", count: 40)], "update argv")
    expect(jobArgv(cli: "/c/omacvm", JobRequest(action: .reinstall, features: ["bridge"]), vm: "V", commit: nil)
           == ["/c/omacvm", "apply", "--vm", "V", "--transaction", "--yes", "--reinstall", "bridge"], "reinstall: that feature only")
    expect(jobArgv(cli: "/c/omacvm", JobRequest(action: .reinstall, features: ["gestures", "mac-clock"]), vm: "V", commit: nil).suffix(4)
           == ["--reinstall", "gestures", "--reinstall", "mac-clock"], "reinstall two")

    // ---- the VM's own key (a VM that takes another one's address) ----
    let k = String(repeating: "5a", count: 32)
    expect(vmKeyCheck(given: k, stored: k + "\n") == nil, "its key")
    expect(vmKeyCheck(given: String(repeating: "5b", count: 32), stored: k)?.code == "vm-key", "another VM's key")
    expect(vmKeyCheck(given: nil, stored: k)?.code == "vm-key", "no key sent")
    expect(vmKeyCheck(given: String(k.prefix(63)), stored: k)?.code == "vm-key", "a shorter key")
    expect(vmKeyCheck(given: k, stored: nil)?.code == "no-vm-key", "no key on the Mac: refused")
    expect(vmKeyCheck(given: "", stored: "")?.code == "no-vm-key", "empty is no key")
    // As lib/mac.sh vm_key_file: printf '%s/%s' parallels "My VM" | shasum -a 256 | cut -c1-32
    expect(vmKeyName(type: "parallels", name: "My VM") == "6904477035f2e239f66f28d2d8ff406a", "key file name: \(vmKeyName(type: "parallels", name: "My VM"))")

    // ---- OmacVM.app's VMs (the app names them; its relay key) ----
    let appOff = VMEntry(name: "Off", type: "app", state: "stopped", ip: "", omacvm: "", setup: false)
    if case .success(let v) = vmForApp("Omarchy", [a, appA]) { expect(v == appA, "app VM by name") } else { expect(false, "app VM") }
    if case .failure(let e) = vmForApp("A", [a, appA]) { expect(e.code == "unknown-vm", "a Parallels VM is no app VM") } else { expect(false, "type") }
    if case .failure(let e) = vmForApp("Off", [appOff]) { expect(e.code == "unknown-vm", "stopped app VM") } else { expect(false, "stopped") }

    // ---- job state: the exit code alone ----
    expect(jobState(rc: nil, alive: true) == "running" && jobState(rc: nil, alive: false) == "failed", "running / gone")
    expect(jobState(rc: 0, alive: false) == "done" && jobState(rc: 4, alive: false) == "rolled-back", "done / rolled back")
    expect(jobState(rc: 1, alive: false) == "failed" && jobState(rc: 3, alive: false) == "failed", "failed")

    // ---- progress lines ----
    let (p, rest) = progress(["==> OmacVM Bridge on the Mac", #"{"omacvm_progress": 1, "step": "mac", "n": 1, "of": 4, "text": "the Mac side"}"#,
                              "pacman: rolled back nothing", #"{"omacvm_progress": 1, "step": "vm", "n": 3, "of": 4, "text": "the VM side"}"#])
    expect(p == Progress(n: 3, of: 4, text: "the VM side"), "last progress line")
    expect(rest == ["==> OmacVM Bridge on the Mac", "pacman: rolled back nothing"], "progress lines are not shown as output")
    expect(progress([#"{"omacvm_progress": 1, "n": 500, "of": 4, "text": "x"}"#]).0 == nil, "nonsense counts")
    expect(progress(["{\"omacvm_progress\": 1, broken"]).0 == nil, "broken line")

    // ---- updates with checks off ----
    let now = Date()
    expect(updateGate(checksEnabled: true, checkedAt: nil, now: now) == nil, "checks on: the weekly result")
    expect(updateGate(checksEnabled: false, checkedAt: now.addingTimeInterval(-300), now: now) == nil, "off, checked 5 min ago")
    expect(updateGate(checksEnabled: false, checkedAt: now.addingTimeInterval(-7200), now: now)?.code == "stale-update", "off, 2 h old")
    expect(updateGate(checksEnabled: false, checkedAt: nil, now: now)?.code == "stale-update", "off, never checked")
    expect(updateGate(checksEnabled: false, checkedAt: now.addingTimeInterval(86400), now: now)?.code == "stale-update", "a time in the future")

    // ---- limits ----
    var lim = JobLimiter()
    let t0 = Date()
    expect(lim.admit("A", now: t0) == nil, "first job")
    expect(lim.admit("A", now: t0)?.code == "busy", "one at a time")
    expect(lim.admit("B", now: t0) == nil, "another VM")
    lim.finished("A")
    for i in 1..<jobsPerHour { expect(lim.admit("A", now: t0.addingTimeInterval(Double(i))) == nil, "job \(i)"); lim.finished("A") }
    expect(lim.admit("A", now: t0.addingTimeInterval(100))?.code == "rate", "21st in an hour")
    expect(lim.admit("A", now: t0.addingTimeInterval(3700)) == nil, "an hour later")

    // ---- versions ----
    expect(versionGate(JobRequest(action: .enable, features: ["bridge"]), mac: "2.9.0", vm: "2.8.0")?.code == "update-first", "older VM")
    expect(versionGate(JobRequest(action: .update, features: []), mac: "2.9.0", vm: "2.8.0") == nil, "update always")
    expect(versionGate(JobRequest(action: .disable, features: ["bridge"]), mac: "2.9.0", vm: "2.9.0") == nil, "same version")

    // ---- manifest ----
    let key = Curve25519.Signing.PrivateKey()
    let other = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let digest = "sha256:" + String(repeating: "ab", count: 32)
    let body = Data(#"{"schema": 1, "version": "2.9.1", "commit": "\#(String(repeating: "c", count: 40))", "date": "2026-10-20", "notes_url": "https://github.com/gillesgoetsch/omacvm/releases/tag/v2.9.1", "proto": 1, "proto_min": 1, "parts": {"gestures": {"digest": "\#(digest)", "release": "2.9.1", "note": "fewer missed swipes"}}}"#.utf8)
    let sig = Data(try! key.signature(for: body).base64EncodedString().utf8)
    expect(manifestSigned(body, sig: sig, key: pub), "good signature")
    expect(!manifestSigned(body, sig: Data(try! other.signature(for: body).base64EncodedString().utf8), key: pub), "wrong key")
    var tampered = body; tampered[tampered.count - 3] = UInt8(ascii: "x")
    expect(!manifestSigned(tampered, sig: sig, key: pub), "changed manifest")
    expect(!manifestSigned(body, sig: Data("bm90IGEgc2ln".utf8), key: pub), "garbage signature")
    expect(!manifestSigned(body, sig: sig, key: ""), "no key")
    if case .success(let m) = parseManifest(body) {
      expect(m.version == "2.9.1" && m.parts["gestures"]?["note"] == "fewer missed swipes", "manifest fields")
    } else { expect(false, "manifest parses") }
    let schema2 = Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: #""schema": 1"#, with: #""schema": 2"#).utf8)
    if case .failure(let e) = parseManifest(schema2) { expect(e.code == "bad-manifest", "schema 2") } else { expect(false, "schema 2") }
    let badPart = Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\"gestures\"", with: "\"../x\"").utf8)
    if case .failure = parseManifest(badPart) { expect(true, "bad part name") } else { expect(false, "bad part name") }

    print("control policy: \(passed) passed, \(failures) failed")
    exit(failures == 0 ? 0 : 1)
  }
}
