import CoreGraphics
import Foundation
import PixelClipKit

/// Frames ready to show on screen (already quantised through the clip pipeline).
/// CGImage is immutable and thread-safe.
struct ClipFrames: @unchecked Sendable, Equatable {
    var images: [CGImage]
    /// Seconds per frame.
    var durations: [Double]
    /// A scrolling strip: the whole (quantised) strip and how the clip scrolls it. `images` then holds
    /// its first screen (what shows when it doesn't scroll, and the glow/thumbnail).
    var strip: Strip?

    struct Strip: @unchecked Sendable, Equatable {
        var image: CGImage
        var scroll: PlaylistItem.Scroll?
        var width: Int { image.width }
    }

    init(images: [CGImage], durations: [Double]) {
        self.images = images
        self.durations = durations.count == images.count ? durations : Array(repeating: 0.1, count: images.count)
    }

    init(strip: CGImage, firstScreen: CGImage, scroll: PlaylistItem.Scroll?) {
        self.init(images: [firstScreen], durations: [0])
        self.strip = Strip(image: strip, scroll: scroll)
    }

    /// The same frames with the item's scroll block (the file itself doesn't carry it).
    func withScroll(_ scroll: PlaylistItem.Scroll?) -> ClipFrames {
        guard let strip else { return self }
        var copy = self
        copy.strip = Strip(image: strip.image, scroll: scroll)
        return copy
    }

    init?(single image: CGImage?) {
        guard let image else { return nil }
        self.init(images: [image], durations: [0])
    }

    var isAnimated: Bool { images.count > 1 }
    var totalDuration: Double { durations.reduce(0, +) }

    func index(at t: TimeInterval) -> Int {
        guard images.count > 1, totalDuration > 0 else { return 0 }
        var r = t.truncatingRemainder(dividingBy: totalDuration)
        for (i, d) in durations.enumerated() {
            if r < d { return i }
            r -= d
        }
        return images.count - 1
    }

    /// Decode a `.hca` into displayable frames (exactly what the clip will show).
    static func decode(_ data: Data, scroll: PlaylistItem.Scroll? = nil) throws -> ClipFrames {
        let file = try HCAFile(data: data)
        if file.isStrip {
            let strip = try file.decodeFrame(0)
            guard let full = ClipRenderer.makeCGImage(strip),
                  let first = ClipRenderer.makeCGImage(StripScroller.firstScreen(strip)) else { throw HCAError.badFrame }
            return ClipFrames(strip: full, firstScreen: first, scroll: scroll)
        }
        var buffer = [UInt16](repeating: 0, count: file.width * file.height)
        var images: [CGImage] = []
        for i in 0..<file.frameCount {
            try file.decodeFrame(i, into: &buffer)
            if let img = ClipRenderer.makeCGImage(RGB565Frame(width: file.width, height: file.height, pixels: buffer)) {
                images.append(img)
            }
        }
        return ClipFrames(images: images, durations: file.frames.map { Double($0.effectiveDurationMs()) / 1000 })
    }

    static func == (a: ClipFrames, b: ClipFrames) -> Bool { a.images == b.images && a.durations == b.durations && a.strip == b.strip }
}

/// How an item was made, so it can be re-edited from the original.
struct EditParams: Codable, Hashable, Sendable {
    var transform: CropTransform
    var adjustments: ImageAdjustments
    /// Animations only (seconds into the source).
    var trimStart: Double = 0
    var trimEnd: Double = 0
    var fps: Double = 12
}

struct LibraryItem: Codable, Identifiable, Hashable, Sendable {
    /// `strip`: one wide frame the clip scrolls (marquees, PROTOCOL §2 `is_strip`).
    /// `oracle`: a Tarot oracle's text asset (PROTOCOL §5f), the item people see; its recipe and the
    /// ids of its deck, keys and notes are the item's `oracle.json`. `oraclePart`: one of those three
    /// (never listed, sent and deleted with its oracle).
    /// `retired`: a kind this version no longer makes or plays (the Magic 8 Ball, removed 2026-10-18):
    /// such items are deleted when the library loads.
    enum Kind: String, Codable, Sendable {
        case still, animation, strip, oracle, oraclePart, retired
        /// §5b.1: a words sheet (one word per frame) for the bouncing-words scene; `words.json` beside it.
        case words
        /// §5g: a board's sheet (header, empty row, a row per entry); `board.json` with the item beside it.
        case board

