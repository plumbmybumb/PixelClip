import Foundation

// Oracle (tarot) (PROTOCOL §5f): the phone renders every frame (the card face down, then for each card
// its face and its reading pages); the clip waits, shuffles, turns the pages and picks the card.

/// Contract constants, limits and the frame index helpers.
public enum Oracle {
    /// `cards` 1–78, `pages` 1–3 (the asset's frame count must match).
    public static let cardsRange = 1...78
    public static let pagesRange = 1...3
    /// `face_ms` default (§5f.3: 0, nothing advances by itself; a non-zero value still auto-advances).
    public static let defaultFaceMs = 0
    /// `page_ms` default (§5f.3: 0, pages turn on a tap only).
    public static let defaultPageMs = 0
    /// `hold_ms` default: the idle timeout (§5f.3): no tap or shake for 5 minutes and the clip goes back to
    /// waits from any screen (0 = never).
    public static let defaultHoldMs = 300_000
    /// `shake_g` default and range (the IMU's decaying-peak metric, as the `balls` scene's kicks).
    public static let defaultShakeG = 0.9
    public static let shakeGRange = 0.4...2.0
    /// How long an oracle takes its turn next to the playlist's items (and as a one-off): three minutes,
    /// since the clip cuts a reading off at the item's end and a three-card sentence runs ~1 min 40 s
    /// before its hold.
    public static let rotationMs = 180_000

    /// The shuffle: 1.2 s of face frames at random, 12 fps, ending on the chosen card.
    public static let shuffleMs = 1_200
    public static let shuffleFps = 12

    // MARK: Assets (§5f "Assets")
    // D, K and N carry the glyph-atlas flag (their frames are pieces the clip pastes, not screens; the
    // clip's storage takes non-536×240 files only as atlases); T is a normal 536×240 asset.

    /// The deck `D`: §5f.12 108×206 (the card's ratio, leaving room for the keyword row under the three cards), frame
    /// 0 the back, 1+i card i (shared between languages). Its library id carries the size
    /// (`tarot-dodal-dk108-…`), so a deck of another size is never taken for this one.
    public static let cardWidth = 108, cardHeight = 206
    public static let deckIDPart = "dk108"
    public static func isCurrentDeckID(_ id: String) -> Bool { id.hasPrefix("tarot-dodal-\(deckIDPart)-") }
    /// The text asset `T`: 536×240; every frame leaves the card slot black.
    public static let slot = PlaylistItem.Window(x: 40, y: 21, w: 104, h: 198)
    /// The keys `K`: §5f.12 160×34, frame i = card i's keyword.
    public static let keyWidth = 160, keyHeight = 34
    /// §5f.12: the keyword's ink stays in a 140×28 box at (10, 2) in its tile.
    public static let keyInkWidth = 140, keyInkHeight = 28
    public static var keyInkBox: (x: Int, y: Int, w: Int, h: Int) { (10, 2, keyInkWidth, keyInkHeight) }
    /// The notes `N`: 536×72, frame i = card i's number note.
    public static let noteWidth = 536, noteHeight = 72

    /// §5f.12 *three* / *hold* / *shuffle*: cards A, B, C at y 0, x 52, 214, 376 in both orientations; their keywords
    /// `K` (160×34) at y 206, x 26, 188, 350 (centres 106, 268, 430; not on the shuffle).
    public static let threeCardX = [52, 214, 376]
    public static let threeCardY = 0
    public static let threeKeyX = [26, 188, 350]
    public static let threeKeyY = 206
    /// §5f.12 *waits* / *armed* / *detail*: the back or the card at y 17 (vertically centred), at the end away from the
    /// BOOT corner: x 8 normally, x 420 flipped.
    public static func singleCardX(flipped: Bool) -> Int { flipped ? 420 : 8 }
    public static let singleCardY = 17
    /// The *thread*: the three notes stacked at these y (x 0).
    public static let threadY = [12, 84, 156]

