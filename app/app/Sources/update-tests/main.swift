// The self-update's checks (OmacVMUpdate), without Xcode:
//   cd app/app && swift run update-tests
// Exit 0 when all pass. CI runs it on every pull request.
import CryptoKit
import Foundation
import OmacVMUpdate

// A copy of this tool inside a fake app bundle plays a VM's QEMU (a copied
// system tool is killed: platform binaries only run from their place).
if CommandLine.arguments.dropFirst().first == "--sleep" { sleep(30); exit(0) }

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}

// Versions
let v = { (s: String) in Version(s)! }
expect(v("2.10.0") > v("2.9.1"), "2.10.0 is newer than 2.9.1")
expect(v("2.7") == v("2.7.0"), "2.7 is 2.7.0")
expect(v("2.7.0") < v("2.7.1"), "2.7.0 is older than 2.7.1")
for bad in ["", "v2.7.0", "2.9.0 RC", "2.9.0-rc2", "1.2.3.4.5", "2..1", " ", "1234567.0"] {
    expect(Version(bad) == nil, "'\(bad)' is not a version")
}

// When to check
let now = Date()
let day: TimeInterval = 24 * 3600
expect(UpdatePolicy.isDue(lastCheck: nil, now: now), "never checked: due")
expect(!UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-6 * day), now: now), "6 days ago: not due")
expect(UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-7 * day), now: now), "7 days ago: due")
expect(!UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(3600), now: now), "an hour ahead (clock skew): not due")
expect(UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(2 * day), now: now), "2 days ahead (clock went back): due")

// The feed: signature first, then strict fields
let key = Curve25519.Signing.PrivateKey()
let pub = key.publicKey.rawRepresentation.base64EncodedString()
let sha = String(repeating: "ab", count: 32)
func feed(_ fields: [String: Any]) -> Data {
    var o: [String: Any] = ["schema": 1, "kind": "app-feed", "version": "2.9.1", "url": "https://github.com/gillesgoetsch/omacvm/releases/download/v2.9.1/OmacVM-2.9.1.zip",
                            "length": 61_234_567, "sha256": sha, "minimum_macos": "15.0",
                            "notes_url": "https://github.com/gillesgoetsch/omacvm/releases/tag/v2.9.1"]
    for (k, val) in fields { o[k] = val is NSNull ? nil : val }
    return try! JSONSerialization.data(withJSONObject: o, options: .sortedKeys)
}
func sign(_ d: Data, with k: Curve25519.Signing.PrivateKey = key) -> Data {
    Data((try! k.signature(for: d)).base64EncodedString().utf8 + [0x0a])
}
let good = feed([:])
if case .success(let a) = Appcast.verified(feed: good, signature: sign(good), publicKey: pub) {
    expect(a.version == v("2.9.1") && a.length == 61_234_567 && a.sha256 == sha && a.minimumMacOS == v("15.0"), "a good feed reads")
} else { expect(false, "a good feed reads") }
var tampered = good; tampered[tampered.count / 2] ^= 1
expect(Appcast.verified(feed: tampered, signature: sign(good), publicKey: pub) == .failure(.badSignature), "one changed byte: refused")
expect(Appcast.verified(feed: good, signature: sign(good, with: Curve25519.Signing.PrivateKey()), publicKey: pub) == .failure(.badSignature),
       "signed with another key: refused")
expect(Appcast.verified(feed: good, signature: Data("garbage".utf8), publicKey: pub) == .failure(.badSignature), "garbage signature: refused")
expect(Appcast.verified(feed: good, signature: sign(good), publicKey: "") == .failure(.noKey), "no key: refused")
let big = Data(repeating: 0x20, count: Appcast.maxFeedBytes + 1)
expect(Appcast.verified(feed: big, signature: sign(big), publicKey: pub) == .failure(.tooLarge), "oversized feed: refused")
let bad: [(String, [String: Any])] = [
    ("schema 2", ["schema": 2]), ("no kind", ["kind": NSNull()]), ("the control centre's manifest", ["kind": "control-manifest"]),
    ("kind as a number", ["kind": 1]), ("version with a suffix", ["version": "2.9.1-rc1"]),
    ("length as a bool", ["length": true]), ("negative length", ["length": -1]), ("fractional length", ["length": 1.5]),
    ("length over 2 GB", ["length": Int64(3) << 30]), ("upper-case digest", ["sha256": sha.uppercased()]),
    ("short digest", ["sha256": "abc"]), ("http to another host", ["url": "http://example.com/OmacVM.zip"]),
    ("file URL", ["url": "file:///tmp/OmacVM.zip"]), ("notes over http", ["notes_url": "http://example.com"]),
    ("no url", ["url": NSNull()]), ("minimum_macos as a number", ["minimum_macos": 15]),
]
for (what, change) in bad {
    let f = feed(change)
    if case .failure(.malformed) = Appcast.verified(feed: f, signature: sign(f), publicKey: pub) {
        expect(true, "\(what): refused")
    } else { expect(false, "\(what): refused") }
}
let local = feed(["url": "http://127.0.0.1:8765/OmacVM.zip"])
if case .success = Appcast.verified(feed: local, signature: sign(local), publicKey: pub) { expect(true, "http to 127.0.0.1 (a test feed): allowed") }
else { expect(false, "http to 127.0.0.1 (a test feed): allowed") }

