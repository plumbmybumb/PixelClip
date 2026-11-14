import Compression
import Foundation

/// Just enough ZIP (PKWARE APPNOTE) to open an EPUB: the central directory, stored and deflated
/// entries. No ZIP64, no encryption, no multi-disk archives.
public struct ZipArchive: Sendable {
    public enum ZipError: Error, Equatable { case notZip, truncated, unsupported(String), corrupt, tooLarge }

    public struct Entry: Sendable, Equatable {
        public var path: String
        public var method: UInt16
        public var compressedSize: Int
        public var size: Int
        public var localHeaderOffset: Int
    }

    public let data: Data
    public let entries: [Entry]
    private let index: [String: Int]

    /// Refuse entries that would inflate past this (a novel is a few MB of XHTML).
    public static let maxEntryBytes = 64 << 20

    public init(data: Data) throws {
        self.data = data
        let b = [UInt8](data)
        guard b.count >= 22 else { throw ZipError.notZip }
        // End of central directory: the last 0x06054b50 within 64 KB + 22 of the end.
        var eocd = -1
        var i = b.count - 22
        let floor = max(0, b.count - 22 - 0xFFFF)
        while i >= floor {
            if b[i] == 0x50, b[i + 1] == 0x4B, b[i + 2] == 0x05, b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        let count = u16(eocd + 10)
        let cdSize = u32(eocd + 12), cdOffset = u32(eocd + 16)
        guard cdOffset >= 0, cdOffset + cdSize <= b.count else { throw ZipError.truncated }
        if count == 0xFFFF || cdOffset == 0xFFFF_FFFF { throw ZipError.unsupported("zip64") }
        var out: [Entry] = []
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x0201_4B50 else { throw ZipError.corrupt }
            let method = UInt16(u16(p + 10))
            let csize = u32(p + 20), usize = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let local = u32(p + 42)
            guard p + 46 + nameLen <= b.count else { throw ZipError.truncated }
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            out.append(Entry(path: name, method: method, compressedSize: csize, size: usize, localHeaderOffset: local))
            p += 46 + nameLen + extraLen + commentLen
        }
        entries = out
        index = Dictionary(out.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func entry(_ path: String) -> Entry? {
        if let i = index[path] { return entries[i] }
        // EPUBs are sometimes sloppy about case.
        return entries.first { $0.path.caseInsensitiveCompare(path) == .orderedSame }
    }

    public func contains(_ path: String) -> Bool { entry(path) != nil }

    /// The uncompressed bytes of `path`.
    public func read(_ path: String) throws -> Data {
        guard let e = entry(path) else { throw ZipError.corrupt }
        return try read(e)
    }

    /// Raw DEFLATE (Apple's "zlib" algorithm, exactly a ZIP entry's payload) to exactly `size` bytes,
    /// in 64 KB pieces: the size the directory declares is a promise the stream is held to, so an entry
    /// that says 10 bytes and holds 300 MB stops at the 11th (`tooLarge`), and one that comes up short is
    /// `corrupt`.
    static func inflate(_ raw: Data, size: Int) throws -> Data {
        guard !raw.isEmpty else { throw ZipError.corrupt }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw ZipError.corrupt }
        defer { compression_stream_destroy(stream) }
        let chunk = 64 << 10
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var out = Data()
        out.reserveCapacity(min(size, 4 << 20))
        try raw.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { throw ZipError.corrupt }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = src.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                if produced > 0 {
                    guard out.count + produced <= size else { throw ZipError.tooLarge }
                    out.append(buffer, count: produced)
                }
                if status == COMPRESSION_STATUS_END { return }
                guard status == COMPRESSION_STATUS_OK, produced > 0 else { throw ZipError.corrupt }
            }
        }
        guard out.count == size else { throw ZipError.corrupt }
        return out
    }

    public func read(_ e: Entry) throws -> Data {
        guard e.size <= Self.maxEntryBytes else { throw ZipError.tooLarge }
        let o = data.startIndex + e.localHeaderOffset
        guard e.localHeaderOffset + 30 <= data.count else { throw ZipError.truncated }
        func u16(_ k: Int) -> Int { Int(data[o + k]) | Int(data[o + k + 1]) << 8 }
        guard data[o] == 0x50, data[o + 1] == 0x4B, data[o + 2] == 0x03, data[o + 3] == 0x04 else { throw ZipError.corrupt }
        let start = o + 30 + u16(26) + u16(28)
        guard start + e.compressedSize <= data.endIndex else { throw ZipError.truncated }
        let raw = data.subdata(in: start..<(start + e.compressedSize))
        switch e.method {
        case 0: return raw
        case 8:
            if e.size == 0 { return Data() }
            return try Self.inflate(raw, size: e.size)
        default:
            throw ZipError.unsupported("method \(e.method)")
        }
    }
}