        init(from decoder: any Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .retired
        }
    }
    /// `created`: made in the Create tab; its recipe (`create.json`) reopens it in Draw, Text or Cards.
    /// `starter`: from the PixelClip pack bundled with the app (no original to re-edit).
    enum Source: String, Codable, Sendable { case photo, gif, video, livePhoto, file, pasted, sample, created, starter }

    /// Also the asset id on the clip.
    var id: String
    var name: String
    var kind: Kind
    var source: Source
    var createdAt: Date
    var updatedAt: Date
    /// File name of the untouched original inside the item folder.
    var originalFile: String
    var edit: EditParams
    var sha256: String
    var byteSize: Int
    var frameCount: Int
    /// One loop, in milliseconds (strips: one pass, `loops` = 1).
    var durationMs: Int
    /// Strips: how the clip scrolls it (speed, direction, gap; loops come from the playlist entry).
    var scroll: PlaylistItem.Scroll?
    /// Strips: the strip's width in pixels.
    var stripWidth: Int?

    var isAnimation: Bool { kind == .animation }
    var isStrip: Bool { kind == .strip && scroll != nil && stripWidth != nil }
    var isOracle: Bool { kind == .oracle }
    /// Shown in Recent (an oracle's deck, keys and notes aren't).
    var isListed: Bool { kind != .oraclePart }

    var summary: String {
        let size = byteSize.byteString
        let made = source == .created ? "Created · " : ""
        switch kind {
        case .animation: return "\(made)\(frameCount) frames · \(size)"
        case .strip: return "\(made)Scrolling · \(size)"
        case .still: return "\(made)Still · \(size)"
        case .retired: return size
        case .oracle: return "Tarot · \(size)"
        case .oraclePart: return "Tarot piece · \(size)"
        case .words: return "\(made)Bouncing words · \(size)"
        case .board: return "Board · \(size)"
        }
    }

    /// One pass of a strip with `loops` repeats, in ms (PlaybackEngine's rule).
    func stripDurationMs(loops: Int) -> Int {
        guard let scroll, let stripWidth else { return PlaybackEngine.stillDefaultMs }
        var s = scroll
        s.loops = max(1, loops)
        return StripScroller.durationMs(stripWidth: stripWidth, scroll: s)
    }
}

/// One slot of the old library playlist (before Now + Tonight), and still a picture's default rotation
/// timing (`LibraryStore.rotationItem`). Not PixelClip's `PlaylistEntry` (PixelClipKit, `PlaylistStore`).
struct LegacyPlaylistEntry: Codable, Identifiable, Hashable, Sendable {
    enum Timing: String, Codable, CaseIterable, Sendable { case seconds, loops }

    var id = UUID()
    var assetID: String
    var timing: Timing = .seconds
    var seconds: Double = 10
    var loops: Int = 3
    var transition: Transition = .fade

    /// The playlist item for this slot: seconds, or whole loops (animations) / passes (strips).
    func clipItem(for item: LibraryItem) -> PlaylistItem {
        if item.isStrip, var scroll = item.scroll {
            if timing == .loops {
                scroll.loops = max(1, loops)
                return PlaylistItem(type: .asset, id: assetID, durationMs: 0, transition: transition, scroll: scroll)
            }
            scroll.loops = nil
            return PlaylistItem(type: .asset, id: assetID, durationMs: Int((seconds * 1000).rounded()), transition: transition, scroll: scroll)
        }
        if timing == .loops && item.isAnimation {
            return .asset(assetID, durationMs: 0, loops: max(1, loops), transition: transition)
        }
        return .asset(assetID, durationMs: Int((seconds * 1000).rounded()), transition: transition)
    }

    /// Whole loops make sense for this item (animations and strips).
    static func loopable(_ item: LibraryItem) -> Bool { item.isAnimation || item.isStrip }
}

private struct LibraryIndex: Codable {
    var version = 1
    var items: [LibraryItem]
    var playlist: [LegacyPlaylistEntry]
    var lastSentFingerprint: String?
    var lastSentAt: Date?
    /// The fingerprint last sent to each clip, by its device id (absent in older indexes).
    var sentFingerprints: [String: String]?
}

