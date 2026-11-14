import Foundation

// Reader mode (PROTOCOL §5c): the word segmentation the clip uses for its word index. A line-for-line
// port of `core/src/rsvp_tok.c` (classes, UTF-8 decoding with invalid bytes as one glyph each,
// dash/no-break-space rules, 32-glyph split, paragraph detection, title break), so a word index on
// the phone (chapters, progress bars, "start here") is the same number the clip stores.

/// One word as the clip shows it.
public struct RSVPWord: Sendable, Hashable {
    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// Ends with `,` `;` (or a dash): +50 %.
        public static let comma = Flags(rawValue: 1 << 0)
        /// Ends a sentence (`.` `!` `?` `…`): +100 % (wins over comma).
        public static let sentence = Flags(rawValue: 1 << 1)
        /// Followed by a paragraph break: a 300 ms blank after it.
        public static let paragraph = Flags(rawValue: 1 << 2)
    }

    /// Byte offset of the word's first byte in the text.
    public var offset: Int
    /// Length in bytes.
    public var byteCount: Int
    /// Code points (an invalid byte sequence counts as one), 1…32.
    public var glyphs: Int
    /// Glyphs before the first letter/digit.
    public var lead: Int
    /// Glyphs from the first to the last letter/digit; 0 when there is none.
    public var core: Int
    public var flags: Flags
    /// The word's text (invalid bytes become U+FFFD here; the clip draws its `?` glyph).
    public var text: String

    public init(offset: Int, byteCount: Int, glyphs: Int, lead: Int, core: Int, flags: Flags, text: String) {
        self.offset = offset; self.byteCount = byteCount; self.glyphs = glyphs; self.lead = lead
        self.core = core; self.flags = flags; self.text = text
    }

    /// The length that drives timing and the ORP: the core, or every glyph for a word without letters.
    public var length: Int { core > 0 ? core : glyphs }

    /// Index (in glyphs) of the optimal recognition point: `lead + ORP(core)`, clamped.
    public var orp: Int {
        guard glyphs > 0 else { return 0 }
        let i = core > 0 ? lead + ORP.index(forLength: core) : ORP.index(forLength: glyphs)
        return min(i, glyphs - 1)
    }
}

/// The Spritz rule: length 1 → 0, 2–5 → 1, 6–9 → 2, 10–13 → 3, else 4 (in glyphs).
public enum ORP {
    public static func index(forLength n: Int) -> Int {
        switch n {
        case ...1: 0
        case 2...5: 1
        case 6...9: 2
        case 10...13: 3
        default: 4
        }
    }
}

/// A tokenised text plus its title.
public struct RSVPText: Sendable {
    /// Longer words are split into pieces of this many glyphs (`RSVP_WORD_MAX_GLYPHS`).
    public static let maxWordGlyphs = 32

    public let title: String
    public let words: [RSVPWord]

    /// A text file as uploaded with `PUT /texts/{id}`: the first line is the title and is read first,
    /// followed by a paragraph pause (the clip tokenises with `RSVP_TOK_TITLE_BREAK`).
    public init(file: String) {
        self.init(fileData: Data(file.utf8))
    }

    public init(fileData: Data) {
        title = Self.title(of: fileData)
        words = Self.tokenize(fileData, titleBreak: true)
    }

    /// A body with no title line (previews of a fragment).
    public init(body: String, title: String = "") {
        self.title = title
        words = Self.tokenize(Data(body.utf8), titleBreak: false)
    }

    public var wordCount: Int { words.count }

    /// Total reading time at `wpm` (sum of the per-word times and paragraph blanks).
    public func durationMs(wpm: Int, from start: Int = 0) -> Int {
        guard start < words.count else { return 0 }
        return words[max(0, start)...].reduce(0) { $0 + RSVPTiming.slotMs($1, wpm: wpm) }
    }

    /// Minutes as the clip's end card words them (`rsvp_minutes(rsvp_total_ms(...))`).
    public func estimatedMinutes(wpm: Int) -> Int {
        RSVPTiming.minutes(totalMs: RSVPTiming.totalMs(words, wpm: wpm))
    }

    // MARK: Character classes (rsvp__class)

    enum CharClass: UInt8 {
        case letter, punct, sentence, pause, close, dash, join, space, newline, paragraphSeparator
    }

    /// Code point reported for an invalid byte sequence.
    static let invalid: UInt32 = 0x110000

