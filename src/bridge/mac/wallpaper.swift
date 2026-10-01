// POST /wallpaper: the VM's current Omarchy background becomes the Mac's
// wallpaper on every display, which macOS also shows behind its lock screen.
// The guest sends it whenever the theme or background changes.
import AppKit
import CryptoKit

let wallpaperDir = supportDir + "/wallpaper"

func setWallpaper(_ data: Data, theme: String) throws -> String {
  guard !data.isEmpty, NSImage(data: data) != nil else { throw APIError(400, "the body must be an image (PNG or JPEG)") }
  let hash = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
  let ext = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "jpg"
  let file = "\(wallpaperDir)/background-\(hash).\(ext)"
  let fm = FileManager.default
  try fm.createDirectory(atPath: wallpaperDir, withIntermediateDirectories: true)
  if !fm.fileExists(atPath: file) {
    try data.write(to: URL(fileURLWithPath: file), options: .atomic)
  }
  // Keep only the current picture (macOS reads it again after a restart).
  for f in (try? fm.contentsOfDirectory(atPath: wallpaperDir)) ?? [] where f.hasPrefix("background-") && "\(wallpaperDir)/\(f)" != file {
    try? fm.removeItem(atPath: "\(wallpaperDir)/\(f)")
  }
  var failures: [String] = []
  DispatchQueue.main.sync {
    let opts: [NSWorkspace.DesktopImageOptionKey: Any] = [
      .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true]
    for screen in NSScreen.screens {
      do { try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: file), for: screen, options: opts) }
      catch { failures.append("\(screen.localizedName): \(error.localizedDescription)") }
    }
  }
  guard failures.isEmpty else { throw APIError(500, "setting the wallpaper failed: " + failures.joined(separator: "; ")) }
  return "wallpaper \(theme.isEmpty ? "" : theme + " ")(\(data.count / 1024) KB)"
}
