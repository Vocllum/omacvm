// When the media-key tap is created again, without AppKit (keys.swift uses it;
// test.sh's offline tests check it). Same rule as the Gestures helper's tap.
import Foundation

/// A new event tap goes to the head of its chain, so a tap made by a VM app
/// started after the Bridge (each OmacVM VM is its own QEMU process) sits
/// ahead of ours. So the tap is created again whenever an OmacVM process comes
/// to the front that was not in front just before: a new VM, a restarted app,
/// or the same VM again after another app.
struct TapRearm {
  private var lastFront: pid_t = 0
  private var failureLogged = false

  /// `vmPid`: the front app's pid when it is an OmacVM process, else nil.
  /// True: create the tap again now.
  mutating func front(_ vmPid: pid_t?) -> Bool {
    defer { lastFront = vmPid ?? 0 }
    guard let vmPid else { return false }
    return vmPid != lastFront
  }

  /// A re-creation failed (Accessibility taken away): true the first time
  /// only, until one works again.
  mutating func failed() -> Bool {
    defer { failureLogged = true }
    return !failureLogged
  }

  mutating func worked() { failureLogged = false }
}
