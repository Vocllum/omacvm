// Renders the "nerdy" Omarchy VM Dock icon (terminal-style squircle with the
// Omarchy mark drawn from its block-art source) and writes a PNG.
// usage: swift make-icon.swift <omarchy icon.txt> <out.png> [size]
// (icon.txt is /usr/share/omarchy/icon.txt from the VM, Omarchy's block-art mark)
import AppKit

let args = CommandLine.arguments
let mark = try! String(contentsOfFile: args[1], encoding: .utf8)
    .split(separator: "\n", omittingEmptySubsequences: false).map { Array($0) }
    .filter { !$0.isEmpty }
let S = CGFloat(Int(args.count > 3 ? args[3] : "1024")!)
let u = S / 1024

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func c(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255,
            blue: CGFloat(h & 255) / 255, alpha: a)
}

// macOS icon grid: 824pt body centred in 1024, continuous-corner radius ~185
let body = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
let shape = CGPath(roundedRect: body, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil)

// drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12 * u), blur: 28 * u, color: c(0x000000, 0.45))
ctx.addPath(shape); ctx.setFillColor(c(0x0d0e14)); ctx.fillPath()
ctx.restoreGState()

// body: deep tokyo-night gradient
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [c(0x1f2335), c(0x0b0c12)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

// faint grid
ctx.setStrokeColor(c(0x7aa2f7, 0.05)); ctx.setLineWidth(1.5 * u)
var gx = body.minX
while gx < body.maxX { ctx.move(to: CGPoint(x: gx, y: body.minY)); ctx.addLine(to: CGPoint(x: gx, y: body.maxY)); gx += 32 * u }
var gy = body.minY
while gy < body.maxY { ctx.move(to: CGPoint(x: body.minX, y: gy)); ctx.addLine(to: CGPoint(x: body.maxX, y: gy)); gy += 32 * u }
ctx.strokePath()

// terminal title bar
let barH = 92 * u
let bar = CGRect(x: body.minX, y: body.maxY - barH, width: body.width, height: barH)
ctx.setFillColor(c(0x16161e)); ctx.fill(bar)
ctx.setFillColor(c(0x7aa2f7, 0.25)); ctx.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width, height: 3 * u))
for (i, col) in [0xf7768e, 0xe0af68, 0x9ece6a].enumerated() {
    let r = 17 * u, cx = body.minX + 150 * u + CGFloat(i) * 56 * u, cy = bar.midY
    ctx.setFillColor(c(UInt32(col))); ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
}

// the Omarchy mark, block by block (1 char wide, 2 units tall = square-ish cells)
let cols = mark.map { $0.count }.max()!, rows = mark.count
let markW: CGFloat = 520 * u
let cw = markW / CGFloat(cols), ch = cw * 2
let markH = ch * CGFloat(rows)
let ox = body.midX - markW / 2, oy = body.minY + 210 * u + (560 * u - markH) / 2
let markRect = CGRect(x: ox, y: oy, width: markW, height: markH)
let blocks = CGMutablePath()
for (r, line) in mark.enumerated() {
    for (i, ch0) in line.enumerated() where ch0 == "█" {
        blocks.addRect(CGRect(x: ox + CGFloat(i) * cw, y: oy + markH - CGFloat(r + 1) * ch, width: cw + 0.5, height: ch + 0.5))
    }
}
// neon glow
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 46 * u, color: c(0x7dcfff, 0.75))
ctx.addPath(blocks); ctx.setFillColor(c(0x7dcfff)); ctx.fillPath()
ctx.restoreGState()
// gradient fill on top
ctx.saveGState()
ctx.addPath(blocks); ctx.clip()
let neon = CGGradient(colorsSpace: cs, colors: [c(0x9ece6a), c(0x7dcfff), c(0xbb9af7)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(neon, start: CGPoint(x: markRect.minX, y: markRect.maxY), end: CGPoint(x: markRect.maxX, y: markRect.minY), options: [])
ctx.restoreGState()

// prompt line
let font = NSFont(name: "Menlo-Bold", size: 64 * u) ?? NSFont.monospacedSystemFont(ofSize: 64 * u, weight: .bold)
func text(_ s: String, _ col: UInt32, _ x: CGFloat, _ y: CGFloat) -> CGFloat {
    let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: c(col))!])
    let line = CTLineCreateWithAttributedString(a)
    ctx.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, ctx)
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}
let py = body.minY + 92 * u
var px = body.minX + 96 * u
px += text("❯ ", 0xbb9af7, px, py)
px += text("omarchy", 0xc0caf5, px, py)
ctx.setFillColor(c(0x9ece6a)); ctx.fill(CGRect(x: px + 8 * u, y: py - 6 * u, width: 34 * u, height: 62 * u))

// CRT scanlines + top sheen
ctx.setFillColor(c(0x000000, 0.10))
var sy = body.minY
while sy < body.maxY - barH { ctx.fill(CGRect(x: body.minX, y: sy, width: body.width, height: 2 * u)); sy += 6 * u }
let sheen = CGGradient(colorsSpace: cs, colors: [c(0xffffff, 0.07), c(0xffffff, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
ctx.restoreGState()

// hairline border
ctx.addPath(shape); ctx.setStrokeColor(c(0xffffff, 0.10)); ctx.setLineWidth(3 * u); ctx.strokePath()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
