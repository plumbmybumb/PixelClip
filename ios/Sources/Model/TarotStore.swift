import CoreGraphics
import Foundation
import Observation
import UIKit
import PixelClipKit

/// The Tarot's credits (Settings ▸ Advanced ▸ About).
enum TarotCredits {
    static let deck = "Tarot de Marseille by Jean Dodal, Lyon 1701 — Bibliothèque nationale de France, via Wikimedia Commons, public domain."
    static let readings = "The readings, questions, keywords and number notes are PixelClip’s own texts, written for this app."
}

/// What an oracle library item was made from, saved beside it as `oracle.json`: the choices (mode,
/// language, card of the day, the person's edits), the ids of its deck, keys and notes, and (PROTOCOL §5f.2) its
/// phrase bundle — saved beside it as `reader.txt`, its `/texts` id here, the oracle's id on the clip — and
/// the body and big fonts the clip writes with. The library item itself is only the app's poster (the
/// waits screen), never sent. Recipes from before §5f.2 (a text asset, `pages`, no fonts) are remade at
/// launch (`TarotMaker.upgrade`).
struct OracleRecipe: Codable, Hashable, Sendable {
    static let fileName = "oracle.json"
    static let readerFileName = "reader.txt"
    var spec: TarotSpec
    var deck: String
    /// The keyword tiles (§5f.12: sent again; nil in recipes made under §5f.10/§5f.11).
    var keys: String?
    /// Before §5f.7: the notes asset (no longer sent).
    var notes: String?
    var cards: Int
    /// Before §5f.2: the text asset's reading pages.
    var pages: Int?
    var reader: String?
    var font: String?
    var fontBig: String?

    /// Made the §5f.3 way (bundle and size-tagged fonts, no text asset).
    /// §5f.12: the 108×206 deck (its id carries the size) with its keys.
    var isCurrent: Bool {
        pages == nil && reader != nil && font.flatMap(TarotFonts.fontKey(inID:)) != nil && fontBig.flatMap(TarotFonts.fontKey(inID:)) != nil
            && Oracle.isCurrentDeckID(deck) && keys != nil
    }
}

extension LibraryStore {
    func oracleRecipe(for id: String) -> OracleRecipe? {
        guard let data = try? Data(contentsOf: folder(id).appendingPathComponent(OracleRecipe.fileName)) else { return nil }
        return try? JSONDecoder().decode(OracleRecipe.self, from: data)
    }

    /// An oracle item's playlist settings (from its recipe; the clip id is its bundle's), nil for other items
    /// and for oracles not yet remade the §5f.2 way.
    func oracleItem(for id: String) -> OracleItem? {
        guard let item = item(id), item.isOracle, let r = oracleRecipe(for: id), r.isCurrent, let reader = r.reader,
              FileManager.default.fileExists(atPath: folder(id).appendingPathComponent(OracleRecipe.readerFileName).path) else { return nil }
        return OracleItem(id: reader, deck: r.deck, keys: r.keys, cards: r.cards,
                          font: r.font, fontBig: r.fontBig, libraryID: id)
    }

    /// The phrase bundle saved with an oracle (`reader.txt`), nil when it has none.
    func readerBundle(forOracle id: String) -> Data? {
        try? Data(contentsOf: folder(id).appendingPathComponent(OracleRecipe.readerFileName))
    }

    /// The phrase bundle whose `/texts` id is `textID`, from whichever oracle carries it.
    func readerBundle(textID: String) -> Data? {
        for item in items where item.isOracle {
            if oracleRecipe(for: item.id)?.reader == textID, let d = readerBundle(forOracle: item.id) { return d }
        }
        return nil
    }

    /// The sentence reader of an oracle item (its saved bundle, parsed), nil without one.
    func sentenceReader(forOracle id: String) -> SentenceReader? {
        readerBundle(forOracle: id).map { SentenceReader(bundle: $0) }
    }
}

/// The Tarot's settings, kept on this iPhone: the language, the text size and the person's edits to the texts (per card,
/// per language), and the library items the oracle was last sent as (§5f.6: no mode, no card of the day).
@MainActor @Observable
final class TarotSettings {
    static let shared = TarotSettings()

    var language: TarotLanguage { didSet { save() } }
    var edits: TarotEdits { didSet { save() } }
    /// §5f.3: Small / Medium / Large on the clip.
    var textSize: TarotTextSize { didSet { save() } }
    /// Library ids: the shared deck, and per language the text asset (the item), keys and notes.
    var deckID: String? { didSet { save() } }
    var itemIDs: [String: String] { didSet { save() } }
    var keysIDs: [String: String] { didSet { save() } }
    var notesIDs: [String: String] { didSet { save() } }

