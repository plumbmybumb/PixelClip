import Foundation

/// Writes `.hca` files exactly as docs/PROTOCOL.md §2 describes.
///
/// Layout produced (deterministic): 32-byte header, frame table, then frame data in frame order with
/// no padding. `data_size` equals the file length; `frame_table_off` is 32; reserved bytes are zero.
public enum HCAEncoder {

    public struct Frame: Sendable {
        public var pixels: RGB565Frame
        /// 0 means "use playlist/default (100 ms)".
        public var durationMs: Int
        public init(pixels: RGB565Frame, durationMs: Int) {
            self.pixels = pixels; self.durationMs = durationMs
        }
    }

    public enum Error: Swift.Error, Equatable {
        case noFrames
        case tooManyFrames
        case inconsistentGeometry
        case badGeometry
    }

    /// Encode frames into a complete `.hca` file.
    public static func encode(frames: [Frame], loopCount: Int = 0, glyphAtlas: Bool = false, strip: Bool = false,
                              compression: HCA.Compression = .rle16) throws -> Data {
        guard let first = frames.first else { throw Error.noFrames }
        guard frames.count <= Int(UInt16.max) else { throw Error.tooManyFrames }
        let w = first.pixels.width, h = first.pixels.height
        guard w > 0, h > 0, w <= Int(UInt16.max), h <= Int(UInt16.max) else { throw Error.badGeometry }
        for f in frames where f.pixels.width != w || f.pixels.height != h {
            throw Error.inconsistentGeometry
        }

        // Compress every frame first so the table can be written in one pass.
        var scratch = RLE16Scratch()
        var payloads: [Data] = []
        payloads.reserveCapacity(frames.count)
        for f in frames {
            switch compression {
            case .rle16: payloads.append(scratch.encode(f.pixels.pixels))
            case .raw: payloads.append(f.pixels.bigEndianBytes)
            }
        }

        let tableBytes = HCA.headerSize + frames.count * HCA.frameEntrySize
        let total = tableBytes + payloads.reduce(0) { $0 + $1.count }
        precondition(total <= Int(UInt32.max))

        var out = Data(capacity: total)
        // Header
        out.append(contentsOf: HCA.magic)
        out.appendLE(UInt16(w))
        out.appendLE(UInt16(h))
        out.appendLE(UInt16(frames.count))
        out.append(HCA.PixelFormat.rgb565BE.rawValue)
        out.append(compression.rawValue)
        out.appendLE(UInt16(clamping: max(0, loopCount)))
        var flags: HCA.Flags = []
        if glyphAtlas { flags.insert(.glyphAtlas) }
        if strip { flags.insert(.strip) }
        out.appendLE(flags.rawValue)
        out.appendLE(UInt32(HCA.headerSize))
        out.appendLE(UInt32(total))
        out.append(contentsOf: [UInt8](repeating: 0, count: 8))
        // Frame table
        var offset = tableBytes
        for (f, p) in zip(frames, payloads) {
            out.appendLE(UInt32(offset))
            out.appendLE(UInt32(p.count))
            out.appendLE(UInt16(clamping: max(0, f.durationMs)))
            out.appendLE(UInt16(0))
            offset += p.count
        }
        for p in payloads { out.append(p) }
        assert(out.count == total)
        return out
    }

    /// A scrolling strip: one frame, `height` 240, `width` 537…8192 (PROTOCOL §2 `is_strip`; the
    /// firmware's `STORAGE_STRIP_MIN_W`/`MAX_W`).
    public static func encodeStrip(_ strip: RGB565Frame) throws -> Data {
        guard strip.height == ClipCanvas.height, PlaylistItem.Scroll.stripWidths.contains(strip.width) else {
            throw Error.badGeometry
        }
        return try encode(frames: [Frame(pixels: strip, durationMs: 0)], strip: true)
    }

    /// RLE16-encode one frame of logical RGB565 pixels (convenience; allocates a scratch buffer).
    public static func rle16(_ pixels: [UInt16]) -> Data {
        var s = RLE16Scratch()
        return s.encode(pixels)
    }
}

/// Reusable output buffer for RLE16 encoding (avoids reallocating per frame).
///
/// Algorithm (the exact rule, so other encoders can match byte-for-byte):
/// scan left to right; at position `i` measure the run of pixels equal to `p[i]`, capped at 32768.
/// If the run is ≥ 3, flush any pending literal pixels (in chunks of ≤ 32768, each preceded by
/// control `len-1`), then emit control `0x8000 | (run-1)` followed by the pixel. Otherwise the run's
/// 1–2 pixels join the pending literal. At the end, flush the pending literal. Pixels are written
/// big-endian, control words little-endian.
public struct RLE16Scratch: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    /// Worst case: 2 bytes per pixel plus at most one control word per pixel pair boundary.
    /// We size generously (n*4 + 16) so the hot loop never bounds-checks.
    public mutating func encode(_ pixels: [UInt16]) -> Data {
        let n = pixels.count
        let cap = n * 4 + 16
        if buffer.count < cap { buffer = [UInt8](repeating: 0, count: cap) }
        let written: Int = pixels.withUnsafeBufferPointer { src in
            buffer.withUnsafeMutableBufferPointer { dst in
                RLE16Scratch.encode(src, into: dst)
            }
        }
        return Data(buffer[0..<written])
    }

    @inline(__always)
    private static func encode(_ src: UnsafeBufferPointer<UInt16>, into dst: UnsafeMutableBufferPointer<UInt8>) -> Int {
        let n = src.count
        var o = 0
        var litStart = 0
        var i = 0

        @inline(__always) func put16LE(_ v: UInt16) {
            dst[o] = UInt8(truncatingIfNeeded: v); dst[o + 1] = UInt8(v >> 8); o += 2
        }
        @inline(__always) func putPixel(_ v: UInt16) {
            dst[o] = UInt8(v >> 8); dst[o + 1] = UInt8(truncatingIfNeeded: v); o += 2
        }
        @inline(__always) func flushLiteral(_ start: Int, _ end: Int) {
            var s = start
            while s < end {
                let len = min(end - s, HCA.maxRun)
                put16LE(UInt16(len - 1))
                for k in s..<(s + len) { putPixel(src[k]) }
                s += len
            }
        }

        while i < n {
            let v = src[i]
            var j = i + 1
            let limit = min(n, i + HCA.maxRun)
            while j < limit && src[j] == v { j += 1 }
            let run = j - i
            if run >= 3 {
                flushLiteral(litStart, i)
                put16LE(0x8000 | UInt16(run - 1))
                putPixel(v)
                i = j
                litStart = i
            } else {
                i = j
            }
        }
        flushLiteral(litStart, n)
        return o
    }
}

extension Data {
    @inline(__always) mutating func appendLE(_ v: UInt16) {
        append(UInt8(truncatingIfNeeded: v)); append(UInt8(v >> 8))
    }
    @inline(__always) mutating func appendLE(_ v: UInt32) {
        append(UInt8(truncatingIfNeeded: v)); append(UInt8(truncatingIfNeeded: v >> 8))
        append(UInt8(truncatingIfNeeded: v >> 16)); append(UInt8(truncatingIfNeeded: v >> 24))
    }
}
