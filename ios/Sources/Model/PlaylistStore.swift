import Foundation
import Observation
import UIKit
import PixelClipKit

/// PixelClip's playlist (docs/DESIGN.md "Playlist"): the only playlist model the UI uses.
///
/// - When `isOn`, the clip rotates through the untimed entries in order, a minute each (`duration_ms`
///   60 000, fade). Now (`NowOnClip`, what the last Send put on the clip) plays first in that rotation,
///   so a Send while the playlist is on still shows at once; an entry showing the same thing as Now
///   isn't played twice.
/// - An entry with `at` is a one-off `queue[]` entry at that time for 60 s, then the clip goes back to
///   what it was doing; it is never in the rotation.
/// - When `isOn` is false, Now holds and the timed entries still fire.
///
/// `ClipDocument` composes this (with `PlaylistSchedule`, PixelClipKit) into the one playlist document every
/// send PUTs; the device protocol is unchanged. Edits don't send by themselves: the composed document
/// then differs from what was last sent (`ClipDocument.hasUnsentChanges`), and the next send carries it
/// (or call `ClipSender.shared.send()`).
///
/// Content: `MomentContent`. A written message (Write) is saved to the Library as a still or a strip,
/// so it is `.asset(id)` like a photo; there is no separate text case.
///
/// Persisted to Application Support/Playlist/playlist.json. The first launch of this version moves
/// the earlier design's Tonight over once (Application Support/Tonight/tonight.json): its rotation items become
/// untimed entries in order, its moments that haven't ended become timed entries, windows are dropped.
@MainActor @Observable
final class PlaylistStore {
    static let shared = PlaylistStore()

    private(set) var entries: [PlaylistEntry] = [] { didSet { save() } }
    /// "Playlist is on" (persisted). Changing it changes the composed document, which then counts as
    /// unsent (`ClipDocument.hasUnsentChanges`).
    var isOn: Bool = true {
        didSet {
            guard isOn != oldValue else { return }
            save()
        }
    }
    /// Bumped on every change (a cheap signal for views and for "changes to send").
    private(set) var revision = 0
    /// Entries the one-time migration from Tonight brought over at this launch (0: none), for a toast.
    private(set) var migratedCount = 0

    /// The library, for thumbnails and names (attached at launch: `ClipSender.shared.attach`).
    @ObservationIgnored weak var library: LibraryStore?

    @ObservationIgnored private let url: URL
    @ObservationIgnored private var loading = true
    @ObservationIgnored private let thumbs = NSCache<NSString, UIImage>()

    private struct Stored: Codable {
        var version = 1
        var entries: [PlaylistEntry]
        var isOn: Bool

        init(entries: [PlaylistEntry], isOn: Bool) { self.entries = entries; self.isOn = isOn }

        /// Entries this version can't read (a Magic 8 Ball, removed 2026-10-18) are dropped, not the playlist.
        init(from decoder: any Decoder) throws {
            struct Lossy: Decodable {
                var entry: PlaylistEntry?
                init(from decoder: any Decoder) throws { entry = try? PlaylistEntry(from: decoder) }
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            entries = try c.decode([Lossy].self, forKey: .entries).compactMap(\.entry)
            isOn = try c.decode(Bool.self, forKey: .isOn)
        }

        enum CodingKeys: String, CodingKey { case version, entries, isOn }
    }

    /// The earlier design's `TonightStore` file, as far as the migration needs it.
    private struct LegacyTonight: Decodable {
        var windows: [String: TonightLayer.Window]?
        var extras: [TonightLayer.Extra]?
        var order: [String]?
        var moments: [Moment]?
    }

    /// - Parameters:
    ///   - directory: where `playlist.json` lives (tests pass a temporary folder).
    ///   - tonightDirectory: where the earlier design kept `tonight.json` (migrated once, when no playlist exists yet).
    init(directory: URL? = nil, tonightDirectory: URL? = nil, now: Date = Date()) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = directory ?? support.appendingPathComponent("Playlist", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("playlist.json")
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder.iso.decode(Stored.self, from: data) {
            entries = s.entries
            isOn = s.isOn
            loading = false
        } else {
            let tonightURL = (tonightDirectory ?? support.appendingPathComponent("Tonight", isDirectory: true))
                .appendingPathComponent("tonight.json")
            if let data = try? Data(contentsOf: tonightURL), let t = try? JSONDecoder.iso.decode(LegacyTonight.self, from: data) {
                let layer = TonightLayer(windows: t.windows ?? [:], extras: t.extras ?? [], order: t.order ?? [], moments: t.moments ?? [])
                entries = PlaylistMigration.entries(from: layer, now: now)
                migratedCount = entries.count
            }
            loading = false
            save()
        }
    }

