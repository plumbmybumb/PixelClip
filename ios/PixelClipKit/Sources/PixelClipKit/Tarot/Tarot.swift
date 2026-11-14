import CoreGraphics
import Foundation
import ImageIO

// The tarot deck and its texts (PROTOCOL §5f "Content"): the 22 trumps of Jean Dodal's Tarot de
// Marseille (Lyon, 1701; public domain, BnF via Wikimedia Commons) and PixelClip's own readings, in French
// and English, each field editable per card and per language.

/// The language of an oracle asset (each asset is one language).
public enum TarotLanguage: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case fr, en

    public var id: String { rawValue }
    public var title: String { self == .fr ? "Français" : "English" }
    /// Frame 0's prompt.
    public var prompt: String { self == .fr ? "la carte attend" : "the card waits" }
    /// Frame 0's hint, under the prompt.
    public var hint: String { self == .fr ? "secoue ou appuie" : "shake or press" }
    /// The question frame's lead-in.
    public var asks: String { self == .fr ? "Le Tarot te demande :" : "The Tarot asks you:" }
}

/// One card's texts as written for PixelClip (an entry of `readings.json`).
public struct TarotReading: Codable, Sendable, Hashable, Identifiable {
    public var index: Int
    /// Roman numeral as printed ("XVII"); empty for Le Mat.
    public var numeral: String
    /// The name as printed on the deck ("LETOILLE"); empty for XIII.
    public var namePrinted: String
    public var nameFR: String
    public var nameEN: String
    public var keywordFR: String
    public var keywordEN: String
    public var readingFR: String
    public var readingEN: String
    public var numberNoteFR: String
    public var numberNoteEN: String
    /// The question the card poses when it is drawn first (sentence mode).
    public var questionFR: String
    public var questionEN: String
    /// The line the question card leaves you with (the sentence reader's closing, PROTOCOL §5f.1).
    public var closingFR: String
    public var closingEN: String

    public var id: Int { index }

    enum CodingKeys: String, CodingKey {
        case index, numeral
        case namePrinted = "name_printed"
        case nameFR = "name_fr", nameEN = "name_en"
        case keywordFR = "keyword_fr", keywordEN = "keyword_en"
        case readingFR = "reading_fr", readingEN = "reading_en"
        case numberNoteFR = "number_note_fr", numberNoteEN = "number_note_en"
        case questionFR = "question_fr", questionEN = "question_en"
        case closingFR = "closing_fr", closingEN = "closing_en"
    }

    public init(index: Int, numeral: String, namePrinted: String, nameFR: String, nameEN: String, keywordFR: String = "",
                keywordEN: String = "", readingFR: String = "", readingEN: String = "", numberNoteFR: String = "", numberNoteEN: String = "",
                questionFR: String = "", questionEN: String = "", closingFR: String = "", closingEN: String = "") {
        self.index = index; self.numeral = numeral; self.namePrinted = namePrinted; self.nameFR = nameFR; self.nameEN = nameEN
        self.keywordFR = keywordFR; self.keywordEN = keywordEN; self.readingFR = readingFR; self.readingEN = readingEN
        self.numberNoteFR = numberNoteFR; self.numberNoteEN = numberNoteEN
        self.questionFR = questionFR; self.questionEN = questionEN
        self.closingFR = closingFR; self.closingEN = closingEN
    }

    /// Every key but `index` may be missing (an empty string then).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String { ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil) ?? "" }
        index = try c.decode(Int.self, forKey: .index)
        numeral = s(.numeral); namePrinted = s(.namePrinted); nameFR = s(.nameFR); nameEN = s(.nameEN)
        keywordFR = s(.keywordFR); keywordEN = s(.keywordEN); readingFR = s(.readingFR); readingEN = s(.readingEN)
        numberNoteFR = s(.numberNoteFR); numberNoteEN = s(.numberNoteEN)
        questionFR = s(.questionFR); questionEN = s(.questionEN)
        closingFR = s(.closingFR); closingEN = s(.closingEN)
    }

    public func name(_ l: TarotLanguage) -> String { l == .fr ? nameFR : nameEN }
    public func keyword(_ l: TarotLanguage) -> String { l == .fr ? keywordFR : keywordEN }
    public func reading(_ l: TarotLanguage) -> String { l == .fr ? readingFR : readingEN }
    public func numberNote(_ l: TarotLanguage) -> String { l == .fr ? numberNoteFR : numberNoteEN }
    public func closing(_ l: TarotLanguage) -> String { l == .fr ? closingFR : closingEN }
    /// The question, or a stand-in until `readings.json` carries one.
    public func question(_ l: TarotLanguage) -> String {
        let q = (l == .fr ? questionFR : questionEN).trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { return q }
        let k = keyword(l).trimmingCharacters(in: .whitespacesAndNewlines)
        if l == .fr { return k.isEmpty ? "Que veux-tu savoir ?" : "Où en es-tu avec : \(k.lowercased()) ?" }
        return k.isEmpty ? "What do you want to know?" : "Where are you with: \(k.lowercased())?"
    }

    /// The name the clip shows: as printed on the card, or the card's name in `l` where nothing is
    /// printed (XIII).
    public func displayName(_ l: TarotLanguage) -> String {
        let p = namePrinted.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? name(l) : p
    }
}