// What to offer
if case .success(let a) = Appcast.verified(feed: good, signature: sign(good), publicKey: pub) {
    let os = v("15.7.4")
    expect(UpdatePolicy.offer(a, current: v("2.9.1"), skipped: nil, os: os) == .upToDate, "same version: nothing")
    expect(UpdatePolicy.offer(a, current: v("3.0.0"), skipped: nil, os: os) == .upToDate, "older feed (replayed): nothing")
    expect(UpdatePolicy.offer(a, current: v("2.7.0"), skipped: nil, os: os) == .newer, "newer: offered")
    expect(UpdatePolicy.offer(a, current: v("2.7.0"), skipped: "2.9.1", os: os) == .skipped, "skipped version: not offered")
    expect(UpdatePolicy.offer(a, current: v("2.7.0"), skipped: "2.8.0", os: os) == .newer, "newer than the skipped one: offered")
    expect(UpdatePolicy.offer(a, current: v("2.7.0"), skipped: nil, os: v("14.6")) == .needsMacOS("15.0"), "too old a macOS: not offered")
}

// Test hooks: only in test builds
let hookEnv = ["OMACVM_APPCAST_URL": "http://127.0.0.1:1/feed.json", "OMACVM_APPCAST_KEY": ""]
expect(!TestHooks.allowed(bundleID: "org.omacvm.app"), "release build: no test hooks")
expect(!TestHooks.allowed(bundleID: nil) && !TestHooks.allowed(bundleID: ""), "no bundle id: no test hooks")
expect(TestHooks.allowed(bundleID: "org.omacvm.sutest"), "test build: test hooks")
expect(TestHooks.value("OMACVM_APPCAST_URL", bundleID: "org.omacvm.app", environment: hookEnv) == nil, "release build: feed URL hook ignored")
expect(TestHooks.value("OMACVM_APPCAST_URL", bundleID: "org.omacvm.sutest", environment: hookEnv) == "http://127.0.0.1:1/feed.json",
       "test build: feed URL hook read")
expect(TestHooks.value("OMACVM_APPCAST_KEY", bundleID: "org.omacvm.sutest", environment: hookEnv) == nil, "empty hook: unset")

// The shared switch (control centre and app)
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omacvm-update-tests-\(getpid())")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let settings = SharedSettings(directory: tmp.appendingPathComponent("support"))
expect(settings.updateChecks, "no settings file: checks on")
try! FileManager.default.createDirectory(at: settings.file.deletingLastPathComponent(), withIntermediateDirectories: true)
try! Data(#"{"update_checks": 0, "other": "kept"}"#.utf8).write(to: settings.file)
expect(settings.updateChecks, "update_checks 0 (not a bool): on")
try! settings.setUpdateChecks(false)
expect(!settings.updateChecks, "switched off: off")
let kept = (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings.file))) as? [String: Any]
expect(kept?["other"] as? String == "kept", "other keys kept")
try! Data("not json".utf8).write(to: settings.file)
expect(settings.updateChecks, "unreadable file: on")

