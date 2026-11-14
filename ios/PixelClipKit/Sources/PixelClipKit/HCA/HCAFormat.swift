import Foundation

/// Constants and plain data types for the `.hca` container (docs/PROTOCOL.md §2).
public enum HCA {
    public static let magic: [UInt8] = Array("HCA1".utf8)
    public static let headerSize = 32
    public static let frameEntrySize = 12
    /// Frame duration the device uses when a frame's `duration_ms` is 0.
    public static let defaultFrameDurationMs = 100

    public enum PixelFormat: UInt8, Sendable { case rgb565BE = 0 }
    public enum Compression: UInt8, Sendable { case raw = 0, rle16 = 1 }

    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let glyphAtlas = Flags(rawValue: 1 << 0)
        /// A single wide frame the device scrolls (PROTOCOL §2 `is_strip`, §4 `scroll`).
        public static let strip = Flags(rawValue: 1 << 1)
    }

    /// Maximum pixels in one RLE16 run (`(c & 0x7FFF) + 1`).
    public static let maxRun = 32_768

    /// Asset id grammar: `[a-z0-9][a-z0-9-]{0,31}`.
    public static func isValidAssetID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (1...32).contains(bytes.count) else { return false }
        for (i, b) in bytes.enumerated() {
            let alnum = (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39)
            if i == 0 { if !alnum { return false } } else if !(alnum || b == 0x2D) { return false }
        }
        return true
    }
}

/// The 32-byte header, field for field.
public struct HCAHeader: Equatable, Sendable {
    public var width: UInt16
    public var height: UInt16
    public var frameCount: UInt16
    public var pixelFormat: UInt8
    public var compression: UInt8
    public var loopCount: UInt16
    public var flags: UInt16
    public var frameTableOffset: UInt32
    public var dataSize: UInt32

    public init(width: UInt16, height: UInt16, frameCount: UInt16, pixelFormat: UInt8 = 0,
                compression: UInt8 = 1, loopCount: UInt16 = 0, flags: UInt16 = 0,
                frameTableOffset: UInt32 = 32, dataSize: UInt32 = 0) {
        self.width = width; self.height = height; self.frameCount = frameCount
        self.pixelFormat = pixelFormat; self.compression = compression
        self.loopCount = loopCount; self.flags = flags
        self.frameTableOffset = frameTableOffset; self.dataSize = dataSize
    }

    public var isGlyphAtlas: Bool { flags & HCA.Flags.glyphAtlas.rawValue != 0 }
    public var isStrip: Bool { flags & HCA.Flags.strip.rawValue != 0 }
    public var pixelCount: Int { Int(width) * Int(height) }
}

/// One 12-byte frame-table entry.
public struct HCAFrameInfo: Equatable, Sendable {
    public var offset: UInt32
    public var length: UInt32
    public var durationMs: UInt16
    public var flags: UInt16

    public init(offset: UInt32, length: UInt32, durationMs: UInt16, flags: UInt16 = 0) {
        self.offset = offset; self.length = length; self.durationMs = durationMs; self.flags = flags
    }

    /// Effective duration: the entry's value, or `defaultMs` when it is 0 (mirrors `hca_frame_duration`).
    public func effectiveDurationMs(default defaultMs: Int = HCA.defaultFrameDurationMs) -> Int {
        durationMs == 0 ? defaultMs : Int(durationMs)
    }
}

/// Mirrors `hca_status_t` so failures map 1:1 onto the C decoder's.
public enum HCAError: Error, Equatable, Sendable {
    case truncated
    case badMagic
    case unsupported
    case badFrame
    case corrupt
    case argument
}

/// A decoded frame: logical RGB565 values (native `UInt16`, not byte-swapped), row-major.
/// Big-endian conversion happens only at the file/wire boundary.
public struct RGB565Frame: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt16]

    public init(width: Int, height: Int, pixels: [UInt16]) {
        precondition(pixels.count == width * height, "pixel count mismatch")
        self.width = width; self.height = height; self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: UInt16 = 0) {
        self.init(width: width, height: height, pixels: [UInt16](repeating: fill, count: width * height))
    }

    /// Interpret a raw RGB565BE byte buffer (e.g. `GET /screenshot`).
    public init(bigEndianBytes data: Data, width: Int, height: Int) throws {
        let n = width * height
        guard data.count == n * 2 else { throw HCAError.truncated }
        var px = [UInt16](repeating: 0, count: n)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: UInt8.self)
            px.withUnsafeMutableBufferPointer { dst in
                for i in 0..<n { dst[i] = UInt16(src[2 * i]) << 8 | UInt16(src[2 * i + 1]) }
            }
        }
        self.init(width: width, height: height, pixels: px)
    }

    /// RGB565BE bytes, the panel's native order.
    public var bigEndianBytes: Data {
        var out = Data(count: pixels.count * 2)
        out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let dst = raw.bindMemory(to: UInt8.self)
            pixels.withUnsafeBufferPointer { src in
                for i in 0..<src.count {
                    dst[2 * i] = UInt8(src[i] >> 8)
                    dst[2 * i + 1] = UInt8(truncatingIfNeeded: src[i])
                }
            }
        }
        return out
    }
}

public extension RGB565Frame {
    static let clipWidth = 536
    static let clipHeight = 240
    /// Byte size of one raw full-screen frame (257,280).
    static let clipFrameBytes = clipWidth * clipHeight * 2

    static func pack(r: UInt8, g: UInt8, b: UInt8) -> UInt16 {
        UInt16(r >> 3) << 11 | UInt16(g >> 2) << 5 | UInt16(b >> 3)
    }
}