    private struct Stored: Codable {
        var language: TarotLanguage; var edits: TarotEdits
        var deckID: String?; var itemIDs: [String: String]; var keysIDs: [String: String]; var notesIDs: [String: String]
        var textSize: TarotTextSize?
    }
    private static let key = "tarot.settings.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let s = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        language = s?.language ?? .fr
        edits = s?.edits ?? .none
        textSize = s?.textSize ?? .large
        deckID = s?.deckID
        itemIDs = s?.itemIDs ?? [:]
        keysIDs = s?.keysIDs ?? [:]
        notesIDs = s?.notesIDs ?? [:]
    }

    private func save() {
        let s = Stored(language: language, edits: edits, deckID: deckID, itemIDs: itemIDs, keysIDs: keysIDs, notesIDs: notesIDs,
                       textSize: textSize)
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.key) }
    }

    var spec: TarotSpec { TarotSpec(language: language, edits: edits, textSize: textSize) }
}

/// The deck and texts bundled with the app (`PixelClip.app/Tarot/`: `dodal/NN-….png`, `back.png`,
/// `readings.json`), loaded once, plus small pictures of the cards for the screens.
@MainActor
final class TarotBundle {
    static let shared = TarotBundle()

    let deck: TarotDeck?
    let readings: TarotReadings?
    /// The sentence reader's phrase bundles as shipped (`reader-fr.txt`, `reader-en.txt`), per language.
    let readerBundles: [TarotLanguage: String]

    init(bundle: Bundle = .main) {
        let root = bundle.url(forResource: "Tarot", withExtension: nil)
        deck = root.flatMap { try? TarotDeck(folder: $0.appendingPathComponent("dodal")) }
        readings = root.flatMap { try? Data(contentsOf: $0.appendingPathComponent("readings.json")) }.flatMap { try? TarotReadings(data: $0) }
        var bundles: [TarotLanguage: String] = [:]
        for l in TarotLanguage.allCases {
            if let url = root?.appendingPathComponent("reader-\(l.rawValue).txt"), let s = try? String(contentsOf: url, encoding: .utf8) { bundles[l] = s }
        }
        readerBundles = bundles
    }

    /// The bundle the clip gets for `language` with the person's edits: their keyword, question and closing replace the
    /// card's lines (`ReaderBundle.applying`); their readings don't change it (the bundle carries the fixed
    /// card table, not the readings). Nil when the app has no bundle for that language.
    func readerBundle(_ language: TarotLanguage, edits: TarotEdits) -> Data? {
        readerBundles[language].map { Data(ReaderBundle.applying(edits: edits, language: language, to: $0).utf8) }
    }

    var isAvailable: Bool { deck != nil && readings != nil }

    func face(_ i: Int) -> UIImage? {
        guard let deck, deck.faces.indices.contains(i) else { return nil }
        return UIImage(cgImage: deck.faces[i])
    }
    var back: UIImage? { deck.map { UIImage(cgImage: $0.back) } }

    /// "XVII · L'Étoile".
    func title(_ i: Int, language: TarotLanguage) -> String {
        guard let r = readings?[i] else { return "" }
        let n = r.numeral.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? r.name(language) : "\(n) · \(r.name(language))"
    }
}

/// The Tarot's fonts (§5f.2/§5f.3), rendered once per run and size (≈ 1 s, off the main actor): the body font
/// the clip writes its screens and paragraph pages with, and the numeral's big font. Content-hashed ids that
/// carry the size (`tarot-font22-<hash>`, `tarot-big56-<hash>`), so a render gives the same ids as the one before.
@MainActor
final class TarotFontStore {
    static let shared = TarotFontStore()
    private var cache: [TarotTextSize: (body: ReaderFont, big: ReaderFont)] = [:]
    private var rendering: [TarotTextSize: Task<(ReaderFont, ReaderFont)?, Never>] = [:]

    /// Already rendered (no wait).
    func cached(_ size: TarotTextSize) -> (body: ReaderFont, big: ReaderFont)? { cache[size] }

    func fonts(_ size: TarotTextSize = .medium) async -> (body: ReaderFont, big: ReaderFont)? {
        if let hit = cache[size] { return hit }
        let task = rendering[size] ?? Task.detached(priority: .userInitiated) { () -> (ReaderFont, ReaderFont)? in
            guard let b = try? TarotFonts.body(size), let g = try? TarotFonts.big(size) else { return nil }
            return (b, g)
        }
        rendering[size] = task
        guard let (b, g) = await task.value else { rendering[size] = nil; return nil }
        cache[size] = (b, g)
        return (b, g)
    }

