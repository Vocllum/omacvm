import Foundation

// Offline tests for picking the guest the strip serves (GuestPicker.swift).
// Run: ./mac/test.sh

var failures = 0
func check<T: Equatable>(_ got: T, _ want: T, _ what: String, line: Int = #line) {
    if got != want {
        failures += 1
        print("FAIL line \(line): \(what): got \(got), want \(want)")
    }
}

let P = "Parallels Desktop", U = "UTM", F = "VMware Fusion"
func g(_ id: Int, _ owner: String?, _ name: String?) -> GuestCandidate { GuestCandidate(id: id, owner: owner, name: name) }
func pick(_ guests: [GuestCandidate], _ owner: String, _ title: String?, current: Int?) -> Int? {
    GuestPicker.pick(guests, front: FrontWindow(owner: owner, title: title), current: current)
}

// hello and vmname
check(GuestPicker.owner(hello: "parallels"), P, "hello parallels")
check(GuestPicker.owner(hello: "qemu"), U, "hello qemu")
check(GuestPicker.owner(hello: "vmware"), F, "hello vmware")
check(GuestPicker.owner(hello: "apple"), nil, "hello apple")
check(GuestPicker.owner(hello: "unknown"), nil, "hello unknown")
check(GuestPicker.owner(hello: "parallels more words"), P, "hello with more words")
check(GuestPicker.vmName(base64: "T21hcmNoeQ=="), "Omarchy", "vmname")
check(GuestPicker.vmName(base64: Data("OmacVM 2 Parallels".utf8).base64EncodedString()), "OmacVM 2 Parallels", "vmname with spaces")
check(GuestPicker.vmName(base64: Data("Büro – Omarchy".utf8).base64EncodedString()), "Büro – Omarchy", "vmname UTF-8")
check(GuestPicker.vmName(base64: ""), nil, "empty vmname")
check(GuestPicker.vmName(base64: "not base64!"), nil, "bad base64")
check(GuestPicker.vmName(base64: Data("a\nb".utf8).base64EncodedString()), nil, "vmname with a newline")
check(GuestPicker.vmName(base64: Data([0xff, 0xfe]).base64EncodedString()), nil, "vmname not UTF-8")
check(GuestPicker.vmName(base64: Data(String(repeating: "x", count: 256).utf8).base64EncodedString()), nil, "vmname too long")

// One guest: always it, whatever the title says (renamed VMs keep working).
check(pick([g(1, P, "Omarchy")], P, nil, current: nil), 1, "one guest, no title")
check(pick([g(1, P, "Omarchy")], P, "Work", current: nil), 1, "one guest, other title")
check(pick([g(1, nil, nil)], U, "UTM – Omarchy", current: nil), 1, "one old guest")

// Two VMs of one app: the title decides, both ways.
let two = [g(1, P, "OmacVM 2 Parallels"), g(2, P, "OmacVM 3 Parallels")]
check(pick(two, P, "OmacVM 3 Parallels", current: 1), 2, "title names the other VM")
check(pick(two, P, "OmacVM 2 Parallels", current: 2), 1, "and back")
check(pick(two, P, "OmacVM 2 Parallels", current: 1), 1, "stays")

// The name that is the title wins, else the longest one in it.
let utm = [g(1, U, "Omarchy"), g(2, U, "Omarchy 2")]
check(pick(utm, U, "UTM – Omarchy 2", current: 1), 2, "longest name in the title")
check(pick(utm, U, "UTM – Omarchy", current: 2), 1, "shorter name in the title")
check(pick(utm, U, "Omarchy", current: 2), 1, "exact title")
check(pick(utm, U, "Omarchy 2", current: 1), 2, "exact title, longer name")
check(pick(utm, U, "omarchy 2", current: 1), 1, "case matters: no match keeps the current one")

// Same name in two apps: the window's app decides.
let apps = [g(1, P, "Omarchy"), g(2, U, "Omarchy")]
check(pick(apps, U, "UTM – Omarchy", current: 1), 2, "UTM window")
check(pick(apps, P, "Omarchy", current: 2), 1, "Parallels window")
check(pick(apps, F, "Omarchy", current: 1), nil, "no guest runs in Fusion")
check(pick([g(1, P, "Omarchy")], U, "UTM – Omarchy", current: 1), nil, "a Parallels guest never serves a UTM window")

