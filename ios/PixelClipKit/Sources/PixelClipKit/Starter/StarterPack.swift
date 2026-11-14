import Foundation

/// The PixelClip pack: the approved loops bundled with the app (`PixelClip.app/Starter/`, with their
/// manifests). All original or procedural work.
public struct StarterPiece: Codable, Sendable, Hashable, Identifiable {
    public var slug: String
    public var title: String
    public var description: String
    /// File name inside the Starter folder.
    public var file: String
    public var bytes: Int
    public var id: String { slug }

    public init(slug: String, title: String, description: String, file: String, bytes: Int) {
        self.slug = slug; self.title = title; self.description = description; self.file = file; self.bytes = bytes
    }

    /// The library item / clip asset id for this piece.
    public var assetID: String { "zp-\(slug)" }
}

public enum StarterPack {
    private struct Manifest: Codable { var version: Int; var pieces: [StarterPiece] }

    /// `starter.json`: `{"version":1,"pieces":[{"slug","title","description","file","bytes"}]}`.
    public static func pieces(manifest: Data) throws -> [StarterPiece] {
        try JSONDecoder().decode(Manifest.self, from: manifest).pieces
    }

    /// What the library needs to store a piece as a normal item.
    public struct Info: Sendable, Equatable {
        public var frameCount: Int
        /// One loop in ms (0 for a still).
        public var durationMs: Int
        public var isStrip: Bool
        public var width: Int
    }

    /// Reads a piece's .hca header (validates it the way the clip will).
    public static func info(_ data: Data) throws -> Info {
        let f = try HCAFile(data: data)
        let ms = f.frameCount > 1 ? f.frames.reduce(0) { $0 + $1.effectiveDurationMs() } : 0
        return Info(frameCount: f.frameCount, durationMs: ms, isStrip: f.isStrip, width: f.width)
    }
}