    /// The size a Tarot font id was rendered at (from the point size in its id).
    static func size(ofFontID id: String) -> TarotTextSize? {
        TarotTextSize.allCases.first { id.hasPrefix(TarotFonts.bodyPrefix($0)) || id.hasPrefix(TarotFonts.bigPrefix($0)) }
    }
}

/// Renders the oracle for one language and puts it in the library (§5f.2): the deck (shared by both
/// languages, replaced only when its bytes change), the keys and notes (hidden pieces), the phrase bundle
/// with the person's edits (`reader.txt`) and the item people see in Recent (the app's waits screen, never sent).
@MainActor
enum TarotMaker {
    enum Failure: Error { case noDeck, noBundle, noFonts }

    static func make(spec: TarotSpec, settings: TarotSettings, library: LibraryStore, replacing: String? = nil) async throws -> LibraryItem {
        guard let deck = TarotBundle.shared.deck, let readings = TarotBundle.shared.readings else { throw Failure.noDeck }
        guard let bundle = TarotBundle.shared.readerBundle(spec.language, edits: TarotEdits(edits: spec.edits)) else { throw Failure.noBundle }
        guard let fonts = await TarotFontStore.shared.fonts(spec.textSize) else { throw Failure.noFonts }
        let box = DeckBox(deck: deck)
        let bodyFont = fonts.body, bigFont = fonts.big
        let rendered = try await Task.detached(priority: .userInitiated) { () -> RenderedBox in
            let r = try TarotRenderer.renderParts(deck: box.deck, readings: readings, spec: spec, fonts: .bundled())
            // The poster: the clip's own waits screen (§5f.11: the back, the prompt, the corner ▶).
            let assets = OracleCompositor.Assets(deck: r.deckFrames, keys: r.keyFrames, notes: [], font: ReaderBoundFont(bodyFont),
                                                 bundle: SentenceReader(bundle: bundle), fontBig: ReaderBoundFont(bigFont))
            let waits = OracleCompositor.frame(.waits, assets)
            let posterHCA = try TarotRenderer.encode([waits])
            return RenderedBox(r: r, posterHCA: posterHCA, poster: ClipRenderer.makeCGImage(waits))
        }.value
        let r = rendered.r
        let lang = spec.language.rawValue
        let existing = Set(library.items.map(\.id))
        func part(_ data: Data, frames: Int, id: String?, fresh: () -> String, name: String) throws -> String {
            let id = id.flatMap { library.item($0) != nil ? $0 : nil }
            if let id, library.item(id)?.sha256 == Hashing.sha256Hex(data) { return id }
            let item = try library.add(RenderedAsset(data: data, poster: nil, frameCount: frames, durationMs: 0,
                                                     edit: EditParams(transform: CropTransform(scale: 1), adjustments: .neutral, fps: 0)),
                                       name: name, source: .created, original: Data(), originalExtension: "bin",
                                       replacing: id, id: id == nil ? fresh() : nil, kind: .oraclePart)
            return item.id
        }
        // §5f.12: a 108×206 deck gets a new id (`tarot-dodal-dk108-…`), so the clip takes it once as a new asset.
        let deckID = try part(r.deck, frames: r.deckFrames.count, id: settings.deckID.flatMap { Oracle.isCurrentDeckID($0) ? $0 : nil },
                              fresh: { OracleItem.makeID(language: nil, part: Oracle.deckIDPart, existing: existing) }, name: "Tarot deck")
        let keysID = try part(r.keys, frames: r.keyFrames.count, id: settings.keysIDs[lang],
                              fresh: { OracleItem.makeID(language: lang, part: "keys", existing: existing) }, name: "Tarot keywords")
        let previous = (replacing ?? settings.itemIDs[lang]).flatMap { library.item($0) }
        let item = try library.add(RenderedAsset(data: rendered.posterHCA, poster: rendered.poster, frameCount: 1, durationMs: 0,
                                                 edit: EditParams(transform: CropTransform(scale: 1), adjustments: .neutral, fps: 0)),
                                   name: previous?.name ?? spec.name, source: .created,
                                   original: rendered.poster.flatMap(ImageLoader.pngData) ?? Data(), originalExtension: "png",
                                   replacing: previous?.id, id: previous == nil ? OracleItem.makeID(language: lang, existing: existing) : nil,
                                   kind: .oracle)
        try bundle.write(to: library.folder(item.id).appendingPathComponent(OracleRecipe.readerFileName), options: .atomic)
        let recipe = OracleRecipe(spec: spec, deck: deckID, keys: keysID, notes: nil, cards: r.cards, pages: nil,
                                  reader: ReaderBundle.textID(language: spec.language, data: bundle), font: fonts.body.id, fontBig: fonts.big.id)
        try JSONEncoder().encode(recipe).write(to: library.folder(item.id).appendingPathComponent(OracleRecipe.fileName), options: .atomic)
        settings.deckID = deckID
        settings.keysIDs[lang] = keysID
        if replacing == nil || settings.itemIDs[lang] == replacing { settings.itemIDs[lang] = item.id }
        return item
    }

