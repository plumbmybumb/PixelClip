import CoreGraphics
import CoreText
import Foundation

/// A text stamp or sticker placed on a frame. Rendered into the frame by `FrameCompositor`, so
/// the canvas, the preview and the export all draw it the same way.
public struct CanvasOverlay: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: Codable, Sendable, Hashable {
        case text(String, FontSelection)
        /// An SF Symbol name (rendered by the app; SF Symbols may only be used in Apple-platform apps).
        case sticker(String)
    }

    public var id: UUID
    public var kind: Kind
    /// Canvas pixels, y-down.
    public var center: CGPoint
    /// Text: font size in px. Sticker: height in px.
    public var size: Double
    public var color: RGBAColor

    public init(id: UUID = UUID(), kind: Kind, center: CGPoint, size: Double, color: RGBAColor) {
        self.id = id; self.kind = kind; self.center = center; self.size = size; self.color = color
    }
}

/// One frame of a drawing.
public struct DrawingFrame: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// `PKDrawing.dataRepresentation()` (opaque to PixelClipKit).
    public var ink: Data
    /// Fill-bucket / pixel-pen / filled-shape paint under the ink.
    public var pixels: PixelLayer?
    public var overlays: [CanvasOverlay]
    /// How many frame-times this frame stays up (per-frame duration = hold / fps).
    public var hold: Int

    public init(id: UUID = UUID(), ink: Data = Data(), pixels: PixelLayer? = nil, overlays: [CanvasOverlay] = [], hold: Int = 1) {
        self.id = id; self.ink = ink; self.pixels = pixels; self.overlays = overlays; self.hold = hold
    }

    /// A copy with a new identity (Duplicate).
    public func duplicated() -> DrawingFrame {
        DrawingFrame(ink: ink, pixels: pixels, overlays: overlays.map { var o = $0; o.id = UUID(); return o }, hold: hold)
    }

    public static func == (a: DrawingFrame, b: DrawingFrame) -> Bool {
        a.id == b.id && a.ink == b.ink && a.pixels == b.pixels && a.overlays == b.overlays && a.hold == b.hold
    }

    public func hash(into h: inout Hasher) { h.combine(id); h.combine(ink); h.combine(overlays); h.combine(hold) }
}

/// A drawing or animation in progress (a draft). Persisted by `DraftStore`.
public struct DrawingDocument: Codable, Sendable, Hashable, Identifiable {
    public static let fpsRange = 6...24
    public static let maxFrames = 120

    public var id: String
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var background: RGBAColor
    public var fps: Int
    public var frames: [DrawingFrame]
    public var dither: Bool
    public var onionSkin: Bool
    /// The library item last saved from this draft (re-saving replaces it).
    public var libraryItemID: String?

    public init(id: String = UUID().uuidString.lowercased(), name: String = "Drawing", background: RGBAColor = .black,
                fps: Int = 12, frames: [DrawingFrame] = [DrawingFrame()], dither: Bool = false, onionSkin: Bool = true,
                now: Date = Date()) {
        self.id = id; self.name = name; self.createdAt = now; self.updatedAt = now; self.background = background
        self.fps = fps; self.frames = frames.isEmpty ? [DrawingFrame()] : frames; self.dither = dither
        self.onionSkin = onionSkin; self.libraryItemID = nil
    }

    public var frameMs: Int { Int((1000 / Double(min(max(fps, Self.fpsRange.lowerBound), Self.fpsRange.upperBound))).rounded()) }
    public func durationMs(_ index: Int) -> Int { frameMs * max(1, frames[index].hold) }
    public var durationsMs: [Int] { frames.indices.map(durationMs) }
    public var loopMs: Int { frames.count > 1 ? durationsMs.reduce(0, +) : 0 }
    public var isAnimated: Bool { frames.count > 1 }
}

public struct DraftSummary: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let updatedAt: Date
    public let frameCount: Int
    public let thumbnailURL: URL?
}

/// Drafts on disk: `<root>/<id>.zdraw` (JSON) plus `<id>.png` (thumbnail).
public struct DraftStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Application Support/Create/Drafts.
    public static func standard() -> DraftStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DraftStore(root: base.appendingPathComponent("Create/Drafts", isDirectory: true))
    }

    func docURL(_ id: String) -> URL { root.appendingPathComponent("\(id).zdraw") }
    public func thumbnailURL(_ id: String) -> URL { root.appendingPathComponent("\(id).png") }

    public func save(_ doc: DrawingDocument, thumbnail: Data? = nil) throws {
        let data = try JSONEncoder().encode(doc)
        try data.write(to: docURL(doc.id), options: .atomic)
        if let thumbnail { try? thumbnail.write(to: thumbnailURL(doc.id), options: .atomic) }
    }

    public func load(_ id: String) throws -> DrawingDocument {
        try JSONDecoder().decode(DrawingDocument.self, from: Data(contentsOf: docURL(id)))
    }

    public func delete(_ id: String) {
        try? FileManager.default.removeItem(at: docURL(id))
        try? FileManager.default.removeItem(at: thumbnailURL(id))
    }

    /// Newest first. Unreadable files are skipped.
    public func list() -> [DraftSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        struct Head: Decodable { var id: String; var name: String; var updatedAt: Date; var frames: [Skip] }
        struct Skip: Decodable { init(from decoder: any Decoder) throws {} }
        return files.filter { $0.pathExtension == "zdraw" }.compactMap { url -> DraftSummary? in
            guard let data = try? Data(contentsOf: url), let h = try? JSONDecoder().decode(Head.self, from: data) else { return nil }
            let thumb = thumbnailURL(h.id)
            return DraftSummary(id: h.id, name: h.name, updatedAt: h.updatedAt, frameCount: h.frames.count,
                                thumbnailURL: FileManager.default.fileExists(atPath: thumb.path) ? thumb : nil)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
}
