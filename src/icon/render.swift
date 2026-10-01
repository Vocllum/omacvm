// Render an SVG (or any image macOS reads) to a square PNG.
// usage: swift render.swift <in.svg> <out.png> <size>
import AppKit

let a = CommandLine.arguments
guard a.count == 4, let img = NSImage(contentsOf: URL(fileURLWithPath: a[1])), let s = Int(a[3]) else {
    FileHandle.standardError.write("usage: render.swift <in.svg> <out.png> <size>\n".data(using: .utf8)!); exit(2)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: s, pixelsHigh: s, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