    static func charClass(_ cp: UInt32) -> CharClass {
        if cp < 0x80 {
            if cp == 0x0A || cp == 0x0B || cp == 0x0C || cp == 0x0D { return .newline }
            if cp <= 0x20 || cp == 0x7F { return .space }
            if (0x30...0x39).contains(cp) || (0x61...0x7A).contains(cp | 0x20) { return .letter }
            switch cp {
            case 0x2E, 0x21, 0x3F: return .sentence                          // . ! ?
            case 0x2C, 0x3B: return .pause                                    // , ;
            case 0x29, 0x5D, 0x7D, 0x22, 0x27: return .close                  // ) ] } " '
            default: return .punct
            }
        }
        if cp == invalid { return .letter }
        if cp < 0xA0 { return cp == 0x85 ? .newline : .space }
        if cp == 0xA0 { return .join }
        if cp <= 0xBF {
            switch cp {
            case 0xAA, 0xB2, 0xB3, 0xB5, 0xB9, 0xBA, 0xBC, 0xBD, 0xBE: return .letter   // ª ² ³ µ ¹ º ¼ ½ ¾
            case 0xBB: return .close                                                     // »
            default: return .punct
            }
        }
        if cp == 0xD7 || cp == 0xF7 { return .punct }
        if cp < 0x1680 { return .letter }
        if cp == 0x1680 { return .space }
        if (0x2000...0x206F).contains(cp) {
            if cp == 0x2007 || cp == 0x202F { return .join }
            if cp <= 0x200B || cp == 0x205F { return .space }
            if cp == 0x2028 { return .newline }
            if cp == 0x2029 { return .paragraphSeparator }
            if (0x2013...0x2015).contains(cp) { return .dash }
            if cp == 0x2019 || cp == 0x201D || cp == 0x203A { return .close }           // ’ ” ›
            if cp == 0x2026 || cp == 0x203C || (0x2047...0x2049).contains(cp) { return .sentence }
            if cp >= 0x2060 { return .space }
            return .punct
        }
        if (0x2E00...0x2E7F).contains(cp) { return .punct }
        if (0x3000...0x303F).contains(cp) {
            if cp == 0x3000 { return .space }
            if cp == 0x3001 { return .pause }
            if cp == 0x3002 { return .sentence }
            if (0x3008...0x3011).contains(cp) && cp & 1 == 1 { return .close }
            return .punct
        }
        if cp == 0xFEFF { return .space }
        if (0xFF01...0xFF65).contains(cp) {
            switch cp {
            case 0xFF01, 0xFF0E, 0xFF1F: return .sentence
            case 0xFF0C, 0xFF1B: return .pause
            case 0xFF09, 0xFF3D, 0xFF5D: return .close
            default: break
            }
            if (0xFF10...0xFF19).contains(cp) || (0xFF21...0xFF3A).contains(cp) || (0xFF41...0xFF5A).contains(cp) { return .letter }
            return .punct
        }
        return .letter
    }

    /// True for code points the clip draws as a space (no glyph, the font's space advance).
    static func drawsAsSpace(_ cp: UInt32) -> Bool {
        if cp == 0x20 { return true }
        switch charClass(cp) {
        case .join, .space, .newline, .paragraphSeparator: return true
        default: return false
        }
    }

    // MARK: UTF-8 (rsvp__u8_step)

    /// One decoded glyph: code point (or `invalid`), byte start and length.
    struct Glyph { var cp: UInt32; var start: Int; var len: Int }

    /// Decodes like the clip: a broken sequence is one invalid glyph covering the bytes read so far.
    static func glyphs(_ bytes: UnsafeBufferPointer<UInt8>) -> [Glyph] {
        var out: [Glyph] = []
        out.reserveCapacity(bytes.count)
        var need = 0, cp: UInt32 = 0, minCP: UInt32 = 0, start = 0, len = 0
        for (pos, b) in bytes.enumerated() {
            if need > 0 {
                if b & 0xC0 == 0x80 {
                    cp = (cp << 6) | UInt32(b & 0x3F)
                    len += 1
                    need -= 1
                    if need == 0 {
                        let ok = cp >= minCP && cp <= 0x10FFFF && !(0xD800...0xDFFF).contains(cp)
                        out.append(Glyph(cp: ok ? cp : invalid, start: start, len: len))
                    }
                    continue
                }
                out.append(Glyph(cp: invalid, start: start, len: len))
                need = 0
            }
            switch b {
            case 0..<0x80: out.append(Glyph(cp: UInt32(b), start: pos, len: 1))
            case 0xC2...0xDF: need = 1; cp = UInt32(b & 0x1F); minCP = 0x80; start = pos; len = 1
            case 0xE0...0xEF: need = 2; cp = UInt32(b & 0x0F); minCP = 0x800; start = pos; len = 1
            case 0xF0...0xF4: need = 3; cp = UInt32(b & 0x07); minCP = 0x10000; start = pos; len = 1
            default: out.append(Glyph(cp: invalid, start: pos, len: 1))
            }
        }
        if need > 0 { out.append(Glyph(cp: invalid, start: start, len: len)) }
        return out
    }

