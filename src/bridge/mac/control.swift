// The control centre's requests on the Mac (docs/adr/0031): /omacvm/*.
// control_policy.swift decides what is allowed; this file runs it: which VM
// asked (from `omacvm vms --json`), the Mac's view of its features and checks,
// jobs (the omacvm CLI with a fixed argv, no shell, in its own session so an
// update that restarts the Bridge does not stop it), and the signed update
// feed (docs/adr/0032).
//
// Threading: requests arrive on worker threads (server.swift). Shared state
// (caches, jobs, limiter) is only touched on `q`; CLI runs and downloads
// happen outside it.
import Foundation

let omacvmSupport = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/omacvm"
let jobsDir = supportDir + "/jobs"
let feedDefault = "https://github.com/gillesgoetsch/omacvm/releases/latest/download/omacvm-manifest.json"

/// What a spawned CLI run gets: a fixed, small environment.
func cliEnvironment(extra: [String: String] = [:]) -> [String: String] {
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  var e = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home,
           "USER": NSUserName(), "LOGNAME": NSUserName(), "LANG": "en_US.UTF-8", "TERM": "dumb",
           "TMPDIR": NSTemporaryDirectory()]
  for (k, v) in extra { e[k] = v }
  return e
}

/// posix_spawn with a fixed argv: stdin /dev/null, stdout and stderr to `out`,
/// every other descriptor closed, its own session.
func spawn(_ argv: [String], env: [String: String], out: Int32) -> pid_t? {
  var fa: posix_spawn_file_actions_t?
  var attr: posix_spawnattr_t?
  posix_spawn_file_actions_init(&fa); defer { posix_spawn_file_actions_destroy(&fa) }
  posix_spawnattr_init(&attr); defer { posix_spawnattr_destroy(&attr) }
  posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
  posix_spawn_file_actions_adddup2(&fa, out, 1)
  posix_spawn_file_actions_adddup2(&fa, out, 2)
  var none = sigset_t(), all = sigset_t()
  sigemptyset(&none); sigfillset(&all)
  posix_spawnattr_setsigmask(&attr, &none)
  posix_spawnattr_setsigdefault(&attr, &all)
  posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
  let cargv = argv.map { strdup($0) } + [nil]
  let cenv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
  defer { cargv.forEach { free($0) }; cenv.forEach { free($0) } }
  var pid = pid_t()
  return posix_spawn(&pid, argv[0], &fa, &attr, cargv, cenv) == 0 ? pid : nil
}

/// A read-only CLI run: its output, or nil after `timeout` (then killed).
func runCLI(_ argv: [String], timeout: Double) -> (Int32, Data)? {
  var p: [Int32] = [0, 0]
  guard pipe(&p) == 0 else { return nil }
  guard let pid = spawn(argv, env: cliEnvironment(), out: p[1]) else { close(p[0]); close(p[1]); return nil }
  close(p[1])
  var data = Data(), buf = [UInt8](repeating: 0, count: 65536)
  let deadline = Date().addingTimeInterval(timeout)
  var pfd = pollfd(fd: p[0], events: Int16(POLLIN), revents: 0)
  while data.count < 4 << 20 {
    let left = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
    if left == 0 || poll(&pfd, 1, left) <= 0 { kill(-pid, SIGKILL); break }
    let n = read(p[0], &buf, buf.count)
    if n <= 0 { break }
    data.append(contentsOf: buf[0..<n])
  }
  close(p[0])
  var status: Int32 = 0
  waitpid(pid, &status, 0)
  guard Date() < deadline else { return nil }
  return ((status >> 8) & 0xff, data)
}

