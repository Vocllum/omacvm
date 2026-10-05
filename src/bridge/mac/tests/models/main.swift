// Offline tests of keys-model.swift (when the media-key tap is created again).
// No permissions.
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
  print("\(ok ? "ok  " : "FAIL") \(what)")
  if !ok { failed += 1; print("     (line \(line))") }
}

// ---- TapRearm ----
var r = TapRearm()
check(!r.front(nil), "tap: no OmacVM in front, nothing to do")
check(r.front(600), "tap: an OmacVM VM comes to the front: again")
check(!r.front(600) && !r.front(600), "tap: not again while it stays in front (checked every 2 s)")
check(r.front(700), "tap: straight to a second VM (another QEMU): again")
check(!r.front(nil) && r.front(700), "tap: the same VM after another app: again")
check(!r.front(nil) && r.front(800), "tap: OmacVM.app restarted (a new pid): again")
check(r.failed() && !r.failed() && !r.failed(), "tap: a failed re-creation is logged once")
r.worked()
check(r.failed(), "tap: ... and again after one worked")

if failed > 0 { print("\(failed) failed"); exit(1) }
print("models: all ok")