    public static func deckFrames(cards: Int) -> Int { 1 + cards }
    public static func textFrames(cards: Int, pages: Int) -> Int { 1 + cards * (2 + pages) }
    public static func keyFrames(cards: Int) -> Int { cards }
    public static func noteFrames(cards: Int) -> Int { cards }

    /// `T[0]`: waits.
    public static let waitsFrame = 0
    /// `base(i) = 1 + i × (2 + pages)`.
    public static func base(_ card: Int, pages: Int) -> Int { 1 + card * (2 + pages) }
    /// `F(i) = base(i)`: the face info (numeral, printed name, keyword).
    public static func face(_ card: Int, pages: Int) -> Int { base(card, pages: pages) }
    /// `Q(i) = base(i) + 1`: the question the card poses.
    public static func question(_ card: Int, pages: Int) -> Int { base(card, pages: pages) + 1 }
    /// `R(i, p) = base(i) + 2 + p`: reading page p.
    public static func reading(_ card: Int, _ page: Int, pages: Int) -> Int { base(card, pages: pages) + 2 + page }

    /// Cards in a text asset of `frames` frames with `pages` reading pages per card (nil when it can't be one).
    public static func cards(textFrames frames: Int, pages: Int) -> Int? {
        guard pagesRange.contains(pages), frames > 1, (frames - 1) % (2 + pages) == 0 else { return nil }
        let n = (frames - 1) / (2 + pages)
        return cardsRange.contains(n) ? n : nil
    }

    /// FNV-1a, 32 bit (offset basis 2166136261, prime 16777619), over UTF-8 bytes.
    public static func fnv1a(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for b in bytes {
            h ^= UInt32(b)
            h = h &* 16_777_619
        }
        return h
    }
}

/// The composer's mode, as the C engine's API still has it (`orr_mode_t`); since §5f.6 the clip only reads three-card
/// sentences (no question card, no card of the day), so the app always passes `.sentence` with q = −1.
public enum OracleMode: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case sentence, day

    public var id: String { rawValue }

    /// Unknown future modes read as sentence (the default).
    public init(from decoder: any Decoder) throws {
        self = OracleMode(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .sentence
    }
}

/// `/status.oracle.state` (§5f.7, §5f.8).
public enum OracleState: String, Codable, Sendable, Hashable, CaseIterable {
    case waits
    /// §5f.8: tapped on waits; a shake (or a tap) deals, a double-tap disarms.
    case armed
    case shuffle, three, hold
    /// The lean screens (by card, by position, by the numbers, together, and), `page` 0–4.
    case lean
    /// A card's one-page detail, `page` 0–2, `card` the card.
    case detail

    /// Unknown (and retired) states read as waits.
    public init(from decoder: any Decoder) throws {
        self = OracleState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .waits
    }
}

/// `POST /oracle/draw {"cards":[a,b,c]}` (§5f.6; body optional; `cards`, three distinct 0-based cards, forces the row).
public struct OracleDrawRequest: Codable, Sendable, Equatable {
    public var cards: [Int]?
    public init(cards: [Int]? = nil) { self.cards = cards }
}

/// What the clip needs to show an oracle (the `oracle` playlist item without its timing).
public struct OracleItem: Codable, Sendable, Hashable {
    /// §5f.2: the phrase bundle's `/texts` id (`tarot-reader-<lang>-<hash>`), the item's identity on the clip
    /// (the clip writes every text screen from it; `reader` on the wire is the same id, kept one release).
    public var id: String
    /// The deck `D` and the keys `K` (§5f.7: no notes asset any more, the thread is gone).
    public var deck: String
    public var keys: String?
    public var cards: Int
    public var shakeG: Double
    public var faceMs: Int
    public var pageMs: Int
    public var holdMs: Int
    /// The body font (`/fonts` id, `tarot-font-<hash>`): the waits prompt, the face's name and keyword, the
    /// question, the reading pages and the typed paragraph. Required by the clip.
    public var font: String?
    /// The numeral's font (`tarot-big-<hash>`, the same face at ~60 px); optional, the clip falls back to `font`.
    public var fontBig: String?
    /// The app's library item this oracle was made as (stable across edits; never sent).
    public var libraryID: String?

