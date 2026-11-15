import Foundation

// JSON documents of PROTOCOL §5c (Reader mode): `/texts`, `/fonts/{id}`, `/reader`.

/// One entry of `GET /texts`.
public struct ClipText: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var bytes: Int
    public var words: Int
    public var title: String
    /// Where the clip will resume (saved every 50 words and on pause).
    public var progressWord: Int

    enum CodingKeys: String, CodingKey {
        case id, bytes, words, title
        case progressWord = "progress_word"
    }

    public init(id: String, bytes: Int, words: Int, title: String, progressWord: Int) {
        self.id = id; self.bytes = bytes; self.words = words; self.title = title; self.progressWord = progressWord
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
        words = try c.decodeIfPresent(Int.self, forKey: .words) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        progressWord = try c.decodeIfPresent(Int.self, forKey: .progressWord) ?? 0
    }

    /// 0…1 read.
    public var fraction: Double { words > 0 ? min(1, Double(progressWord) / Double(words)) : 0 }
}

public struct TextList: Codable, Sendable, Equatable {
    public var ok: Bool
    public var texts: [ClipText]
    public init(ok: Bool = true, texts: [ClipText]) { self.ok = ok; self.texts = texts }
}

/// One entry of `GET /fonts`: a font's id and a summary of its document.
public struct ClipFontInfo: Codable, Sendable, Equatable {
    public var id: String
    public var glyphs: Int?
    public var cellW: Int?
    public var cellH: Int?
    public var compact: Bool?
    public var large: Bool?

    enum CodingKeys: String, CodingKey {
        case id, glyphs, compact, large
        case cellW = "cell_w"
        case cellH = "cell_h"
    }

    public init(id: String, glyphs: Int? = nil, cellW: Int? = nil, cellH: Int? = nil, compact: Bool? = nil, large: Bool? = nil) {
        self.id = id; self.glyphs = glyphs; self.cellW = cellW; self.cellH = cellH; self.compact = compact; self.large = large
    }

    /// The entry the clip lists for `document` stored under `id`.
    public init(id: String, document d: ReaderFontDocument) {
        self.init(id: id, glyphs: d.normal.glyphs.unicodeScalars.count, cellW: d.normal.cellW, cellH: d.normal.cellH,
                  compact: d.compact != nil, large: d.large != nil)
    }

    /// The clip's font is `document` as far as the list tells: the same glyph count, cell size and faces. An entry
    /// without the summary (a document the clip could not parse) never matches, so that font is sent again.
    public func matches(_ document: ReaderFontDocument) -> Bool {
        self == ClipFontInfo(id: id, document: document)
    }
}

public struct FontList: Codable, Sendable, Equatable {
    public var ok: Bool
    public var fonts: [ClipFontInfo]
    public init(ok: Bool = true, fonts: [ClipFontInfo]) { self.ok = ok; self.fonts = fonts }
}

/// The reader font document (`PUT /fonts/{id}`):
/// `{"glyphs":"ABC…","advance":[…],"cell_w":64,"cell_h":120,"baseline":92,"atlas_white":"…","atlas_accent":"…","compact":{…same keys…}}`.
/// Glyph `i` of both atlases is the i-th code point of `glyphs`; it is drawn with its pen origin at
/// the cell's left edge and its baseline `baseline` px below the cell top; black pixels are transparent.
public struct ReaderFontDocument: Codable, Sendable, Equatable, Hashable {
    public struct Face: Codable, Sendable, Equatable, Hashable {
        public var glyphs: String
        public var advance: [Int]
        public var cellW: Int
        public var cellH: Int
        public var baseline: Int
        public var atlasWhite: String
        public var atlasAccent: String

        enum CodingKeys: String, CodingKey {
            case glyphs, advance, baseline
            case cellW = "cell_w"
            case cellH = "cell_h"
            case atlasWhite = "atlas_white"
            case atlasAccent = "atlas_accent"
        }

        public init(glyphs: String, advance: [Int], cellW: Int, cellH: Int, baseline: Int, atlasWhite: String, atlasAccent: String) {
            self.glyphs = glyphs; self.advance = advance; self.cellW = cellW; self.cellH = cellH
            self.baseline = baseline; self.atlasWhite = atlasWhite; self.atlasAccent = atlasAccent
        }

        /// Code points in atlas order.
        public var codePoints: [UInt32] { glyphs.unicodeScalars.map(\.value) }