/// The library on disk: Application Support/Library/index.json plus one folder per item holding
/// the original, the rendered `asset.hca` and a `thumb.png`.
@MainActor @Observable
final class LibraryStore {
    private(set) var items: [LibraryItem] = []
    /// The old playlist (read once to migrate it to Now + the playlist, see `ClipDocument.migrateIfNeeded`).
    private(set) var playlist: [LegacyPlaylistEntry] = [] { didSet { save() } }
    /// The fingerprint of the last document sent, to whichever clip.
    private(set) var lastSentFingerprint: String?
    private(set) var lastSentAt: Date?
    /// What each clip was last sent, by its device id: "sent" is a fact about one clip, so a send to a
    /// second clip (or to something posing as one) doesn't make the first look up to date.
    private(set) var sentFingerprints: [String: String] = [:]
    /// Bumped when an item's rendered asset changes, so previews reload.
    private(set) var revision = 0

    @ObservationIgnored let root: URL
    @ObservationIgnored private var framesCache: [String: ClipFrames] = [:]
    @ObservationIgnored private var cacheOrder: [String] = []

    init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Library", isDirectory: true)
        self.root = base
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("items"), withIntermediateDirectories: true)
        DataProtection.protect(base, .afterFirstUnlock)
        DataProtection.protect(base.appendingPathComponent("items"), .afterFirstUnlock)
        load()
    }

    // MARK: Paths

    func folder(_ id: String) -> URL { root.appendingPathComponent("items/\(id)", isDirectory: true) }
    func assetURL(_ id: String) -> URL { folder(id).appendingPathComponent("asset.hca") }
    func thumbURL(_ id: String) -> URL { folder(id).appendingPathComponent("thumb.png") }
    func originalURL(_ item: LibraryItem) -> URL { folder(item.id).appendingPathComponent(item.originalFile) }

    func item(_ id: String) -> LibraryItem? { items.first { $0.id == id } }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("index.json")),
              let idx = try? JSONDecoder.iso.decode(LibraryIndex.self, from: data) else { return }
        // The Magic 8 Ball is gone (2026-10-18): its items leave the library (and Now, Recent, the playlist).
        let retired = idx.items.filter { $0.kind == .retired }.map(\.id)
        for id in retired {
            NowOnClip.shared.forget(assetID: id)
            PlaylistStore.shared.removeAll(showingAsset: id)
            try? FileManager.default.removeItem(at: folder(id))
        }
        if !retired.isEmpty { UserDefaults.standard.removeObject(forKey: "eightball.settings.v1") }
        // Items made in Create before the `created` source existed were stored as `.file`.
        items = idx.items.filter { $0.kind != .retired }.map { item in
            var i = item
            if i.source == .file, FileManager.default.fileExists(atPath: folder(i.id).appendingPathComponent("create.json").path) { i.source = .created }
            return i
        }
        lastSentFingerprint = idx.lastSentFingerprint
        lastSentAt = idx.lastSentAt
        sentFingerprints = idx.sentFingerprints ?? [:]
        playlist = idx.playlist.filter { e in items.contains { $0.id == e.assetID } }   // (didSet saves: keep last)
    }

    private func save() {
        let idx = LibraryIndex(items: items, playlist: playlist, lastSentFingerprint: lastSentFingerprint, lastSentAt: lastSentAt,
                               sentFingerprints: sentFingerprints.isEmpty ? nil : sentFingerprints)
        guard let data = try? JSONEncoder.iso.encode(idx) else { return }
        try? data.write(to: root.appendingPathComponent("index.json"), options: .atomic)
    }

    // MARK: Mutations

    /// Store a freshly rendered asset (new item, or a re-edit when `replacing` is set).
    @discardableResult
    func add(_ rendered: RenderedAsset, name: String, source: LibraryItem.Source, original: Data, originalExtension: String,
             replacing: String? = nil, id fixedID: String? = nil, kind fixedKind: LibraryItem.Kind? = nil) throws -> LibraryItem {
        let kind: LibraryItem.Kind = fixedKind ?? (rendered.strip != nil ? .strip : (rendered.frameCount > 1 ? .animation : .still))
        let id = replacing ?? fixedID ?? Self.makeID(for: name, existing: Set(items.map(\.id)))
        let dir = folder(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let originalFile = "original.\(originalExtension)"
        if replacing == nil || !FileManager.default.fileExists(atPath: dir.appendingPathComponent(originalFile).path) {
            try original.write(to: dir.appendingPathComponent(originalFile), options: .atomic)
        }
        try rendered.data.write(to: assetURL(id), options: .atomic)
        if let thumb = rendered.poster.flatMap(ImageLoader.pngData) { try? thumb.write(to: thumbURL(id), options: .atomic) }
        let now = Date()
        let item = LibraryItem(id: id, name: name, kind: kind, source: source,
                               createdAt: self.item(id)?.createdAt ?? now, updatedAt: now, originalFile: self.item(id)?.originalFile ?? originalFile,
                               edit: rendered.edit, sha256: Hashing.sha256Hex(rendered.data), byteSize: rendered.data.count,
                               frameCount: rendered.frameCount, durationMs: rendered.durationMs,
                               scroll: rendered.strip?.scroll, stripWidth: rendered.strip?.width)
        if let i = items.firstIndex(where: { $0.id == id }) { items[i] = item } else { items.insert(item, at: 0) }
        invalidate(id)
        save()
        return item
    }

    func rename(_ id: String, to name: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items[i].name = trimmed
        save()
    }

    /// Adds a PixelClip pack piece as a normal item (`source` starter, id `zp-<slug>`); returns the
    /// existing item if it's already in the library with the same bytes. When an app update ships a
    /// changed piece, the copy is refreshed in place (same id, so Now and the playlist keep pointing at it,
    /// and the clip sync re-uploads it because its hash changed).
    @discardableResult
    func addStarter(_ piece: StarterPiece, data: Data) throws -> LibraryItem {
        let existing = item(piece.assetID)
        if let existing {
            if existing.sha256 == Hashing.sha256Hex(data) { return existing }
            try? FileManager.default.removeItem(at: originalURL(existing))   // `add` rewrites the original only if missing
        }
        let info = try StarterPack.info(data)
        let frames = try ClipFrames.decode(data)
        let rendered = RenderedAsset(data: data, poster: frames.images.first, frameCount: info.frameCount, durationMs: info.durationMs,
                                     edit: EditParams(transform: CropTransform(scale: 1), adjustments: ImageAdjustments(),
                                                      fps: info.frameCount > 1 && info.durationMs > 0 ? Double(info.frameCount) * 1000 / Double(info.durationMs) : 0))
        return try add(rendered, name: existing?.name ?? piece.title, source: .starter, original: data, originalExtension: "hca",
                       replacing: existing == nil ? nil : piece.assetID, id: piece.assetID)
    }

    /// Deletes an item; it stops being Now (and can't come back through Undo) and leaves the playlist.
    func delete(_ id: String) {
        // An oracle takes its keys (and an older one's notes) along, and its deck when no other oracle uses it.
        if let r = oracleRecipe(for: id) {
            let deckShared = items.contains { $0.id != id && $0.isOracle && oracleRecipe(for: $0.id)?.deck == r.deck }
            for part in [r.keys, r.notes].compactMap({ $0 }) + (deckShared ? [] : [r.deck]) where item(part)?.kind == .oraclePart {
                items.removeAll { $0.id == part }
                try? FileManager.default.removeItem(at: folder(part))
                invalidate(part)
            }
        }
        NowOnClip.shared.forget(assetID: id)
        PlaylistStore.shared.removeAll(showingAsset: id)
        items.removeAll { $0.id == id }
        playlist.removeAll { $0.assetID == id }
        try? FileManager.default.removeItem(at: folder(id))
        invalidate(id)
        save()
    }

    /// Record a successful send of the composed playlist (see `ClipDocument`) to the clip with this
    /// device id (nil when the clip never said who it was).
    func markSent(fingerprint: String, deviceID: String?) {
        lastSentFingerprint = fingerprint
        lastSentAt = Date()
        if let deviceID {
            if sentFingerprints.count >= Self.clipsRemembered, sentFingerprints[deviceID] == nil { sentFingerprints.removeAll() }
            sentFingerprints[deviceID] = fingerprint
        }
        save()
    }

    /// The clip with this device id was erased: it was sent nothing (nor, by the fallback, was whichever clip had
    /// the last send).
    func forgetSent(deviceID: String?) {
        lastSentFingerprint = nil
        if let deviceID { sentFingerprints[deviceID] = nil }
        save()
    }

    /// Clips whose last send is remembered (an id is the clip's to claim, so the list is bounded).
    static let clipsRemembered = 16

    /// What this clip was last sent. A clip the app has no record for was sent nothing, except when no
    /// send has been recorded by clip yet (an index from before they were told apart).
    func sentFingerprint(for deviceID: String?) -> String? {
        guard let deviceID, !sentFingerprints.isEmpty else { return lastSentFingerprint }
        return sentFingerprints[deviceID]
    }

    // MARK: Clip documents

    /// The old playlist as rotation slots (keyed by entry id), for the migration.
    var legacyPlaylistSlots: [RotationSlot] {
        playlist.compactMap { e in
            guard let item = item(e.assetID) else { return nil }
            return RotationSlot(id: e.id.uuidString, item: e.clipItem(for: item), title: item.name)
        }
    }

    func clearLegacyPlaylist() { if !playlist.isEmpty { playlist = [] } }

    /// A picture's playlist item (its scroll block for a strip): long animations play two loops and strips
    /// scroll by twice; short ones (and stills) get 10 s; an oracle gets three minutes. The playlist
    /// retimes it to a minute (`PlaylistSchedule.minute`); alone as Now it's held instead.
    func rotationItem(for id: String) -> PlaylistItem? {
        guard let item = item(id) else { return nil }
        if item.isOracle { return oracleItem(for: id)?.playlistItem() }
        var e = LegacyPlaylistEntry(assetID: id)
        if item.isStrip || (item.isAnimation && item.durationMs >= 3000) { e.timing = .loops; e.loops = 2 }
        return e.clipItem(for: item)
    }

    /// What sending this item shows: a picture, or the Tarot with its deck, keys, notes and mode.
    func content(for id: String) -> MomentContent {
        if let o = oracleItem(for: id) { return .oracle(o) }
        if item(id)?.kind == .words { return .words(sheet: id, text: wordsRecipe(for: id)?.text ?? "") }
        if item(id)?.kind == .board, let b = boardContent(for: id) { return .board(b) }
        return .asset(id)
    }

    /// §5g: what a board was stored with (`board.json` beside its sheet).
    func boardContent(for id: String) -> BoardContent? {
        guard let data = try? Data(contentsOf: folder(id).appendingPathComponent(BoardPreview.recipeFile)) else { return nil }
        return try? JSONDecoder().decode(BoardContent.self, from: data)
    }

    /// §5b.1: what a words sheet was made from (`words.json`): the text and the look.
    struct WordsRecipe: Codable, Equatable {
        var text: String
        var look: String
        static let fileName = "words.json"
    }

    func wordsRecipe(for id: String) -> WordsRecipe? {
        guard let data = try? Data(contentsOf: folder(id).appendingPathComponent(WordsRecipe.fileName)) else { return nil }
        return try? JSONDecoder().decode(WordsRecipe.self, from: data)
    }

    /// Stores a words sheet like a written message (id = the sheet id, its poster = the words at rest).
    @discardableResult
    func addWords(_ sheet: WordsSheet, text: String, look: String, name: String) throws -> LibraryItem {
        let still = WordsSheetRenderer.restingStill(sheet.frames)
        let poster = ClipRenderer.makeCGImage(still)
        let png = poster.flatMap(ImageLoader.pngData) ?? Data()
        let rendered = RenderedAsset(data: sheet.data, poster: poster, frameCount: sheet.frames.count, durationMs: 0,
                                     edit: EditParams(transform: CropTransform(scale: 1), adjustments: .neutral), strip: nil)
        let item = try add(rendered, name: name, source: .created, original: png, originalExtension: "png",
                           replacing: self.item(sheet.id) == nil ? nil : sheet.id, id: sheet.id, kind: .words)
        let recipe = try JSONEncoder().encode(WordsRecipe(text: text, look: look))
        try? recipe.write(to: folder(item.id).appendingPathComponent(WordsRecipe.fileName), options: .atomic)
        return item
    }

    /// Scroll blocks of strip items (moments that show a strip need them too).
    var scrolls: [String: PlaylistItem.Scroll] {
        Dictionary(items.compactMap { i in i.isStrip ? i.scroll.map { (i.id, $0) } : nil }, uniquingKeysWith: { a, _ in a })
    }

    func localAssets(ids: [String]) -> [LocalAsset] {
        ids.compactMap { id in
            guard let data = try? Data(contentsOf: assetURL(id)) else { return nil }
            return LocalAsset(id: id, data: data, name: item(id)?.name)
        }
    }

    var totalBytes: Int { items.reduce(0) { $0 + $1.byteSize } }

    // MARK: Previews

    func cachedFrames(_ id: String) -> ClipFrames? { framesCache[id] }

    /// Decoded frames for an item (off the main thread, cached; LRU of 24 items).
    func frames(for id: String) async -> ClipFrames? {
        if let hit = framesCache[id] { return hit }
        let url = assetURL(id)
        let scroll = item(id)?.scroll
        // An oracle's picture is its waits screen: the text asset's frame 0 with the deck's back in the slot.
        let deckURL = item(id)?.isOracle == true ? oracleRecipe(for: id).map { assetURL($0.deck) } : nil
        let isWords = item(id)?.kind == .words
        let isBoard = item(id)?.kind == .board
        let frames = await Task.detached(priority: .userInitiated) { () -> ClipFrames? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            if isBoard {
                // A board shows as the header over its first rows (as the clip at rest).
                guard let sheet = try? HCAFile(data: data).decodeAllFrames() else { return nil }
                return ClipFrames(single: ClipRenderer.makeCGImage(BoardPreview.poster(sheet)))
            }
            if isWords {
                // A words sheet shows as its words resting along the bottom edge (as the virtual clip draws it).
                guard let sprites = try? HCAFile(data: data).decodeAllFrames() else { return nil }
                return ClipFrames(single: ClipRenderer.makeCGImage(WordsSheetRenderer.restingStill(sprites)))
            }
            if deckURL != nil {
                // §5f.11: the poster is the clip's whole waits screen (the back, the prompt, the corner ▶).
                guard let waits = try? HCAFile(data: data).decodeFrame(0) else { return nil }
                return ClipFrames(single: ClipRenderer.makeCGImage(waits))
            }
            return try? ClipFrames.decode(data, scroll: scroll)
        }.value
        if let frames {
            framesCache[id] = frames
            cacheOrder.removeAll { $0 == id }
            cacheOrder.append(id)
            while cacheOrder.count > 24 { framesCache[cacheOrder.removeFirst()] = nil }
        }
        return frames
    }

    private func invalidate(_ id: String) {
        framesCache[id] = nil
        cacheOrder.removeAll { $0 == id }
        revision += 1
    }

    // MARK: Ids

    /// `slug-xxxx`, ASCII only, ≤ 32 chars.
    static func makeID(for name: String, existing: Set<String>) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .init(identifier: "en"))
            .lowercased()
        var slug = ""
        for ch in folded.unicodeScalars {
            if ("a"..."z").contains(ch) || ("0"..."9").contains(ch) { slug.unicodeScalars.append(ch) } else if !slug.hasSuffix("-") && !slug.isEmpty { slug += "-" }
        }
        slug = String(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(26))
        if slug.isEmpty { slug = "item" }
        while true {
            let suffix = String(UInt16.random(in: 0...UInt16.max), radix: 16).leftPadded(4)
            let id = "\(slug)-\(suffix)"
            if !existing.contains(id) && HCA.isValidAssetID(id) { return id }
        }
    }
}

/// Output of the editor, ready to store.
struct RenderedAsset: @unchecked Sendable {
    var data: Data
    var poster: CGImage?
    var frameCount: Int
    var durationMs: Int
    var edit: EditParams
    /// Set for a scrolling strip (one wide frame + how to scroll it).
    var strip: (width: Int, scroll: PlaylistItem.Scroll)?
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

extension String {
    func leftPadded(_ n: Int, with c: Character = "0") -> String {
        count >= n ? self : String(repeating: c, count: n - count) + self
    }
}

extension Int {
    var byteString: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: Int64(self))
    }
}

/// §5g: a board item in the library: its `board.json` and the picture it shows.
enum BoardPreview {
    static let recipeFile = "board.json"

    /// The library picture of a board: the header over the first rows, as the clip shows it at rest.
    static func poster(_ frames: [RGB565Frame]) -> RGB565Frame {
        let rows = (2..<max(2, frames.count)).map { BoardRow(frame: $0) }
        return Board.frame(sheet: frames, header: 0, empty: 1, rows: rows, speed: Board.defaultSpeed, tMs: 0)
    }
}
