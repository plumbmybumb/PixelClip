import Foundation

/// A parsed `.hca` file. Validation mirrors `hca_open` in core/include/hca.h:
/// magic, pixel format, compression, `frame_count >= 1`, `frame_table_off == 32`,
/// `data_size == file size`, and every frame's byte range inside the file.
public struct HCAFile: Sendable {
    public let data: Data
    public let header: HCAHeader
    public let frames: [HCAFrameInfo]

    public init(data: Data) throws {
        // Re-base so indices start at 0 regardless of the caller's slice.
        let data = Data(data)
        guard data.count >= HCA.headerSize else { throw HCAError.truncated }
        let h: HCAHeader = data.withUnsafeBytes { raw in
            HCAHeader(width: raw.le16(4), height: raw.le16(6), frameCount: raw.le16(8),
                      pixelFormat: raw[10], compression: raw[11], loopCount: raw.le16(12),
                      flags: raw.le16(14), frameTableOffset: raw.le32(16), dataSize: raw.le32(20))
        }
        guard data.prefix(4).elementsEqual(HCA.magic) else { throw HCAError.badMagic }
        guard h.pixelFormat == HCA.PixelFormat.rgb565BE.rawValue,
              HCA.Compression(rawValue: h.compression) != nil else { throw HCAError.unsupported }
        guard h.frameTableOffset == UInt32(HCA.headerSize) else { throw HCAError.unsupported }
        guard h.frameCount >= 1, h.width >= 1, h.height >= 1 else { throw HCAError.badFrame }
        let tableEnd = HCA.headerSize + Int(h.frameCount) * HCA.frameEntrySize
        guard data.count >= tableEnd else { throw HCAError.truncated }
        guard Int(h.dataSize) == data.count else { throw HCAError.truncated }

        var infos: [HCAFrameInfo] = []
        infos.reserveCapacity(Int(h.frameCount))
        try data.withUnsafeBytes { raw in
            for i in 0..<Int(h.frameCount) {
                let o = HCA.headerSize + i * HCA.frameEntrySize
                let fi = HCAFrameInfo(offset: raw.le32(o), length: raw.le32(o + 4),
                                      durationMs: raw.le16(o + 8), flags: raw.le16(o + 10))
                guard Int(fi.offset) >= tableEnd,
                      Int(fi.offset) + Int(fi.length) <= data.count else { throw HCAError.badFrame }
                if h.compression == HCA.Compression.raw.rawValue, Int(fi.length) != h.pixelCount * 2 {
                    throw HCAError.badFrame
                }
                infos.append(fi)
            }
        }
        self.data = data
        self.header = h
        self.frames = infos
    }

    public var width: Int { Int(header.width) }
    public var height: Int { Int(header.height) }
    public var frameCount: Int { Int(header.frameCount) }
    public var isGlyphAtlas: Bool { header.isGlyphAtlas }
    public var isStrip: Bool { header.isStrip }

    /// Total loop duration with 0-duration frames counted as `defaultMs`.
    public func totalDurationMs(default defaultMs: Int = HCA.defaultFrameDurationMs) -> Int {
        frames.reduce(0) { $0 + $1.effectiveDurationMs(default: defaultMs) }
    }

    /// Decode frame `index` into logical RGB565 pixels.
    public func decodeFrame(_ index: Int) throws -> RGB565Frame {
        var out = [UInt16](repeating: 0, count: header.pixelCount)
        try decodeFrame(index, into: &out)
        return RGB565Frame(width: width, height: height, pixels: out)
    }

    /// Decode into a caller-owned buffer of exactly `width*height` pixels (no allocation).
    public func decodeFrame(_ index: Int, into out: inout [UInt16]) throws {
        guard frames.indices.contains(index) else { throw HCAError.badFrame }
        guard out.count == header.pixelCount else { throw HCAError.argument }
        let fi = frames[index]
        try data.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self)
            let src = UnsafeBufferPointer(rebasing: base[Int(fi.offset)..<Int(fi.offset + fi.length)])
            try out.withUnsafeMutableBufferPointer { dst in
                switch HCA.Compression(rawValue: header.compression) {
                case .raw: try HCADecoder.decodeRaw(src, into: dst)
                case .rle16: try HCADecoder.decodeRLE16(src, into: dst)
                case nil: throw HCAError.unsupported
                }
            }
        }
    }

    public func decodeAllFrames() throws -> [RGB565Frame] {
        try (0..<frameCount).map { try decodeFrame($0) }
    }
}

public enum HCADecoder {
    public static func decodeRaw(_ src: UnsafeBufferPointer<UInt8>, into dst: UnsafeMutableBufferPointer<UInt16>) throws {
        guard src.count == dst.count * 2 else { throw HCAError.corrupt }
        for i in 0..<dst.count { dst[i] = UInt16(src[2 * i]) << 8 | UInt16(src[2 * i + 1]) }
    }

    /// RLE16 decode. Rejects overrun (a run that would exceed the frame), underrun (stream ends early)
    /// and trailing bytes after the last pixel.
    public static func decodeRLE16(_ src: UnsafeBufferPointer<UInt8>, into dst: UnsafeMutableBufferPointer<UInt16>) throws {
        let n = dst.count
        var p = 0, o = 0
        let len = src.count
        while o < n {
            guard p + 2 <= len else { throw HCAError.corrupt }
            let c = UInt16(src[p]) | UInt16(src[p + 1]) << 8
            p += 2
            let run = Int(c & 0x7FFF) + 1
            guard o + run <= n else { throw HCAError.corrupt }
            if c & 0x8000 != 0 {
                guard p + 2 <= len else { throw HCAError.corrupt }
                let v = UInt16(src[p]) << 8 | UInt16(src[p + 1])
                p += 2
                for k in o..<(o + run) { dst[k] = v }
            } else {
                guard p + run * 2 <= len else { throw HCAError.corrupt }
                for k in 0..<run { dst[o + k] = UInt16(src[p + 2 * k]) << 8 | UInt16(src[p + 2 * k + 1]) }
                p += run * 2
            }
            o += run
        }
        guard p == len else { throw HCAError.corrupt }
    }

    /// Decode RLE16 bytes for a frame of `pixelCount` pixels.
    public static func decodeRLE16(_ data: Data, pixelCount: Int) throws -> [UInt16] {
        var out = [UInt16](repeating: 0, count: pixelCount)
        try data.withUnsafeBytes { raw in
            try out.withUnsafeMutableBufferPointer { dst in
                try decodeRLE16(raw.bindMemory(to: UInt8.self), into: dst)
            }
        }
        return out
    }
}

extension UnsafeRawBufferPointer {
    @inline(__always) func le16(_ o: Int) -> UInt16 { UInt16(self[o]) | UInt16(self[o + 1]) << 8 }
    @inline(__always) func le32(_ o: Int) -> UInt32 {
        UInt32(self[o]) | UInt32(self[o + 1]) << 8 | UInt32(self[o + 2]) << 16 | UInt32(self[o + 3]) << 24
    }
}