    public init(id: String, deck: String, keys: String? = nil, cards: Int = 22,
                shakeG: Double = Oracle.defaultShakeG, faceMs: Int = Oracle.defaultFaceMs,
                pageMs: Int = Oracle.defaultPageMs, holdMs: Int = Oracle.defaultHoldMs, font: String? = nil, fontBig: String? = nil,
                libraryID: String? = nil) {
        self.id = id; self.deck = deck; self.keys = keys
        self.cards = cards; self.shakeG = shakeG
        self.faceMs = faceMs; self.pageMs = pageMs; self.holdMs = holdMs
        self.font = font; self.fontBig = fontBig; self.libraryID = libraryID
    }

    /// The bundle's `/texts` id (the same as `id` since §5f.2).
    public var reader: String { id }
    /// The clip can write its screens (it names a body font).
    public var hasReader: Bool { font != nil }
    /// The app's key for it: its library item, else its id.
    public var libraryKey: String { libraryID ?? id }

    /// From an `oracle` playlist item (defaults for missing keys); nil for other types or without its deck.
    public init?(item: PlaylistItem) {
        guard item.type == .oracle, let id = item.id, let deck = item.deck else { return nil }
        self.init(id: id, deck: deck, keys: item.keys, cards: item.cards ?? 22,
                  shakeG: item.shakeG ?? Oracle.defaultShakeG,
                  faceMs: item.faceMs ?? Oracle.defaultFaceMs, pageMs: item.pageMs ?? Oracle.defaultPageMs,
                  holdMs: item.holdMs ?? Oracle.defaultHoldMs, font: item.font, fontBig: item.fontBig)
    }

    /// The playlist item, timed for rotating with the playlist (the composer holds it when alone).
    public func playlistItem(durationMs: Int = Oracle.rotationMs, transition: Transition? = .fade) -> PlaylistItem {
        .oracle(self, durationMs: durationMs, transition: transition)
    }

    /// Every asset the item needs (the bundle is a `/texts` document, the fonts `/fonts` documents).
    public var assetIDs: [String] { [deck] + [keys].compactMap { $0 } }
    /// Every font it names.
    public var fontIDs: [String] { [font, fontBig].compactMap { $0 } }

    /// §5f.6: a row of three distinct cards needs at least 3.
    public static let minCards = 3

    /// `tarot-<deck>-<lang>[-<part>]-xxxx`: ASCII, ≤ 32 characters, a valid asset id not in `existing`.
    /// `part` is `deck` (no language), `keys` or `notes`; nil for the text asset.
    public static func makeID(deck: String = "dodal", language: String?, part: String? = nil, existing: Set<String>) -> String {
        var rng = SystemRandomNumberGenerator()
        return makeID(deck: deck, language: language, part: part, existing: existing, using: &rng)
    }

    public static func makeID<R: RandomNumberGenerator>(deck: String = "dodal", language: String?, part: String? = nil,
                                                        existing: Set<String>, using rng: inout R) -> String {
        func slug(_ s: String) -> String { String(s.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }.map(Character.init)) }
        var base = "tarot-\(slug(deck).prefix(8))"
        if let language { base += "-\(slug(language).prefix(4))" }
        if let part { base += "-\(slug(part).prefix(6))" }
        while true {
            let hex = String(UInt16.random(in: 0...UInt16.max, using: &rng), radix: 16)
            let id = "\(base)-\(String(repeating: "0", count: max(0, 4 - hex.count)))\(hex)"
            if !existing.contains(id) && HCA.isValidAssetID(id) { return id }
        }
    }
}
