import Foundation

/// A text saved in the app's Reader: its metadata, chapter starts as word indices of the clip's own
/// index, and the exact file `PUT /texts/{id}` sends (the body itself lives in a file next to it).
public struct ReaderDocument: Codable, Sendable, Identifiable, Hashable {
    public struct Chapter: Codable, Sendable, Hashable {
        public var title: String
        /// Index of the chapter's first word in the clip file (title words included).
        public var word: Int
        public init(title: String, word: Int) { self.title = title; self.word = word }
    }

    public var id: String
    public var title: String
    public var kind: ImportedText.Kind
    public var origin: String?
    public var sourceURL: URL?
    public var addedAt: Date
    /// Words in the clip file (the title line is read first).
    public var wordCount: Int
    public var chapters: [Chapter]
    /// Where the phone thinks the reading is (the preview's position, or the clip's last progress).
    public var position: Int
    /// `text-<10 hex of SHA-256>` of the clip file.
    public var clipTextID: String
    public var byteCount: Int
    /// The body was cut to fit the clip's 1 MB limit.
    public var truncated: Bool

    public init(id: String, title: String, kind: ImportedText.Kind, origin: String?, sourceURL: URL?, addedAt: Date, wordCount: Int,
                chapters: [Chapter], position: Int, clipTextID: String, byteCount: Int, truncated: Bool) {
        self.id = id; self.title = title; self.kind = kind; self.origin = origin; self.sourceURL = sourceURL; self.addedAt = addedAt
        self.wordCount = wordCount; self.chapters = chapters; self.position = position; self.clipTextID = clipTextID
        self.byteCount = byteCount; self.truncated = truncated
    }

    /// 0…1.
    public var fraction: Double { wordCount > 0 ? min(1, Double(position) / Double(wordCount)) : 0 }

    public func minutes(wpm: Int) -> Int { max(1, Int((Double(wordCount) / Double(max(1, wpm))).rounded())) }

    /// The chapter containing `word`.
    public func chapter(at word: Int) -> Chapter? { chapters.last { $0.word <= word } }

    /// Builds the document and its clip file from an import: `title\nbody`, the title on one line,
    /// cut at a paragraph so the file stays within 1 MB.
    public static func make(_ t: ImportedText, id: String = UUID().uuidString, now: Date = Date()) -> (ReaderDocument, Data) {
        let title = t.title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = title.isEmpty ? TextImporter.firstWords(t.body) : title
        let head = Data((safeTitle + "\n").utf8)
        var body = Data(t.body.utf8)
        var truncated = false
        let room = ReaderLimits.maxTextBytes - head.count
        if body.count > room {
            truncated = true
            // Last paragraph break before the limit (else the last space, else a code-point boundary).
            let cut = body.prefix(room)
            if let r = cut.range(of: Data("\n\n".utf8), options: .backwards) { body = cut.prefix(upTo: r.lowerBound) }
            else if let sp = cut.lastIndex(of: 0x20) { body = cut.prefix(upTo: sp) }
            else {
                var end = cut.endIndex
                while end > cut.startIndex, cut[end - 1] & 0xC0 == 0x80 { end -= 1 }
                body = cut.prefix(upTo: max(cut.startIndex, end - 1))
            }
            body = Data(body)
        }
        let file = head + body
        let words = RSVPText.tokenize(file, titleBreak: true)
        let chapters: [Chapter] = t.chapters.compactMap { c in
            let off = head.count + c.offset
            guard off < file.count, let w = Self.firstWord(atOrAfter: off, in: words) else { return nil }
            return Chapter(title: c.title, word: w)
        }
        let doc = ReaderDocument(id: id, title: safeTitle, kind: t.kind, origin: t.origin, sourceURL: t.sourceURL, addedAt: now,
                                 wordCount: words.count, chapters: chapters, position: 0, clipTextID: clipID(file),
                                 byteCount: file.count, truncated: truncated)
        return (doc, file)
    }

    public static func clipID(_ file: Data) -> String { "text-\(Hashing.sha256Hex(file).prefix(10))" }

    static func firstWord(atOrAfter offset: Int, in words: [RSVPWord]) -> Int? {
        var lo = 0, hi = words.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if words[mid].offset < offset { lo = mid + 1 } else { hi = mid }
        }
        return lo < words.count ? lo : nil
    }
}
