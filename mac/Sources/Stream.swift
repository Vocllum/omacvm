import Compression
import CoreGraphics
import Foundation

/// Messages coming from the guest's `notchcast`.
enum GuestMessage {
    /// A rectangle of the bar image changed; the canvas is already updated.
    case frame
    /// A text reply, e.g. `targets [[x,y,w,h],...]`.
    case text(String)
}

/// Parses the byte stream from `notchcast` and keeps the bar image.
///
/// Wire format (little-endian):
///   frame: "NTCH" u32 magic, u32 seq, u16 full_w, u16 full_h, u16 x, u16 y,
///          u16 w, u16 h, u8 codec (0 raw, 1 LZ4 block), u8 wl_shm format,
///          u16 scale*100, u32 payload_len, then payload (BGRA rows, w*4 bytes)
///   text:  "NTXT" u32 magic, u32 len, then UTF-8 text
final class GuestStream {
    static let frameMagic: UInt32 = 0x4843_544E
    static let textMagic: UInt32 = 0x5458_544E
    static let frameHeaderSize = 28

    private var pending = Data()
    private(set) var width = 0
    private(set) var height = 0
    /// Output scale of the guest's hidden output (2.0 on a Retina VM).
    private(set) var scale: CGFloat = 2
    private var pixels: [UInt8] = []
    private(set) var hasImage = false

    func reset() {
        pending.removeAll(keepingCapacity: true)
    }

    /// Feeds received bytes; returns the complete messages they contained.
    /// Throws on a corrupt stream (the caller should drop the connection).
    func feed(_ data: Data) throws -> [GuestMessage] {
        pending.append(data)
        var out: [GuestMessage] = []
        while pending.count >= 8 {
            let magic = pending.readUInt32(at: 0)
            if magic == Self.textMagic {
                let len = Int(pending.readUInt32(at: 4))
                guard len < 1 << 20 else { throw StreamError.corrupt("text too long") }
                guard pending.count >= 8 + len else { break }
                let body = pending.subdata(in: pending.startIndex + 8 ..< pending.startIndex + 8 + len)
                out.append(.text(String(decoding: body, as: UTF8.self)))
                pending.removeFirst(8 + len)
            } else if magic == Self.frameMagic {
                guard pending.count >= Self.frameHeaderSize else { break }
                let fullW = Int(pending.readUInt16(at: 8)), fullH = Int(pending.readUInt16(at: 10))
                let x = Int(pending.readUInt16(at: 12)), y = Int(pending.readUInt16(at: 14))
                let w = Int(pending.readUInt16(at: 16)), h = Int(pending.readUInt16(at: 18))
                let codec = pending[pending.startIndex + 20]
                let scale100 = Int(pending.readUInt16(at: 22))
                let payloadLen = Int(pending.readUInt32(at: 24))
                guard payloadLen < 64 << 20, fullW > 0, fullH > 0, x + w <= fullW, y + h <= fullH else {
                    throw StreamError.corrupt("bad frame header")
                }
                guard pending.count >= Self.frameHeaderSize + payloadLen else { break }
                let start = pending.startIndex + Self.frameHeaderSize
                let payload = pending.subdata(in: start ..< start + payloadLen)
                pending.removeFirst(Self.frameHeaderSize + payloadLen)
                try apply(fullW: fullW, fullH: fullH, x: x, y: y, w: w, h: h, codec: codec,
                          scale100: scale100, payload: payload)
                out.append(.frame)
            } else {
                throw StreamError.corrupt(String(format: "bad magic %08x", magic))
            }
        }
        return out
    }

    private func apply(fullW: Int, fullH: Int, x: Int, y: Int, w: Int, h: Int, codec: UInt8,
                       scale100: Int, payload: Data) throws {
        if fullW != width || fullH != height {
            width = fullW
            height = fullH
            pixels = [UInt8](repeating: 0, count: fullW * fullH * 4)
            hasImage = false
        }
        if scale100 > 0 { scale = CGFloat(scale100) / 100 }
        let rawLen = w * h * 4
        var raw: [UInt8]
        switch codec {
        case 0:
            guard payload.count == rawLen else { throw StreamError.corrupt("raw size") }
            raw = [UInt8](payload)
        case 1:
            raw = [UInt8](repeating: 0, count: rawLen)
            let n = payload.withUnsafeBytes { src -> Int in
                raw.withUnsafeMutableBytes { dst in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, rawLen,
                                              src.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                                              nil, COMPRESSION_LZ4_RAW)
                }
            }
            guard n == rawLen else { throw StreamError.corrupt("lz4 decoded \(n) of \(rawLen)") }
        default:
            throw StreamError.corrupt("codec \(codec)")
        }
        let rowBytes = w * 4, stride = fullW * 4
        raw.withUnsafeBytes { src in
            pixels.withUnsafeMutableBytes { dst in
                for r in 0 ..< h {
                    memcpy(dst.baseAddress! + (y + r) * stride + x * 4, src.baseAddress! + r * rowBytes, rowBytes)
                }
            }
        }
        if x == 0, y == 0, w == fullW, h == fullH { hasImage = true }
    }

    /// The current bar image (BGRX, sRGB).
    func makeImage() -> CGImage? {
        guard hasImage, width > 0 else { return nil }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                           | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Colour of the bar background, sampled near the left edge.
    func backgroundColor() -> CGColor? {
        guard hasImage, width > 4, height > 4 else { return nil }
        let i = (2 * width + 2) * 4
        return CGColor(srgbRed: CGFloat(pixels[i + 2]) / 255, green: CGFloat(pixels[i + 1]) / 255,
                       blue: CGFloat(pixels[i]) / 255, alpha: 1)
    }
}

enum StreamError: Error, CustomStringConvertible {
    case corrupt(String)
    var description: String {
        switch self { case .corrupt(let s): return "corrupt stream: \(s)" }
    }
}

extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0 ..< 4 { v |= UInt32(self[startIndex + offset + i]) << (8 * UInt32(i)) }
        return v
    }

    func readUInt16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }
}