    private func save() {
        guard !loading else { return }
        revision += 1
        guard let data = try? JSONEncoder.iso.encode(Stored(entries: entries, isOn: isOn)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Reading

    /// The entries that take turns (no time).
    var rotation: [PlaylistEntry] { entries.filter { !$0.isTimed } }
    /// The one-offs, in time order.
    var timed: [PlaylistEntry] { entries.filter(\.isTimed).sorted { $0.at! < $1.at! } }
    var isEmpty: Bool { entries.isEmpty }

    func entry(_ id: String) -> PlaylistEntry? { entries.first { $0.id == id } }

    /// The Home tile's line: "3 things, one after another" / "nothing yet".
    var tileLine: String {
        switch entries.count {
        case 0: "nothing yet"
        case 1: "1 thing"
        default: "\(entries.count) things, one after another"
        }
    }

    /// A row's timing: "1 min", or "once, at 21:30 · then back to the playlist" ("played at 21:30" once it has).
    func timingLine(_ entry: PlaylistEntry, now: Date = Date()) -> String {
        guard let at = entry.at else { return "1 min" }
        let t = at.formatted(date: .omitted, time: .shortened)
        if entry.isPast(now: now) { return "played at \(t)" }
        let day = Calendar.current.isDate(at, inSameDayAs: now) ? "" : (Calendar.current.isDateInTomorrow(at) ? " tomorrow" : " on \(at.formatted(.dateTime.weekday(.wide)))")
        return "once, at \(t)\(day) · then back to the playlist"
    }

    // MARK: Writing

    /// Adds `content` at the end of the rotation (an identical untimed entry already there is returned
    /// instead, renamed to `name`).
    @discardableResult
    func add(_ content: MomentContent, name: String) -> PlaylistEntry {
        if let i = entries.firstIndex(where: { !$0.isTimed && $0.content == content }) {
            if entries[i].name != name { entries[i].name = name }
            return entries[i]
        }
        let e = PlaylistEntry(id: uniqueID(), content: content, name: name)
        entries.append(e)
        return e
    }

    /// Takes an entry out; returns it so the UI can offer Undo (`insert(_:at:)`).
    @discardableResult
    func remove(_ id: String) -> PlaylistEntry? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: i)
    }

    /// Puts a removed entry back (Undo). No-op if an entry with its id is there.
    func insert(_ entry: PlaylistEntry, at index: Int) {
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        entries.insert(entry, at: max(0, min(entries.count, index)))
    }

    /// `Array.move(fromOffsets:toOffset:)` semantics (SwiftUI's `onMove`).
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let valid = IndexSet(source.filter { entries.indices.contains($0) })
        guard !valid.isEmpty else { return }
        let moving = valid.sorted().map { entries[$0] }
        let before = valid.filter { $0 < destination }.count
        var rest = entries.enumerated().filter { !valid.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: moving, at: max(0, min(rest.count, destination - before)))
        if rest != entries { entries = rest }
    }

    /// "Play it once at a time": `at` makes the entry a one-off at that time (out of the rotation);
    /// nil puts it back in the rotation. (`PlaylistSchedule.upcoming(hour:minute:)` turns a picked
    /// time of day into the next such moment.)
    func setTime(_ id: String, at: Date?) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let rounded = at.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 60).rounded(.down) * 60) }
        if entries[i].at != rounded { entries[i].at = rounded }
    }

    func rename(_ id: String, to name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = entries.firstIndex(where: { $0.id == id }), entries[i].name != t else { return }
        entries[i].name = t
    }

    /// A library item was deleted: its entries go.
    func removeAll(showingAsset assetID: String) {
        if entries.contains(where: { $0.content.assetID == assetID }) { entries.removeAll { $0.content.assetID == assetID } }
    }

    /// Reader ▸ Add to the playlist: the reading of a text joins the rotation, or its untimed entry
    /// gets the new typeface, speed and title. Returns the entry.
    @discardableResult
    func upsertReading(_ content: MomentContent, name: String) -> PlaylistEntry {
        guard case .reader(let text, _, _) = content else { return add(content, name: name) }
        if let i = entries.firstIndex(where: { e in
            if !e.isTimed, case .reader(let t, _, _) = e.content { t == text } else { false }
        }) {
            entries[i].content = content
            entries[i].name = name
            return entries[i]
        }
        return add(content, name: name)
    }

    /// A saved text was deleted: its readings go.
    func removeReadings(text: String) {
        let shows: (PlaylistEntry) -> Bool = { if case .reader(let t, _, _) = $0.content { t == text } else { false } }
        if entries.contains(where: shows) { entries.removeAll(where: shows) }
    }

    private func uniqueID() -> String {
        let taken = Set(entries.map(\.id))
        while true {
            let id = PlaylistEntry.makeID()
            if !taken.contains(id) { return id }
        }
    }

    // MARK: Thumbnails

    /// A small picture of what the entry shows: the Library's thumbnail (pictures, messages, drawings,
    /// the Tarot: its waits screen), the scene in its palette, a card for a reading.
    func thumbnail(for entry: PlaylistEntry) -> UIImage? {
        let key = thumbKey(entry) as NSString
        if let hit = thumbs.object(forKey: key) { return hit }
        let image: UIImage?
        switch entry.content {
        case .asset(let id):
            image = libraryThumb(id)
        case .oracle(let o):
            image = libraryThumb(o.libraryKey)
        case .words(let sheet, _):
            image = libraryThumb(sheet)   // the words resting along the bottom (its poster)
        case .board(let b):
            image = libraryThumb(b.sheet) // the header over the first rows
        case .scene(let name, let params):
            let palette: String? = if case .string(let p)? = params["palette"] { p } else { nil }
            image = SceneThumbnail.image(scene: name, palette: SceneLook.palette(palette, for: name)).map { UIImage(cgImage: $0) }
        case .reader:
            image = Self.readerCard(title: entry.name)
        }
        if let image { thumbs.setObject(image, forKey: key) }
        return image
    }

    private func thumbKey(_ e: PlaylistEntry) -> String {
        switch e.content {
        case .asset(let id): "a|\(id)|\(library?.item(id)?.sha256 ?? "")"
        case .oracle(let o): "a|\(o.libraryKey)|\(library?.item(o.libraryKey)?.sha256 ?? "")"
        case .words(let sheet, _): "a|\(sheet)|\(library?.item(sheet)?.sha256 ?? "")"
        case .board(let b): "a|\(b.sheet)|\(library?.item(b.sheet)?.sha256 ?? "")"
        case .scene(let n, let p): "s|\(n)|\(p["palette"].map { "\($0)" } ?? "")"
        case .reader(let t, _, _): "r|\(t)|\(e.name)"
        }
    }

    private func libraryThumb(_ id: String) -> UIImage? {
        guard let library, library.item(id) != nil else { return nil }
        if let img = UIImage(contentsOfFile: library.thumbURL(id).path) { return img }
        return library.cachedFrames(id)?.images.first.map { UIImage(cgImage: $0) }
    }

    /// A dark clip-shaped card with the reading's title.
    private static func readerCard(title: String) -> UIImage {
        let size = CGSize(width: 268, height: 120)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.055, green: 0.047, blue: 0.078, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .semibold),
                .foregroundColor: UIColor(red: 0.957, green: 0.945, blue: 0.98, alpha: 1),
                .paragraphStyle: style,
            ]
            let text = title.isEmpty ? "Reader" : title
            let rect = CGRect(x: 16, y: (size.height - 56) / 2, width: size.width - 32, height: 56)
            (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs, context: nil)
        }
    }
}