// No usable title (no Accessibility permission): first one wins, but a guest
// whose app is in front beats one whose app is not.
check(pick(two, P, nil, current: 2), 2, "no title keeps the current one")
check(pick(two, P, nil, current: nil), 1, "no title, nothing served yet: first connected")
check(pick([g(1, nil, nil), g(2, P, nil)], P, nil, current: 1), 2, "unknown app vs the front app")
check(pick([g(1, nil, nil), g(2, U, nil)], P, nil, current: 2), 1, "the front app's guest is the only fit")
check(pick([g(1, P, nil), g(2, P, nil)], P, "Omarchy", current: 2), 2, "two old guests: keep the current one")

// Names that match nothing: a guest that did not say its name may be the one.
check(pick([g(1, P, "Alpha"), g(2, P, nil)], P, "Beta", current: 1), 2, "unnamed old guest over a named mismatch")
check(pick([g(1, P, "Alpha"), g(2, P, "Beta")], P, "Gamma", current: 2), 2, "no match: keep the current one")
check(pick([g(1, P, "Alpha"), g(2, P, "Beta")], P, "Gamma", current: nil), 1, "no match, nothing served: first")
check(pick([g(1, P, ""), g(2, P, "Beta")], P, "Beta", current: 1), 2, "empty name never matches")
check(pick([g(1, P, "Beta"), g(2, nil, "Beta")], P, "Beta", current: nil), 1, "equal names: the front app's guest")

// ParkState: only the served guest is parked; switching unparks the old one first.
var st = ParkState()
var parkedGuests = Set<Int>()
func apply(_ commands: [(guest: Int, line: String)]) {
    for c in commands {
        if c.line == "park 1" { parkedGuests.insert(c.guest) }
        if c.line == "park 0" { parkedGuests.remove(c.guest) }
    }
}
apply(st.activate(1)); apply(st.setParked(true))
check(parkedGuests, [1], "guest 1 parked")
check(st.setParked(true).count, 0, "parking again sends nothing (the heartbeat does)")
let sw = st.activate(2)
check(sw.map { "\($0.guest) \($0.line)" }, ["1 park 0", "1 cursor 1"], "switch: old guest unparked, cursor back")
apply(sw)
check(parkedGuests, [], "nobody parked between")
apply(st.setParked(true))
check(parkedGuests, [2], "guest 2 parked")
check(st.activate(2).count, 0, "same guest: nothing")
st.reset(2, gone: false)  // new session of guest 2 (it starts unparked)
check(st.parked, false, "new session unparked")
check(st.setParked(true).map { "\($0.guest) \($0.line)" }, ["2 park 1"], "re-parked")
st.reset(2, gone: true)
check(st.active, nil, "gone")
check(st.setParked(true).count, 0, "nobody to park")
var st2 = ParkState()
apply(st2.activate(1))
check(st2.activate(2).count, 0, "switching away from an unparked guest sends nothing")

// The whole loop with fake windows: at most one bar parked, always the front VM's.
var s3 = ParkState()
parkedGuests = []
let guests = [g(1, P, "OmacVM 2 Parallels"), g(2, P, "OmacVM 3 Parallels"), g(3, U, "Omarchy"), g(4, P, nil)]
let windows: [(String, String?, Int?)] = [
    (P, "OmacVM 2 Parallels", 1), (P, "OmacVM 3 Parallels", 2), (U, "UTM – Omarchy", 3),
    (P, "OmacVM 2 Parallels", 1), (F, "Windows 11", nil), (P, "Omarchy ARM", 4), (P, nil, 4),
]
for (owner, title, want) in windows {
    let p = GuestPicker.pick(guests, front: FrontWindow(owner: owner, title: title), current: s3.active)
    check(p, want, "front \(owner) \"\(title ?? "-")\"")
    if let p {
        apply(s3.activate(p))
        apply(s3.setParked(true))
    }
    check(parkedGuests.count <= 1, true, "at most one bar parked")
    if let want { check(parkedGuests, [want], "the front VM's bar is parked") }
}

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