    /// Oracles made before §5f.2 (a text asset, no bundle or fonts) are remade from their recipe, so Now and
    /// the playlist keep them (they drop out until then: the clip no longer takes a text asset).
    static func upgrade(library: LibraryStore, settings: TarotSettings = .shared) async {
        for item in library.items where item.isOracle {
            guard let r = library.oracleRecipe(for: item.id), !r.isCurrent else { continue }
            _ = try? await make(spec: r.spec, settings: settings, library: library, replacing: item.id)
        }
    }

    /// Bytes the clip stores for one language: deck, keys, notes, bundle and both fonts' atlases.
    static func clipBytes(for item: String, library: LibraryStore) async -> Int? {
        guard let r = library.oracleRecipe(for: item), let fonts = await TarotFontStore.shared.fonts(r.spec.textSize) else { return nil }
        let parts = [r.deck, r.keys].compactMap { $0 }.compactMap { library.item($0)?.byteSize }.reduce(0, +)
        return parts + (library.readerBundle(forOracle: item)?.count ?? 0) + fonts.body.atlasBytes + fonts.big.atlasBytes
    }

    private struct DeckBox: @unchecked Sendable { let deck: TarotDeck }
    private struct RenderedBox: @unchecked Sendable { let r: TarotRenderer.Parts; let posterHCA: Data; let poster: CGImage? }
}

/// Before a send (PROTOCOL §5f.2): the phrase bundles and the fonts the playlist's oracles name go on the
/// clip first (the clip refuses an oracle whose bundle or body font it lacks), older bundles and Tarot font
/// atlases are cleaned up, and an oracle whose bundle or body font couldn't go is left out of this send.
@MainActor
enum TarotReaderSend {
    static func prepare(_ playlist: Playlist, client: any ClipClient, library: LibraryStore, clipPlaylist: Playlist?) async throws -> Playlist {
        var playlist = playlist
        let names = playlist.oracleReaderIDs
        guard !names.isEmpty || clipPlaylist != nil else { return playlist }
        var fonts: [ReaderFont] = []
        // The fonts as rendered now, at each oracle's size (an older recipe's ids are replaced when this app
        // renders them differently; ids without a size read as Medium).
        for id in playlist.oracleFontIDs {
            let size = TarotFontStore.size(ofFontID: id) ?? .medium
            guard let f = await TarotFontStore.shared.fonts(size) else { continue }
            let now = id.hasPrefix(TarotFonts.bigPrefix) ? f.big : f.body
            if now.id != id { playlist = playlist.replacingOracleFont(id, with: now.id) }
            if !fonts.contains(where: { $0.id == now.id }) { fonts.append(now) }
        }
        let texts = names.compactMap { id in library.readerBundle(textID: id).map { ReaderPusher.Text(id: id, data: $0, title: "Tarot") } }
        let r = try await ReaderPusher(client: client).prepareOracleReaders(playlist, texts: texts, fonts: fonts, keep: clipPlaylist)
        return r.playlist
    }
}

extension Playlist {
    /// Oracle items and entries writing with font `old` (body or big) write with `new` instead.
    func replacingOracleFont(_ old: String, with new: String) -> Playlist {
        var p = self
        for i in p.items.indices where p.items[i].type == .oracle {
            if p.items[i].font == old { p.items[i].font = new }
            if p.items[i].fontBig == old { p.items[i].fontBig = new }
        }
        if var q = p.queue {
            for i in q.indices where q[i].type == .oracle {
                if q[i].font == old { q[i].font = new }
                if q[i].fontBig == old { q[i].fontBig = new }
            }
            p.queue = q
        }
        return p
    }
}