/// A still of a live scene in its palette, on the clip's pixel grid (an illustration, like the previews).
enum SceneThumbnail {
    static func image(scene: String, palette: String, cols: Int = 67, rows: Int = 30) -> CGImage? {
        var px = [UInt8](repeating: 0, count: cols * rows * 4)
        func hash(_ x: Int, _ y: Int) -> Double {
            var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
            h = (h ^ (h >> 13)) &* 1_274_126_177
            return Double(h ^ (h >> 16)) / Double(UInt32.max)
        }
        func put(_ x: Int, _ y: Int, _ v: Double) {
            guard x >= 0, x < cols, y >= 0, y < rows else { return }
            let c = SceneLook.color(palette, at: v)
            let i = (y * cols + x) * 4
            px[i] = UInt8(min(255, c.r * 255)); px[i + 1] = UInt8(min(255, c.g * 255)); px[i + 2] = UInt8(min(255, c.b * 255)); px[i + 3] = 255
        }
        for y in 0..<rows { for x in 0..<cols { put(x, y, 0) } }
        let w = Double(cols), h = Double(rows)
        switch scene {
        case "sand":
            // A heap in the middle, grains falling onto it.
            for x in 0..<cols {
                let d = abs(Double(x) - w / 2) / (w / 2)
                let top = Int(h * (0.35 + 0.55 * d * d))
                for y in top..<rows { put(x, y, 0.45 + 0.4 * hash(x, y)) }
            }
            for i in 0..<14 { put(Int(w / 2) + i % 3 - 1, i * 2 / 3, 0.85) }
        case "water":
            for x in 0..<cols {
                let top = Int(h * 0.45 + 2.2 * sin(Double(x) / 5))
                for y in max(0, top)..<rows { put(x, y, 0.35 + 0.45 * Double(y - top) / h + 0.1 * hash(x, y)) }
            }
        case "snow":
            for y in 0..<rows { for x in 0..<cols where hash(x, y) > 0.94 { put(x, y, 0.75 + 0.25 * hash(y, x)) } }
            for x in 0..<cols { for y in (rows - 3 - Int(2 * hash(x, 0)))..<rows { put(x, y, 0.85) } }
        case "fire":
            for y in 0..<rows {
                for x in 0..<cols {
                    let heat = pow(Double(y) / h, 1.6) * (0.7 + 0.5 * hash(x, y / 3)) - 0.1 * abs(Double(x) - w / 2) / w
                    if heat > 0.12 { put(x, y, min(1, heat)) }
                }
            }
        default:   // "balls" and anything else: bright dots of several tones
            for i in 0..<9 {
                let cx = Int(hash(i, 1) * w), cy = Int(hash(i, 2) * h), r = 2 + Int(hash(i, 3) * 3)
                let tone = 0.45 + 0.5 * hash(i, 4)
                for y in (cy - r)...(cy + r) { for x in (cx - r)...(cx + r) where (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r { put(x, y, tone) } }
            }
        }
        let data = Data(px) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
