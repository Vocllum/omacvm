// Offline tests of OmacVM.app's Storage.swift on fixture folders; run by
// src/tests/app-storage.sh. Arguments: WORK (an empty folder), DRIVE (a small
// mounted disk image: "another drive"), VOLUMES (a folder standing in for
// /Volumes, with DRIVE mounted at VOLUMES/Real), HFS (a small Mac OS Extended
// disk image: no sparse files).
import CryptoKit
import Foundation

setvbuf(stdout, nil, _IONBF, 0)   // each line at once, also when the test is killed
let args = CommandLine.arguments
let work = URL(fileURLWithPath: args[1]), drive = URL(fileURLWithPath: args[2]), volumes = URL(fileURLWithPath: args[3])
let hfs = URL(fileURLWithPath: args[4])
let fm = FileManager.default
var failed = 0

func expect(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) \(detail())"); failed += 1 }
}

func sha(_ url: URL) -> String {
    guard let h = FileHandle(forReadingAtPath: url.path) else { return "unreadable" }
    var hash = SHA256()
    while let d = try? h.read(upToCount: 1 << 20), !d.isEmpty { hash.update(data: d) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

func allocated(_ url: URL) -> Int64 {
    Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? -1)
}

/// A VM folder: vm.env, a sparse 2 GB disk.img with MB of data at a few places,
/// efi-vars.fd, logs/, a symbolic link and a private file.
func makeVM(_ root: URL, _ name: String, dataMB: Int = 3) throws -> URL {
    let d = root.appendingPathComponent(name)
    try fm.createDirectory(at: d.appendingPathComponent("logs"), withIntermediateDirectories: true)
    try "NAME='\(name)'\nCPUS=4\n".write(to: d.appendingPathComponent("vm.env"), atomically: true, encoding: .utf8)
    let disk = d.appendingPathComponent("disk.img")
    fm.createFile(atPath: disk.path, contents: nil)
    let h = try FileHandle(forWritingTo: disk)
    try h.truncate(atOffset: 2 << 30)
    let mb = [UInt8](repeating: 0, count: 1 << 20)
    for i in 0..<dataMB {
        var block = mb
        for j in stride(from: 0, to: block.count, by: 4096) { block[j] = UInt8(truncatingIfNeeded: i * 31 + j / 4096 + 1) }
        try h.seek(toOffset: UInt64(i) * (300 << 20))
        h.write(Data(block))
    }
    // A data block of zeros: read as data, written as a hole.
    try h.seek(toOffset: 1 << 30)
    h.write(Data(mb))
    try h.close()
    try Data(repeating: 7, count: 65536).write(to: d.appendingPathComponent("efi-vars.fd"))
    try "boot\n".write(to: d.appendingPathComponent("logs/qemu.log"), atomically: true, encoding: .utf8)
    try fm.createSymbolicLink(atPath: d.appendingPathComponent("latest.log").path, withDestinationPath: "logs/qemu.log")
    try "secret".write(to: d.appendingPathComponent("fast-network"), atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: d.appendingPathComponent("fast-network").path)
    return d
}

func fingerprint(_ d: URL) -> [String: String] {
    var out: [String: String] = [:]
    for case let rel as String in fm.enumerator(atPath: d.path)! {
        let u = d.appendingPathComponent(rel)
        let a = try! fm.attributesOfItem(atPath: u.path)
        let perm = String(format: "%o", (a[.posixPermissions] as? Int) ?? 0)
        switch a[.type] as? FileAttributeType {
        case .typeSymbolicLink?: out[rel] = "link " + ((try? fm.destinationOfSymbolicLink(atPath: u.path)) ?? "")
        case .typeDirectory?: out[rel] = "dir " + perm
        default: out[rel] = "file \(perm) \((a[.size] as? Int) ?? -1) \(sha(u))"
        }
    }
    return out
}

do {
    // Drives
    try fm.createDirectory(at: volumes.appendingPathComponent("Stale"), withIntermediateDirectories: true)
    expect("missing drive: a stale folder", Storage.missingDrive(for: volumes.appendingPathComponent("Stale/OmacVM"), volumes: volumes) == "Stale")
    expect("missing drive: no folder", Storage.missingDrive(for: volumes.appendingPathComponent("Gone/OmacVM"), volumes: volumes) == "Gone")
    expect("missing drive: mounted", Storage.missingDrive(for: volumes.appendingPathComponent("Real/OmacVM"), volumes: volumes) == nil)
    expect("missing drive: not under Volumes", Storage.missingDrive(for: work.appendingPathComponent("x"), volumes: volumes) == nil)
    expect("missing drive: the real /Volumes, home", Storage.missingDrive(for: fm.homeDirectoryForCurrentUser) == nil)
    expect("same volume: two folders here", Storage.sameVolume(work.appendingPathComponent("a/b"), work))
    expect("same volume: the disk image is another", !Storage.sameVolume(work, drive))
    expect("free space of a folder not made yet", (Storage.freeBytes(at: work.appendingPathComponent("no/such")) ?? 0) > 0)

    // Same drive: a rename
    let r1 = work.appendingPathComponent("root1"), r2 = work.appendingPathComponent("root2")
    let vm = try makeVM(r1, "Omarchy")
    let before = fingerprint(vm)
    let inode = (try fm.attributesOfItem(atPath: vm.appendingPathComponent("disk.img").path))[.systemFileNumber] as? Int
    let moved = try FolderMover().move(vm, into: r2)
    expect("same drive: new place", moved.path == r2.appendingPathComponent("Omarchy").path)
    expect("same drive: old place gone", !fm.fileExists(atPath: vm.path))
    expect("same drive: same files", fingerprint(moved) == before)
    let inode2 = (try fm.attributesOfItem(atPath: moved.appendingPathComponent("disk.img").path))[.systemFileNumber] as? Int
    expect("same drive: renamed, not copied", inode == inode2)

    // Target exists
    _ = try makeVM(r1, "Omarchy")
    do { _ = try FolderMover().move(r1.appendingPathComponent("Omarchy"), into: r2); expect("existing target refused", false) }
    catch { expect("existing target refused", "\(error.localizedDescription)".contains("already exists"), error.localizedDescription) }
    expect("existing target: source kept", fm.fileExists(atPath: r1.appendingPathComponent("Omarchy/disk.img").path))

    // Another drive: copy, check, delete; sparse kept (2 GB logical on a 64 MB drive)
    let ext = drive.appendingPathComponent("OmacVM")
    var phases = Set<String>(), last: Int64 = 0, total: Int64 = 0, monotonic = true
    let m = FolderMover()
    m.progress = { phase, done, all in
        if phases.insert(phase).inserted { last = 0 }
        if done < last { monotonic = false }
        last = done; total = all
    }
    let onExt = try m.move(moved, into: ext)
    expect("other drive: new place", onExt.path == ext.appendingPathComponent("Omarchy").path)
    expect("other drive: old place gone", !fm.fileExists(atPath: moved.path))
    expect("other drive: same files, modes and links", fingerprint(onExt) == before,
           "\(fingerprint(onExt).filter { before[$0.key] != $0.value })")
    let alloc = allocated(onExt.appendingPathComponent("disk.img"))
    expect("other drive: disk stays sparse", alloc > 0 && alloc < 16 << 20, "allocated \(alloc)")
    expect("other drive: copied and checked", phases == ["Copying", "Checking"], "\(phases)")
    expect("other drive: progress counts up to the data size", monotonic && last == total && total >= 4 << 20, "\(last)/\(total)")
    expect("other drive: no half copy left", !fm.fileExists(atPath: ext.appendingPathComponent(".Omarchy.moving").path))

    // Back from the other drive
    let back = try FolderMover().move(onExt, into: r2)
    expect("back again: same files", fingerprint(back) == before)

    // Too big for the drive: refused before copying, nothing changes
    let big = try makeVM(r1, "Big", dataMB: 90)
    let bigBefore = fingerprint(big)
    do { _ = try FolderMover().move(big, into: ext); expect("too big refused", false) }
    catch { expect("too big refused", error.localizedDescription.contains("free there"), error.localizedDescription) }
    expect("too big: source unchanged", fingerprint(big) == bigBefore)

    // Mac OS Extended: the 2 GB disk would take 2 GB there
    let small = try makeVM(work.appendingPathComponent("root4"), "Small", dataMB: 1)
    do { _ = try FolderMover().move(small, into: hfs.appendingPathComponent("VMs")); expect("no sparse files: full size counted", false) }
    catch { expect("no sparse files: full size counted", error.localizedDescription.contains("2.15 GB to copy"), error.localizedDescription) }
    expect("no sparse files: source kept", fm.fileExists(atPath: small.appendingPathComponent("disk.img").path))

    // Cancel during the copy: the source stays, no half copy
    let mid = try makeVM(work.appendingPathComponent("root3"), "Mid", dataMB: 24)
    let midBefore = fingerprint(mid)
    let c = FolderMover()
    c.progress = { _, done, _ in if done > 0 { c.cancel() } }
    do { _ = try c.move(mid, into: ext); expect("cancel stops the move", false) }
    catch { expect("cancel stops the move", error as? StorageError == .cancelled, "\(error)") }
    expect("cancel: source unchanged", fingerprint(mid) == midBefore)
    expect("cancel: no half copy", !fm.fileExists(atPath: ext.appendingPathComponent(".Mid.moving").path)
           && !fm.fileExists(atPath: ext.appendingPathComponent("Mid").path))

    // A drive that is not connected
    do { _ = try FolderMover().move(mid, into: URL(fileURLWithPath: "/Volumes/OmacVM-no-such-drive/VMs")); expect("missing drive refused", false) }
    catch { expect("missing drive refused", error.localizedDescription.contains("not connected"), error.localizedDescription) }

    // Busy folders and downloads in use
    let lines = ["/x/OmacVM -drive if=none,id=disk,file=\(r2.path)/Omarchy/disk.img,format=raw",
                 "/bin/bash /x/create-vm.sh \(work.path)/root3/Mid", "vim notes.txt"]
    let busy = Storage.busyFolders([back, mid, big], lines: lines).map(\.lastPathComponent)
    expect("busy: QEMU's disk and a build", busy == ["Omarchy", "Mid"], "\(busy)")
    let comma = work.appendingPathComponent("a,b")
    expect("busy: a comma doubled on QEMU's line",
           Storage.busyFolders([comma], lines: ["qemu file=\(work.path)/a,,b/disk.img,format=raw"]).count == 1)
    expect("busy: none", Storage.busyFolders([big], lines: ["other \(big.path)x"]).isEmpty)
    let caches = work.appendingPathComponent("Caches/omacvm")
    expect("downloads in use: curl into them", Storage.downloadsInUse(caches, lines: ["curl -o \(caches.path)/live/x.dmg"]))
    expect("downloads in use: omacvm build", Storage.downloadsInUse(caches, lines: ["/bin/bash /u/.omacvm/omacvm build --vm-type app"]))
    expect("downloads not in use", !Storage.downloadsInUse(caches, lines: ["zsh", "/Applications/Safari.app"]))
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", "exec -a 'OmacVM -drive file=\(back.path)/disk.img,format=raw' sleep 20"]
    try p.run()
    Thread.sleep(forTimeInterval: 0.5)
    expect("busy: a real process", Storage.busyFolders([back, big]).map(\.lastPathComponent) == ["Omarchy"])
    p.terminate()

    // Clear downloads
    try fm.createDirectory(at: caches.appendingPathComponent("live"), withIntermediateDirectories: true)
    try "x".write(to: caches.appendingPathComponent("live/a.dmg"), atomically: true, encoding: .utf8)
    try "x".write(to: caches.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
    try Storage.clear(caches)
    expect("clear: folder empty, folder kept", fm.fileExists(atPath: caches.path) && ((try? fm.contentsOfDirectory(atPath: caches.path)) ?? ["?"]).isEmpty)

    // Sizes and Time Machine
    expect("size of a VM counts what the disk holds", Storage.allocatedSize(of: back) < 64 << 20 && Storage.allocatedSize(of: back) > 3 << 20)
    Storage.excludeFromBackup(back)
    let tm = Process(), out = Pipe()
    tm.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
    tm.arguments = ["isexcluded", back.path]
    tm.standardOutput = out
    try tm.run(); tm.waitUntilExit()
    expect("Time Machine leaves it out", String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("[Excluded]"))

    // The app into ~/Applications
    let sys = work.appendingPathComponent("Applications"), home = work.appendingPathComponent("home/Applications")
    let app = sys.appendingPathComponent("OmacVM.app")
    try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try "x".write(to: app.appendingPathComponent("Contents/MacOS/OmacVM"), atomically: true, encoding: .utf8)
    let newApp = try AppMover.move(app, into: home)
    expect("app moved", newApp.path == home.appendingPathComponent("OmacVM.app").path && !fm.fileExists(atPath: app.path)
           && fm.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/OmacVM").path))
    try fm.createDirectory(at: app, withIntermediateDirectories: true)
    do { _ = try AppMover.move(app, into: home); expect("app: existing copy refused", false) }
    catch { expect("app: existing copy refused", fm.fileExists(atPath: app.path)) }
} catch {
    print("FAIL unexpected: \(error)")
    failed += 1
}
print(failed == 0 ? "all passed" : "\(failed) failed")
exit(failed == 0 ? 0 : 1)