// Files
let abc = tmp.appendingPathComponent("abc")
try! Data("abc".utf8).write(to: abc)
expect((try? Files.sha256(abc)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of a file")
let unpacked = tmp.appendingPathComponent("unpacked")
try! FileManager.default.createDirectory(at: unpacked.appendingPathComponent("OmacVM.app/Contents"), withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: unpacked.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true)
expect(Files.singleApp(in: unpacked)?.lastPathComponent == "OmacVM.app", "one app in the zip: found")
try! FileManager.default.createSymbolicLink(at: unpacked.appendingPathComponent("Other.app"), withDestinationURL: tmp)
expect(Files.singleApp(in: unpacked) == nil, "two apps in the zip: refused")
let linked = tmp.appendingPathComponent("linked")
try! FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
try! FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("OmacVM.app"), withDestinationURL: unpacked)
expect(Files.singleApp(in: linked) == nil, "an app that is a link: refused")

// Code signatures: Apple's own tools are valid but not OmacVM's team
expect(CodeCheck.problem(URL(fileURLWithPath: "/bin/ls"), requirement: nil) == nil, "/bin/ls has a valid signature")
expect(CodeCheck.problem(URL(fileURLWithPath: "/bin/ls"), requirement: CodeCheck.developerID())?.contains("Developer ID") == true,
       "/bin/ls is not OmacVM's Developer ID")
let unsigned = tmp.appendingPathComponent("unsigned")
try! Data("#!/bin/sh\n".utf8).write(to: unsigned)
expect(CodeCheck.problem(unsigned, requirement: CodeCheck.developerID()) != nil, "an unsigned file: refused")

// Who may replace the bundle: its folder and the bundle itself writable
let folder = tmp.appendingPathComponent("Applications")
let mine = folder.appendingPathComponent("OmacVM.app")
try! FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
expect(UpdatePolicy.writeProblem(bundle: mine) == nil, "own folder and bundle: can update")
try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: mine.path)
expect(UpdatePolicy.writeProblem(bundle: mine)?.contains("OmacVM.app is not writable") == true, "bundle not writable: says so")
try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mine.path)
try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
expect(UpdatePolicy.writeProblem(bundle: mine)?.contains("Applications is not writable") == true, "folder not writable: says so")
try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)

// Processes from inside a bundle (a VM's QEMU)
let fake = tmp.appendingPathComponent("Fake.app")
let exe = fake.appendingPathComponent("Contents/MacOS/qemu")
try! FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
try! FileManager.default.copyItem(at: Bundle.main.executableURL!, to: exe)
let p = Process()
p.executableURL = exe
p.arguments = ["--sleep"]
try! p.run()
usleep(200_000)
expect(Running.pids(inside: fake).contains(p.processIdentifier), "a process from inside the bundle is seen")
expect(Running.pids(inside: tmp.appendingPathComponent("Other.app")).isEmpty, "another bundle: nothing")
p.terminate(); p.waitUntilExit()
expect(Running.pids(inside: fake).isEmpty, "after it ends: nothing")

// One update folder per copy; the swap's work folder on the app's volume
let copyA = folder.appendingPathComponent("OmacVM.app")
let copyB = tmp.appendingPathComponent("Other place/OmacVM.app")
try! FileManager.default.createDirectory(at: copyB, withIntermediateDirectories: true)
let keyA = UpdateFolders.key(for: copyA)
expect(keyA.range(of: "^OmacVM-[0-9a-f]{8}$", options: .regularExpression) != nil, "folder key: name and 8 hex digits (\(keyA))")
expect(keyA != UpdateFolders.key(for: copyB), "two copies with one name: two folders")
expect(keyA == UpdateFolders.key(for: copyA), "the same copy: the same folder")
let viaLink = tmp.appendingPathComponent("link")
try! FileManager.default.createSymbolicLink(at: viaLink, withDestinationURL: folder)
expect(UpdateFolders.key(for: viaLink.appendingPathComponent("OmacVM.app")) == keyA, "reached through a link: the same folder")
expect(UpdateFolders.key(for: folder.appendingPathComponent("Omarchy.app")).hasPrefix("Omarchy-"), "a renamed copy: its own name")
let home = tmp.appendingPathComponent("support/Updates/org.omacvm.app/\(keyA)")
expect(UpdateFolders.device(home) == UpdateFolders.device(tmp), "a folder not made yet: its parent's volume")
expect(UpdateFolders.work(for: copyA, home: home) == home, "app on the update folder's volume: work there")
// /dev (devfs) is another volume than the temporary folder.
let elsewhere = URL(fileURLWithPath: "/dev/OmacVM.app")
expect(UpdateFolders.device(URL(fileURLWithPath: "/dev")) != UpdateFolders.device(tmp), "/dev is another volume")
expect(UpdateFolders.work(for: elsewhere, home: home).path == "/dev/.omacvm-updates/\(UpdateFolders.key(for: elsewhere))",
       "app on another volume: work next to it")

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