/// The omacvm CLI the Bridge may run: from the file src/mac/install.sh writes
/// (OMACVM_CONTROL_CLI for tests). It and the folders whose scripts it runs
/// must belong to this user and not be writable by others.
func controlCLI() -> Result<String, PolicyError> {
  let env = ProcessInfo.processInfo.environment
  let raw = env["OMACVM_CONTROL_CLI"] ?? (try? String(contentsOfFile: omacvmSupport + "/cli", encoding: .utf8)) ?? ""
  let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard path.hasPrefix("/"), !path.contains("/../") else {
    return .failure(PolicyError(503, "no-cli", "the Mac's OmacVM is not set up for the control centre: omacvm update on the Mac"))
  }
  let root = (path as NSString).deletingLastPathComponent
  for p in [path, root, root + "/src", root + "/src/cmd", root + "/src/lib"] {
    var st = stat()
    guard lstat(p, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o022 == 0,
          p != path || (st.st_mode & S_IFMT) == S_IFREG else {
      return .failure(PolicyError(503, "cli-unsafe", "the Mac's OmacVM at \(p) is not this user's alone: not run"))
    }
  }
  return .success(path)
}

func cliRoot(_ cli: String) -> String { (cli as NSString).deletingLastPathComponent }

func macFeatures(_ cli: String) -> [String] {
  let tsv = (try? String(contentsOfFile: cliRoot(cli) + "/src/features.tsv", encoding: .utf8)) ?? ""
  return tsv.split(separator: "\n").compactMap { line in
    let name = String(line.split(separator: "\t", maxSplits: 1).first ?? "")
    return validFeatureName(name) ? name : nil
  }
}

func macVersion(_ cli: String) -> String {
  ((try? String(contentsOfFile: cliRoot(cli) + "/src/VERSION", encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

func chipName() -> String {
  var size = 0
  sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
  var b = [CChar](repeating: 0, count: max(size, 1))
  sysctlbyname("machdep.cpu.brand_string", &b, &size, nil, 0)
  return String(cString: b)
}

let ansi = try! NSRegularExpression(pattern: "\u{1b}\\[[0-9;?]*[A-Za-z]")
/// A job's output for the VM: no colours, the Mac's home folder as ~.
func cleanLines(_ data: Data) -> [String] {
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  var s = String(decoding: data, as: UTF8.self)
  s = ansi.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
  s = s.replacingOccurrences(of: home, with: "~").replacingOccurrences(of: "\r", with: "\n")
  return s.split(separator: "\n", omittingEmptySubsequences: true).map { String($0.prefix(300)) }
}

final class JobRun {
  let id: String, vm: String, action: String, features: [String], started: Date
  var pid: pid_t
  var rc: Int32?
  init(id: String, vm: String, action: String, features: [String], started: Date, pid: pid_t) {
    self.id = id; self.vm = vm; self.action = action; self.features = features; self.started = started; self.pid = pid
  }
  var logPath: String { jobsDir + "/\(id).log" }
  var rcPath: String { jobsDir + "/\(id).rc" }
}

final class Control {
  private let q = DispatchQueue(label: "omacvm-bridge.control")
  private var limiter = JobLimiter()
  private var vms: (at: Date, list: [VMEntry]) = (.distantPast, [])
  private var status: [String: (at: Date, body: [String: Any])] = [:]
  private var statusRunning: Set<String> = []
  private var jobs: [String: JobRun] = [:]
  private var lastCheck = Date.distantPast
  private var timer: DispatchSourceTimer?

  func start() {
    try? FileManager.default.createDirectory(atPath: jobsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    t.schedule(deadline: .now() + 60, repeating: 6 * 3600, leeway: .seconds(60))
    t.setEventHandler { [self] in weeklyCheck() }
    t.resume()
    timer = t
  }

  // ---- entry point (server.swift) ----
  func handle(fd: Int32, peer: String, method: String, path: String, headers: [String: String], body: Data) {
    var vmName = "-"
    func answer(_ code: Int, _ obj: [String: Any], _ note: String = "") {
      log("control: \(method) \(path) from \(peer) (\(vmName)): \(code)\(note.isEmpty ? "" : " " + note)")
      respond(fd, code, obj)
    }
    func refuse(_ e: PolicyError) { answer(e.status, ["error": e.message, "code": e.code], e.code) }

    let cli: String
    switch controlCLI() { case .success(let c): cli = c; case .failure(let e): return refuse(e) }
    let known = Set(macFeatures(cli))
    let route: ControlRoute
    switch controlRoute(method: method, path: path, body: body, known: known) {
    case .success(let r): route = r
    case .failure(let e): return refuse(e)
    }
    let proto: Int
    switch negotiateProto(headers["x-omacvm-proto"]) { case .success(let p): proto = p; case .failure(let e): return refuse(e) }
    let version = macVersion(cli)

    if route == .hello {
      let v = ProcessInfo.processInfo.operatingSystemVersion
      return answer(200, ["proto": proto, "proto_min": controlProtoMin, "omacvm": version,
                          "requests": ["hello", "status", "updates", "updates/check", "settings/update-checks", "jobs"],
                          "features": known.sorted(), "macos": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                          "chip": chipName()])
    }
    switch route {
    case .updates: return answer(200, updatesAnswer(version))
    case .updatesCheck:
      let wait = q.sync { () -> Double in
        let w = 60 - Date().timeIntervalSince(lastCheck)
        if w <= 0 { lastCheck = Date() }
        return w
      }
      if wait > 0 { return refuse(PolicyError(429, "rate", "checked a moment ago: try again in \(Int(wait) + 1) s")) }
      _ = checkFeed()
      return answer(200, updatesAnswer(version))
    case .setUpdateChecks(let on):
      setUpdateChecks(on)
      return answer(200, updatesAnswer(version), on ? "checks on" : "checks off")
    default: break
    }

    // Everything else is about the VM that asked.
    let vm: VMEntry
    switch vmForPeer(peer, vmList(cli, refreshFor: peer)) { case .success(let v): vm = v; case .failure(let e): return refuse(e) }
    vmName = vm.name
    switch route {
    case .status:
      answer(200, statusAnswer(cli, vm, version))
    case .job(let id):
      guard let j = job(id), j.vm == vmKey(vm) else { return refuse(PolicyError(404, "not-found", "no such job")) }
      answer(200, jobAnswer(j))
    case .startJob(let r):
      if let e = versionGate(r, mac: version, vm: vm.omacvm) { return refuse(e) }
      var commit: String?
      if r.action == .update {
        guard let m = verifiedManifest() else {
          return refuse(PolicyError(409, "no-update", "no verified update on the Mac: check for updates first"))
        }
        commit = m.commit
      }
      if let e = q.sync(execute: { limiter.admit(vmKey(vm)) }) { return refuse(e) }
      let argv = jobArgv(cli: cli, r, vm: vm.name, commit: commit)
      guard let j = startJob(argv, vm: vm, request: r) else {
        q.sync { limiter.finished(vmKey(vm)) }
        return refuse(PolicyError(500, "spawn", "the job did not start"))
      }
      answer(202, jobAnswer(j), "\(r.action.rawValue) \(r.features.joined(separator: " ")) job \(j.id)")
    default:
      refuse(PolicyError(404, "not-found", "not found"))
    }
  }

  // ---- which VM ----
  private func vmKey(_ v: VMEntry) -> String { "\(v.type)/\(v.name)" }

  /// `omacvm vms --json`, cached for a minute; asked again (at most every
  /// 10 s) when a peer is not in it, e.g. a VM that just started.
  private func vmList(_ cli: String, refreshFor peer: String) -> [VMEntry] {
    let (cached, age) = q.sync { (vms.list, Date().timeIntervalSince(vms.at)) }
    if age < 60 && (cached.contains { $0.ip == peer } || age < 10) { return cached }
    guard let (rc, out) = runCLI([cli, "vms", "--json"], timeout: 90), rc == 0,
          let o = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any],
          let list = o["vms"] as? [[String: Any]] else { return cached }
    let fresh = list.map { v in
      VMEntry(name: v["name"] as? String ?? "", type: v["type"] as? String ?? "", state: v["state"] as? String ?? "",
              ip: v["ip"] as? String ?? "", omacvm: v["omacvm"] as? String ?? "", setup: strictBool(v["setup"]) ?? false)
    }
    q.sync { vms = (Date(), fresh) }
    return fresh
  }

  // ---- status: the Mac's view of this VM's features ----
  private func statusAnswer(_ cli: String, _ vm: VMEntry, _ version: String) -> [String: Any] {
    let key = vmKey(vm)
    if let c = q.sync(execute: { status[key] }), Date().timeIntervalSince(c.at) < 30 { return c.body }
    // One run per VM at a time; others get the last answer meanwhile.
    let mine = q.sync { () -> Bool in statusRunning.insert(key).inserted }
    guard mine else { return q.sync { status[key]?.body } ?? ["omacvm": version, "pending": true] }
    defer { _ = q.sync { statusRunning.remove(key) } }
    var feats: Any = NSNull(), checks: Any = NSNull()
    let g = DispatchGroup()
    DispatchQueue.global().async(group: g) {
      if let (_, out) = runCLI([cli, "features", "--vm", vm.name, "--json"], timeout: 60),
         let o = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any], let f = o["features"] as? [[String: Any]] {
        feats = f.map { ["name": $0["name"] ?? "", "on": $0["on"] ?? false, "available": $0["available"] ?? true, "reason": $0["reason"] ?? ""] }
      }
    }
    DispatchQueue.global().async(group: g) {
      if let (_, out) = runCLI([cli, "check", "--vm", vm.name, "--vm-type", vm.type, "--json", "--mac-only"], timeout: 60),
         let o = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any], let c = o["checks"] as? [[String: Any]] {
        checks = c.map { c -> [String: Any] in
          var d: [String: Any] = [:]
          for k in ["status", "name", "detail", "needs_human", "feature"] { d[k] = c[k] ?? "" }
          if let s = d["detail"] as? String { d["detail"] = cleanLines(Data(s.utf8)).joined(separator: " ") }
          return d
        }
      }
    }
    g.wait()
    let body: [String: Any] = ["omacvm": version, "vm_omacvm": vm.omacvm, "type": vm.type, "features": feats,
                               "checks": checks, "checked_at": isoFormat.string(from: Date())]
    q.sync { status[key] = (Date(), body) }
    return body
  }

  // ---- jobs ----
  private func startJob(_ argv: [String], vm: VMEntry, request r: JobRequest) -> JobRun? {
    var b = [UInt8](repeating: 0, count: 8)
    guard SecRandomCopyBytes(kSecRandomDefault, b.count, &b) == errSecSuccess else { return nil }
    let id = b.map { String(format: "%02x", $0) }.joined()
    let j = JobRun(id: id, vm: vmKey(vm), action: r.action.rawValue, features: r.features, started: Date(), pid: 0)
    let fd = open(j.logPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    // omacvm writes its exit code there, also when the Bridge restarts meanwhile (an update).
    guard let pid = spawn(argv, env: cliEnvironment(extra: ["OMACVM_JOB_STATUS": j.rcPath]), out: fd) else { return nil }
    j.pid = pid
    let meta: [String: Any] = ["id": id, "vm": j.vm, "action": j.action, "features": j.features,
                               "started": isoFormat.string(from: j.started), "pid": Int(pid)]
    try? jsonData(meta).write(to: URL(fileURLWithPath: jobsDir + "/\(id).json"))
    q.sync { jobs[id] = j }
    DispatchQueue.global(qos: .utility).async { [self] in
      var st: Int32 = 0
      // A whole thp-kernel build is about 10 minutes; nothing takes an hour.
      let deadline = Date().addingTimeInterval(3600)
      while waitpid(pid, &st, WNOHANG) == 0 {
        if Date() > deadline { kill(-pid, SIGTERM); sleep(5); kill(-pid, SIGKILL) }
        usleep(250_000)
      }
      let rc = (st & 0x7f) == 0 ? (st >> 8) & 0xff : 128 + (st & 0x7f)
      q.sync {
        j.rc = rc
        limiter.finished(j.vm)
        status[j.vm] = nil   // the next status asks again
        vms.at = .distantPast
      }
      log("control: job \(id) (\(j.action) \(j.features.joined(separator: " "))) ended \(rc)")
    }
    return j
  }

  /// A job from this run, or one from before a restart (its files).
  private func job(_ id: String) -> JobRun? {
    if let j = q.sync(execute: { jobs[id] }) { return j }
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: jobsDir + "/\(id).json")),
          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
    let j = JobRun(id: id, vm: o["vm"] as? String ?? "", action: o["action"] as? String ?? "",
                   features: o["features"] as? [String] ?? [], started: isoFormat.date(from: o["started"] as? String ?? "") ?? Date(),
                   pid: pid_t(o["pid"] as? Int ?? 0))
    return j
  }

  private func jobAnswer(_ j: JobRun) -> [String: Any] {
    let data = (try? Data(contentsOf: URL(fileURLWithPath: j.logPath))) ?? Data()
    let lines = cleanLines(data.suffix(65536))
    let steps = lines.filter { $0.hasPrefix("==> ") }
    var rc = q.sync { j.rc }
    if rc == nil, let s = try? String(contentsOfFile: j.rcPath, encoding: .utf8) { rc = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var state: String
    switch rc {
    case nil: state = (j.pid > 0 && kill(j.pid, 0) == 0) ? "running" : "failed"
    case 0: state = "done"
    default: state = lines.contains { $0.contains("rolled back") } ? "rolled-back" : "failed"
    }
    let text = state == "running" ? String((steps.last ?? "starting").dropFirst(steps.isEmpty ? 0 : 4))
      : state == "done" ? "done" : (lines.last ?? "failed")
    return ["id": j.id, "action": j.action, "features": j.features, "state": state, "step": steps.count, "of": 0,
            "text": text, "rc": rc.map { Int($0) } ?? NSNull(), "lines": Array(lines.suffix(20))]
  }

  // ---- updates ----
  private var settingsPath: String { omacvmSupport + "/settings.json" }
  private var updatesPath: String { omacvmSupport + "/updates.json" }

  /// The one switch for update checks (off: no checks, no prompts), shared
  /// with OmacVM.app's own updates.
  func updateChecks() -> Bool {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return true }
    return strictBool(o["update_checks"]) ?? true
  }

  private func setUpdateChecks(_ on: Bool) {
    var o: [String: Any] = [:]
    if let d = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
       let old = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { o = old }
    o["update_checks"] = on
    try? FileManager.default.createDirectory(atPath: omacvmSupport, withIntermediateDirectories: true)
    try? jsonData(o).write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
  }

  private func lastResult() -> [String: Any] {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: updatesPath)),
          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
    return o
  }

  /// The cached manifest, verified again (the file is only a cache).
  private func verifiedManifest() -> Manifest? {
    guard let raw = (lastResult()["raw"] as? String).flatMap({ Data(base64Encoded: $0) }),
          let sig = (lastResult()["sig"] as? String).flatMap({ Data(base64Encoded: $0) }),
          let key = releaseKey(), manifestSigned(raw, sig: sig, key: key),
          case .success(let m) = parseManifest(raw) else { return nil }
    return m
  }

  private func releaseKey() -> String? {
    if let k = ProcessInfo.processInfo.environment["OMACVM_FEED_KEY"], !k.isEmpty { return k }
    guard case .success(let cli) = controlCLI() else { return nil }
    return try? String(contentsOfFile: cliRoot(cli) + "/src/lib/release-key.pub", encoding: .utf8)
  }

  private func fetch(_ url: URL) -> (Data?, String?) {
    var result: (Data?, String?) = (nil, "no answer")
    let sem = DispatchSemaphore(value: 0)
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
    req.setValue("OmacVM-Bridge", forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: req) { d, r, e in
      if let e { result = (nil, e.localizedDescription) }
      else if let h = r as? HTTPURLResponse, h.statusCode != 200 { result = (nil, "HTTP \(h.statusCode)") }
      else if let d, d.count <= 256 << 10 { result = (d, nil) }
      else { result = (nil, "too large") }
      sem.signal()
    }.resume()
    sem.wait()
    return result
  }

  /// Fetch and verify the manifest; the result (good or not) is kept.
  @discardableResult
  func checkFeed() -> [String: Any] {
    let env = ProcessInfo.processInfo.environment
    let feed = env["OMACVM_FEED_URL"] ?? feedDefault
    var out: [String: Any] = ["checked_at": isoFormat.string(from: Date()), "ok": false]
    let old = lastResult()
    defer {
      try? FileManager.default.createDirectory(atPath: omacvmSupport, withIntermediateDirectories: true)
      try? jsonData(out).write(to: URL(fileURLWithPath: updatesPath), options: .atomic)
    }
    guard let key = releaseKey() else {
      out["error"] = "this OmacVM has no release key yet: updates come with omacvm update on the Mac"
      return out
    }
    guard let url = URL(string: feed), let sigURL = URL(string: feed + ".sig") else { out["error"] = "bad feed address"; return out }
    let (data, e1) = fetch(url)
    let (sig, e2) = data == nil ? (nil, e1) : fetch(sigURL)
    guard let data, let sig else {
      // Offline: the last good result stays, marked.
      out = old; out["offline"] = true; out["error"] = e1 ?? e2 ?? "no answer"
      out["tried_at"] = isoFormat.string(from: Date())
      return out
    }
    guard manifestSigned(data, sig: sig, key: key) else { out["error"] = "the update's signature does not match: not used"; return out }
    switch parseManifest(data) {
    case .failure(let e): out["error"] = e.message
    case .success(let m):
      out["ok"] = true
      out["raw"] = data.base64EncodedString(); out["sig"] = sig.base64EncodedString()
      log("control: update check: \(m.version) (\(m.parts.count) parts)")
    }
    return out
  }

  private func weeklyCheck() {
    guard updateChecks() else { return }
    let at = (lastResult()["checked_at"] as? String).flatMap { isoFormat.date(from: $0) } ?? .distantPast
    if Date().timeIntervalSince(at) > 7 * 86400 { checkFeed() }
  }

  private func updatesAnswer(_ version: String) -> [String: Any] {
    let r = lastResult()
    var a: [String: Any] = ["checks_enabled": updateChecks(), "omacvm": version,
                            "checked_at": r["checked_at"] ?? NSNull(), "ok": r["ok"] ?? false,
                            "offline": r["offline"] ?? false, "error": r["error"] ?? NSNull(), "manifest": NSNull()]
    if let m = verifiedManifest() {
      a["manifest"] = ["version": m.version, "date": m.date, "notes_url": m.notesURL, "proto": m.proto,
                       "proto_min": m.protoMin, "parts": m.parts]
    }
    return a
  }
}
let control = Control()