        /// Why the clip would refuse this face (`rsvp_font_parse` rules), or nil.
        public var validationProblem: String? {
            let n = glyphs.unicodeScalars.count
            if n == 0 || n > ReaderFontDocument.maxGlyphs { return "glyphs must hold 1–\(ReaderFontDocument.maxGlyphs) code points" }
            if Set(codePoints).count != n { return "glyphs has duplicates" }
            if advance.count != n { return "advance needs one value per glyph" }
            if advance.contains(where: { !(0...1024).contains($0) }) { return "advances are 0–1024" }
            if !(1...ClipCanvas.width).contains(cellW) || !(1...ClipCanvas.height).contains(cellH) { return "cell size out of range" }
            if !(0...cellH).contains(baseline) { return "baseline outside the cell" }
            if !HCA.isValidAssetID(atlasWhite) || !HCA.isValidAssetID(atlasAccent) { return "bad atlas id" }
            return nil
        }
    }

    public var normal: Face
    public var compact: Face?
    /// §5f.11: an optional third, larger face (the Tarot's body font: 1.3× the chosen size); Reader mode ignores it.
    public var large: Face?

    /// `RSVP_MAX_GLYPHS`.
    public static let maxGlyphs = 256
    /// `RSVP_FONT_JSON_MAX`.
    public static let maxJSONBytes = 16_384

    public init(normal: Face, compact: Face?, large: Face? = nil) { self.normal = normal; self.compact = compact; self.large = large }

    enum TopKeys: String, CodingKey { case compact, large }

    public init(from decoder: any Decoder) throws {
        normal = try Face(from: decoder)
        let c = try decoder.container(keyedBy: TopKeys.self)
        compact = try c.decodeIfPresent(Face.self, forKey: .compact)
        large = try c.decodeIfPresent(Face.self, forKey: .large)
    }

    public func encode(to encoder: any Encoder) throws {
        try normal.encode(to: encoder)
        var c = encoder.container(keyedBy: TopKeys.self)
        try c.encodeIfPresent(compact, forKey: .compact)
        try c.encodeIfPresent(large, forKey: .large)
    }

    /// Every atlas the document points at (white before accent, normal before compact), without duplicates.
    public var atlasIDs: [String] {
        var seen = Set<String>()
        return [normal.atlasWhite, normal.atlasAccent, compact?.atlasWhite, compact?.atlasAccent, large?.atlasWhite, large?.atlasAccent]
            .compactMap { $0 }.filter { seen.insert($0).inserted }
    }

    public var validationProblem: String? { normal.validationProblem ?? compact?.validationProblem ?? large?.validationProblem }
}

/// `GET /reader` → `{"ok":true,"text":"id","word":n,"words":N,"paused":bool,"wpm":w}`. `text` is nil
/// when no reader item is on screen.
public struct ReaderStatus: Codable, Sendable, Equatable {
    public var ok: Bool
    public var text: String?
    public var word: Int
    public var words: Int
    public var paused: Bool
    public var wpm: Int

    public init(ok: Bool = true, text: String?, word: Int, words: Int, paused: Bool, wpm: Int) {
        self.ok = ok; self.text = text; self.word = word; self.words = words; self.paused = paused; self.wpm = wpm
    }

    enum CodingKeys: String, CodingKey { case ok, text, word, words, paused, wpm }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        text = try c.decodeIfPresent(String.self, forKey: .text)
        word = try c.decodeIfPresent(Int.self, forKey: .word) ?? 0
        words = try c.decodeIfPresent(Int.self, forKey: .words) ?? 0
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        wpm = try c.decodeIfPresent(Int.self, forKey: .wpm) ?? 0
    }

    public var isReading: Bool { text != nil }
}

/// `POST /reader {"action":"pause"|"resume"|"seek","word":n}`.
public struct ReaderCommand: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case pause, resume, seek }
    public var action: Action
    public var word: Int?
    public init(_ action: Action, word: Int? = nil) { self.action = action; self.word = word }
    public static let pause = ReaderCommand(.pause)
    public static let resume = ReaderCommand(.resume)
    public static func seek(_ word: Int) -> ReaderCommand { ReaderCommand(.seek, word: word) }
}

public enum ReaderLimits {
    /// `PUT /texts` bodies are at most 1 MB.
    public static let maxTextBytes = 1 << 20
}