/// The 22 entries of `readings.json` (a top-level array, or an object holding the array).
public struct TarotReadings: Sendable, Hashable {
    public var cards: [TarotReading]

    public init(cards: [TarotReading]) { self.cards = cards.sorted { $0.index < $1.index } }

    public init(data: Data) throws {
        if let list = try? JSONDecoder().decode([TarotReading].self, from: data) {
            self.init(cards: list)
            return
        }
        struct Wrapped: Decodable {
            var list: [TarotReading]
            struct Key: CodingKey {
                var stringValue: String; var intValue: Int?
                init?(stringValue: String) { self.stringValue = stringValue }
                init?(intValue: Int) { return nil }
            }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: Key.self)
                for k in ["cards", "readings", "entries", "trumps"] {
                    if let key = Key(stringValue: k), let l = try? c.decode([TarotReading].self, forKey: key) { list = l; return }
                }
                for key in c.allKeys {
                    if let l = try? c.decode([TarotReading].self, forKey: key) { list = l; return }
                }
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "No array of readings"))
            }
        }
        self.init(cards: try JSONDecoder().decode(Wrapped.self, from: data).list)
    }

    public subscript(_ index: Int) -> TarotReading? { cards.first { $0.index == index } }
}

/// What the person changed on one card in one language (nil fields: the original text).
public struct TarotCardEdit: Codable, Sendable, Hashable {
    public var name: String?
    public var keyword: String?
    public var reading: String?
    public var note: String?
    public var question: String?
    /// The sentence reader's closing line (it goes into the phrase bundle's `card.<i>.closing`).
    public var closing: String?

    public init(name: String? = nil, keyword: String? = nil, reading: String? = nil, note: String? = nil, question: String? = nil,
                closing: String? = nil) {
        self.name = name; self.keyword = keyword; self.reading = reading; self.note = note; self.question = question
        self.closing = closing
    }

    public var isEmpty: Bool { name == nil && keyword == nil && reading == nil && note == nil && question == nil && closing == nil }
}

/// The person's edits, per card and per language, kept on the iPhone (`Codable`).
public struct TarotEdits: Codable, Sendable, Hashable {
    /// `"<index>-<lang>"` → edit.
    public var edits: [String: TarotCardEdit]

    public init(edits: [String: TarotCardEdit] = [:]) { self.edits = edits }
    public static let none = TarotEdits()

    static func key(_ card: Int, _ l: TarotLanguage) -> String { "\(card)-\(l.rawValue)" }

    public subscript(card: Int, language: TarotLanguage) -> TarotCardEdit {
        get { edits[Self.key(card, language)] ?? TarotCardEdit() }
        set { edits[Self.key(card, language)] = newValue.isEmpty ? nil : newValue }
    }

    /// The card has edits in either language.
    public func isEdited(_ card: Int) -> Bool { TarotLanguage.allCases.contains { !self[card, $0].isEmpty } }

    /// "Restore the original": both languages.
    public mutating func restore(_ card: Int) { for l in TarotLanguage.allCases { self[card, l] = TarotCardEdit() } }

    /// The edits that matter for `language` (fingerprints).
    public func filtered(_ language: TarotLanguage) -> [String: TarotCardEdit] {
        edits.filter { $0.key.hasSuffix("-\(language.rawValue)") }
    }
}