    // MARK: Tokeniser (rsvp_tok_*)

    /// Words of `data`. `titleBreak`: the first line break also counts as a paragraph break.
    public static func tokenize(_ data: Data, titleBreak: Bool) -> [RSVPWord] {
        let bytes = [UInt8](data)
        return bytes.withUnsafeBufferPointer { buf in tokenize(buf, titleBreak: titleBreak) }
    }

    static func tokenize(_ buf: UnsafeBufferPointer<UInt8>, titleBreak: Bool) -> [RSVPWord] {
        var out: [RSVPWord] = []
        var inWord = false
        var wGlyphs = 0, wFirst = 0, wLast = 0, wOff = 0, wEnd = 0
        var wTerm = CharClass.letter
        var wHasLetter = false
        var nl = 0
        var prevCR = false, seenNL = false
        var pending: RSVPWord?

        func text(_ off: Int, _ end: Int) -> String {
            String(decoding: UnsafeBufferPointer(rebasing: buf[off..<end]), as: UTF8.self)
        }
        func endWord() {
            var flags: RSVPWord.Flags = []
            if wTerm == .sentence { flags = .sentence } else if wTerm == .pause || wTerm == .dash { flags = .comma }
            pending = RSVPWord(offset: wOff, byteCount: wEnd - wOff, glyphs: wGlyphs,
                               lead: wHasLetter ? wFirst : 0, core: wHasLetter ? wLast - wFirst + 1 : 0,
                               flags: flags, text: text(wOff, wEnd))
            inWord = false
            nl = 0
        }
        func countNewline(_ n: Int) {
            var n = n
            if titleBreak && !seenNL { n += 1 }
            seenNL = true
            nl = min(nl + n, 200)
        }

        for g in glyphs(buf) {
            let cls = charClass(g.cp)
            if cls == .space || cls == .newline || cls == .paragraphSeparator {
                if inWord { endWord() }
                if cls == .newline {
                    let crlf = g.cp == 0x0A && prevCR
                    prevCR = g.cp == 0x0D
                    if !crlf { countNewline(1) }
                } else {
                    prevCR = false
                    if cls == .paragraphSeparator { countNewline(2) }
                }
                continue
            }
            prevCR = false
            if inWord && wGlyphs >= maxWordGlyphs { endWord() }
            if !inWord {
                if var p = pending {
                    if nl >= 2 { p.flags.insert(.paragraph) }
                    out.append(p)
                    pending = nil
                }
                inWord = true
                wOff = g.start
                wGlyphs = 0
                wHasLetter = false
                wFirst = 0; wLast = 0
                wTerm = .letter
                nl = 0
            }
            let idx = wGlyphs
            wGlyphs += 1
            wEnd = g.start + g.len
            if cls == .letter {
                if !wHasLetter { wHasLetter = true; wFirst = idx }
                wLast = idx
            }
            if cls != .close && cls != .join { wTerm = cls }   // "!\u{A0}»" ends a sentence
            if cls == .dash { endWord() }
        }
        if inWord { endWord() }
        if let p = pending { out.append(p) }
        return out
    }

    /// The title: the first line (a leading BOM and surrounding whitespace removed), as `rsvp_title`
    /// returns it (without its 63-byte buffer limit).
    public static func title(of data: Data) -> String {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        if let end = bytes.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) { bytes = Array(bytes[..<end]) }
        let gs = bytes.withUnsafeBufferPointer { glyphs($0) }
        var out = String.UnicodeScalarView()
        var lastInk = 0
        var started = false
        for g in gs {
            let cls = charClass(g.cp)
            var space = cls == .space || cls == .join || cls == .newline || cls == .paragraphSeparator
            if !started && space { continue }
            started = true
            let scalar: Unicode.Scalar
            if g.cp == invalid { scalar = "?" } else if g.cp < 0x20 || g.cp == 0x7F { scalar = " "; space = true } else {
                scalar = Unicode.Scalar(g.cp) ?? "?"
            }
            out.append(scalar)
            if !space { lastInk = out.count }
        }
        return String(String.UnicodeScalarView(out.prefix(lastInk)))
    }
}