/// One card's texts as the clip shows them in one language (originals with the edits applied).
public struct TarotCardText: Sendable, Hashable {
    public var index: Int
    public var numeral: String
    public var name: String
    public var keyword: String
    public var reading: String
    public var note: String
    public var question: String
    /// The sentence reader's closing (§5f.1).
    public var closing: String

    public init(index: Int, numeral: String, name: String, keyword: String, reading: String, note: String, question: String = "",
                closing: String = "") {
        self.index = index; self.numeral = numeral; self.name = name; self.keyword = keyword; self.reading = reading; self.note = note
        self.question = question; self.closing = closing
    }

    /// The original, with `edit` laid over it.
    public init(_ r: TarotReading, language l: TarotLanguage, edit: TarotCardEdit = TarotCardEdit()) {
        self.init(index: r.index, numeral: r.numeral, name: edit.name ?? r.displayName(l), keyword: edit.keyword ?? r.keyword(l),
                  reading: edit.reading ?? r.reading(l), note: edit.note ?? r.numberNote(l), question: edit.question ?? r.question(l),
                  closing: edit.closing ?? r.closing(l))
    }

    /// The number note as the thread shows it: the numeral first ("II · accumuler, préparer"). Notes
    /// that already lead with their numeral (or "Le Mat ·") are kept as written.
    public var threadNote: String {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let num = numeral.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return num.isEmpty ? name : num }
        if n.prefix(16).contains("·") || num.isEmpty || n.hasPrefix(num + " ") { return n }
        return "\(num) · \(n)"
    }

    /// The numeral as it goes on the face ("0" stands in for Le Mat's blank).
    public var shownNumeral: String {
        let n = numeral.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "0" : n
    }
}

extension TarotReadings {
    /// Every card's texts in `language`, with `edits` applied.
    public func texts(_ language: TarotLanguage, edits: TarotEdits = .none) -> [TarotCardText] {
        cards.map { TarotCardText($0, language: language, edit: edits[$0.index, language]) }
    }
}

/// The deck's pictures: the 22 faces (`NN-<slug>.png`, 236×448) and the back (`back.png`).
public struct TarotDeck: @unchecked Sendable {
    public var faces: [CGImage]
    public var back: CGImage
    /// Source size of every picture.
    public static let sourceSize = CGSize(width: 236, height: 448)

    public enum Error: Swift.Error, Equatable { case missing(String), unreadable(String) }

    public init(faces: [CGImage], back: CGImage) { self.faces = faces; self.back = back }

    /// Loads `back.png` and the faces `00-…png`, `01-…png`, … (in index order, matched by their
    /// two-digit prefix) from `folder`.
    public init(folder: URL, cards: Int = 22) throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        func image(_ name: String) throws -> CGImage {
            let url = folder.appendingPathComponent(name)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw Error.unreadable(name) }
            return img
        }
        var faces: [CGImage] = []
        for i in 0..<cards {
            let prefix = String(format: "%02d-", i)
            guard let name = names.filter({ $0.hasPrefix(prefix) && $0.lowercased().hasSuffix(".png") }).sorted().first else {
                throw Error.missing("\(prefix)*.png")
            }
            faces.append(try image(name))
        }
        guard names.contains("back.png") else { throw Error.missing("back.png") }
        self.init(faces: faces, back: try image("back.png"))
    }
}

/// Everything the Tarot extra lets the person choose, saved with the library item (its recipe). §5f.6: no mode, no card of
/// the day (older recipes' `mode` / `daily` are read and ignored).
public struct TarotSpec: Codable, Sendable, Hashable {
    public var language: TarotLanguage
    /// The edits in this language only.
    public var edits: [String: TarotCardEdit]
    /// §5f.3: how big the clip writes (the body and numeral atlases).
    public var textSize: TarotTextSize

    public init(language: TarotLanguage = .fr, edits: TarotEdits = .none, textSize: TarotTextSize = .large) {
        self.language = language; self.edits = edits.filtered(language); self.textSize = textSize
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decodeIfPresent(TarotLanguage.self, forKey: .language) ?? .fr
        edits = try c.decodeIfPresent([String: TarotCardEdit].self, forKey: .edits) ?? [:]
        textSize = try c.decodeIfPresent(TarotTextSize.self, forKey: .textSize) ?? .large
    }

    enum CodingKeys: String, CodingKey { case language, edits, textSize }

    public var name: String { language == .fr ? "Tarot" : "Tarot (English)" }
}
