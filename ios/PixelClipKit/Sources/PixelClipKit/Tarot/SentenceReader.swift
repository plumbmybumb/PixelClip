import Foundation

/// The Oracle's sentence reader (PROTOCOL §5f.1 v3, §5f.6 no question card, §5f.7 the lean draw): what a
/// practised reader of the book would say about a three-card row, generated from the book's rules over a phrase
/// bundle (one UTF-8 text per language, ~85 KB): the five lean screens and the full paragraph (at most `textMax`
/// bytes).
///
/// A line-for-line port of `core/src/oracle_reader.c` (`orr_compose`, `orr_compose_lean`; the contract is
/// `core/include/oracle_reader.h`): the same bundle and row give the same **bytes** on the clip and on the phone.
/// The shared cases are `core/fixtures/tarot/cases.json` and `cases-lean.json`; `SentenceReaderTests` replays every
/// one of them byte for byte.
///
/// **Bundle.** Lines split on LF (a trailing CR is dropped). Ignored: blank lines (spaces / tabs only),
/// lines before the first header, lines longer than `lineMax` bytes, lines that aren't valid UTF-8, lines
/// with a control byte other than TAB. `[name]` starts a section (a repeated header adds to it). Phrase
/// sections hold one variant per line: the fixed ones (`phraseNames`, `short.card` and `short.positions`
/// included) and the pair sections `couple.<a>-<b>`, `couple.<a>-<b>.any`, `meet.<a>-<b>`, `kin.sum21.<a>-<b>`,
/// `kin.same.<a>-<b>`, `succ.<a>-<b>` (a ≠ b); a variant whose placeholders aren't all
/// `{q|A|B|C|X|Y|S}.{name|kw|num|role|from|to|closing|question|srole}` or `{tag}` is ignored. One-line sections
/// keep their first line: `card.<i>.<field>` (the twelve, `reading`, `printed`, `srole`, `brief`), `tag.<name>`, `depth`,
/// `prompt`, `prompt.armed` (§5f.8), `question.lead`, `hint.waits|armed|next|back|end` (§5f.9).
///
/// **Paragraph.** The findings in this order — couple by order 5, encounter 4, centre gaze 4, facing / back 3 (two
/// slots), kinship 3, succession 3, degree step 2, arc 2, placement 2, hidden sum 2, open / closed 1, follow 1,
/// echo 1 — then the positions and the centre card's closing (`{B.closing}`), joined with one space. Sums count Le
/// Mat as 22 and reduce a sum over 22 by adding its digits. No question card: q is −1 (the engine refuses others).
///
/// **Variant**: `fnv1a32("-1,A,B,C,<section>") mod n` over the UTF-8 bytes (e.g. `"-1,2,11,19,arc.dip"`).
///
/// **Budget** (over `textMax` bytes): the weakest finding goes first (equal strengths: the one written later
/// first); at strength 2 the arc's `" (…)"` numerals go first; the positions and closing are never dropped (if they
/// alone are too long, the paragraph is cut before a space and ends with "…").
///
/// **Lean draw** (§5f.7, `composeLean`): five one-page screens — by card (one `[short.card]` variant for the row
/// filled with A, B, C), by position (`[short.positions]`), by the numbers (the arc, numerals and all), together (the
/// strongest finding other than arc, gaze.front, follow and echo), and (the second such finding + " " + B's closing
/// if that fits a page, else the finding alone if it fits, else the closing alone; the closing alone without a
/// second finding). "Fits" is the caller's page test (the clip's body font), else ≤ `leanPageChars` code points.
public struct SentenceReader: Sendable {
    /// Bytes of the paragraph (`ORR_TEXT_MAX`, = the text layout's 900).
    public static let textMax = 900
    /// Longer bundle lines are ignored (`ORR_LINE_MAX`).
    public static let lineMax = 512
    /// A sentence is cut to this many bytes before joining (`ORR_SENTENCE_MAX`).
    public static let sentenceMax = 960
    /// Card indices are 0…77 (`ORR_MAX_CARDS`).
    public static let maxCards = 78

    /// `card.<i>.<field>`: the first eight are the placeholder fields, the first twelve the engine's table;
    /// `reading` and `printed` are the clip's text screens (§5f.2) and `brief` its one-page detail (§5f.7); they stay
    /// out of the composer.
    public enum Field: Int, CaseIterable, Sendable {
        case name, kw, num, role, from, to, closing, question, gaze, degree, row, symbols, reading, printed, srole, brief
        public var key: String { SentenceReader.fieldNames[rawValue] }
    }

    public static let fieldNames = ["name", "kw", "num", "role", "from", "to", "closing", "question", "gaze", "degree", "row", "symbols",
                                    "reading", "printed", "srole", "brief"]
    /// The 20 symbol tags of §5f.1, in the echo's fixed order.
    public static let tags = ["water", "sun", "moon", "animal", "tower", "crown", "book", "sword", "cup", "coin", "staff", "child",
                              "angel", "star", "wheel", "hand", "path", "flower", "egg", "mountain"]
    static let phraseNames = ["question", "arc.rising", "arc.falling", "arc.peak", "arc.dip", "arc.plateau", "arc.still",
                              "gaze.facing", "gaze.back", "gaze.follow", "gaze.front", "gaze.center.left", "gaze.center.right",
                              "kin.sum21", "kin.same", "positions", "echo",
                              "qsum.two", "qsum.three", "step.up", "step.down", "step.restart", "place.wheel.first", "place.wheel.later",
                              "place.world.first", "place.world.last", "place.fool.before", "place.fool.after", "hsum", "hsum.drawn",
                              "row.open.left", "row.open.right", "row.closed", "short.card", "short.positions"]
    /// One-line sections of the clip's text screens (§5f.2).
    public static let textSections = ["prompt", "prompt.armed", "question.lead", "hint.waits", "hint.armed", "hint.next", "hint.back", "hint.end"]

    /// Pair section kinds (prefix, suffix), in the engine's matching order.
    enum PairKind: Int, CaseIterable, Sendable {
        case couple, coupleAny, meet, kinSum, kinSame, succ
        var prefix: String { ["couple.", "couple.", "meet.", "kin.sum21.", "kin.same.", "succ."][rawValue] }
        var suffix: String { rawValue == 1 ? ".any" : "" }
    }

    /// A phrase section: one of `phraseNames`, or a pair section.
    enum Section: Hashable, Sendable {
        case phrase(Int)
        case pair(PairKind, Int, Int)

        /// As hashed ("arc.rising", "couple.3-4.any", "kin.sum21.1-20").
        var name: String {
            switch self {
            case .phrase(let p): SentenceReader.phraseNames[p]
            case .pair(let k, let a, let b): "\(k.prefix)\(a)-\(b)\(k.suffix)"
            }
        }
    }

    // Phrase indices (`P_*`).
    static let pQuestion = 0, pRising = 1, pFalling = 2, pPeak = 3, pDip = 4, pPlateau = 5, pStill = 6
    static let pFacing = 7, pBack = 8, pFollow = 9, pFront = 10, pCenterLeft = 11, pCenterRight = 12
    static let pSum21 = 13, pSame = 14, pPositions = 15, pEcho = 16
    static let pQsumTwo = 17, pQsumThree = 18, pStepUp = 19, pStepDown = 20, pStepRestart = 21, pWheelFirst = 22, pWheelLater = 23
    static let pWorldFirst = 24, pWorldLast = 25, pFoolBefore = 26, pFoolAfter = 27, pHsum = 28, pHsumDrawn = 29
    static let pRowOpenLeft = 30, pRowOpenRight = 31, pRowClosed = 32, pShortCard = 33, pShortPositions = 34

    /// Placeholder cards: {q} {A} {B} {C} the row, {X} {Y} the cards a finding names, {S} the hidden sum.
    static let who: [UInt8] = [0x71, 0x41, 0x42, 0x43, 0x58, 0x59, 0x53]   // q A B C X Y S

    /// Sentence slots in writing order (`S_*`), their strengths (0 = never dropped) and budget names
    /// (the engine's `ORR_DROP_*` bits are 1 << slot).
    static let sQuestion = 0, sCouple = 1, sQsum = 2, sMeet = 3, sCenter = 4, sFB1 = 5, sFB2 = 6, sKin = 7, sSucc = 8, sStep = 9,
               sArc = 10, sPlace = 11, sHsum = 12, sRow = 13, sFollow = 14, sEcho = 15, sPositions = 16, sClosing = 17, slotCount = 18
    static let strength = [0, 5, 5, 4, 4, 3, 3, 3, 3, 2, 2, 2, 2, 1, 1, 1, 0, 0]
    static let slotDropNames: [Int: String] = [1: "couple", 2: "qsum", 3: "meet", 4: "center", 5: "facing1", 6: "facing2", 7: "kin",
                                               8: "succ", 9: "step", 10: "arc", 11: "place", 12: "hsum", 13: "row", 14: "follow", 15: "echo"]
    /// The engine's bits for the budget names (`orr_dropped`).
    public static let dropBits: [String: Int] = {
        var d: [String: Int] = ["numerals": 1 << 20, "cut": 1 << 21]
        for (s, n) in slotDropNames { d[n] = 1 << s }
        return d
    }()

    /// Card lines, `cards × 15` (nil = absent).
    private let table: [[[UInt8]?]]
    /// `prompt`, `prompt.armed` (§5f.8), `question.lead`, `hint.waits|armed|next|back|end` (§5f.9).
    private let texts: [String: [UInt8]]
    /// Valid variants per phrase section, in bundle order.
    private let variants: [Section: [[UInt8]]]
    private let tagGloss: [[UInt8]?]
    private let depth: [UInt8]?
    /// 1 + the highest card index with a card line (0 for none).
    public let cards: Int

    // MARK: Parsing

    /// Indexes a bundle (never fails: a bundle with no usable line says little or refuses every row).
    public init(bundle data: Data) {
        self.init(bytes: [UInt8](data))
    }

    public init(text: String) {
        self.init(bytes: Array(text.utf8))
    }

    init(bytes text: [UInt8]) {
        enum Kind { case none, ignore, phrase(Section), depth, tag(Int), card(Int, Int), text(String) }
        var cur = Kind.none
        var table: [[[UInt8]?]] = []
        var texts: [String: [UInt8]] = [:]
        var variants: [Section: [[UInt8]]] = [:]
        var tagGloss = [[UInt8]?](repeating: nil, count: Self.tags.count)
        var depth: [UInt8]?
        var lineCount = 0
        var pos = 0
        let len = text.count
        while pos < len {
            var end = pos
            while end < len && text[end] != 0x0A { end += 1 }
            let s = pos
            var e = end
            pos = end < len ? end + 1 : len
            if e > s && text[e - 1] == 0x0D { e -= 1 }
            let n = e - s
            if n > Self.lineMax { continue }
            var ctl = false, blank = true
            for i in s..<e {
                let c = text[i]
                if (c < 0x20 && c != 0x09) || c == 0x7F { ctl = true }
                if c != 0x20 && c != 0x09 { blank = false }
            }
            if ctl || !Self.utf8OK(text[s..<e]) { continue }
            let line = Array(text[s..<e])
            if n >= 2 && line[0] == 0x5B && line[n - 1] == 0x5D {
                let inner = Array(line[1..<(n - 1)])
                if let p = Self.lookup(inner, Self.phraseNames) {
                    cur = .phrase(.phrase(p))
                } else if let sec = Self.pairSection(inner) {
                    cur = .phrase(sec)
                } else if Self.eq(inner, "depth") {
                    cur = .depth
                } else if inner.count > 4, Self.hasPrefix(inner, "tag.") {
                    cur = Self.lookup(Array(inner[4...]), Self.tags).map { .tag($0) } ?? .ignore
                } else if inner.count > 5, Self.hasPrefix(inner, "card.") {
                    var i = 5
                    let v = Self.cardNumber(inner, &i)
                    if v >= 0, i < inner.count, inner[i] == 0x2E, let f = Self.lookup(Array(inner[(i + 1)...]), Self.fieldNames) {
                        cur = .card(v, f)
                    } else {
                        cur = .ignore
                    }
                } else if let t = Self.textSections.first(where: { Self.eq(inner, $0) }) {
                    cur = .text(t)
                } else {
                    cur = .ignore
                }
                continue
            }
            if blank { continue }
            switch cur {
            case .none, .ignore: continue
            case .phrase(let sec):
                // (a 64 K-line bundle: the rest is ignored, as the engine's 16-bit count)
                guard Self.phraseOK(line), lineCount < Int(UInt16.max) else { break }
                variants[sec, default: []].append(line)
                lineCount += 1
            case .depth:
                if depth == nil { depth = line }
            case .tag(let t):
                if tagGloss[t] == nil { tagGloss[t] = line }
            case .card(let c, let f):
                while table.count <= c { table.append([[UInt8]?](repeating: nil, count: Self.fieldNames.count)) }
                if table[c][f] == nil { table[c][f] = line }
            case .text(let t):
                if texts[t] == nil { texts[t] = line }
            }
        }
        self.table = table
        self.texts = texts
        self.variants = variants
        self.tagGloss = tagGloss
        self.depth = depth
        self.cards = table.count
    }

    /// `utf8_ok`: shortest forms, no surrogates, ≤ U+10FFFF.
    static func utf8OK(_ s: ArraySlice<UInt8>) -> Bool {
        var i = s.startIndex
        let n = s.endIndex
        while i < n {
            let c = s[i]
            if c < 0x80 { i += 1; continue }
            let k: Int
            var cp: UInt32, minCP: UInt32
            if c & 0xE0 == 0xC0 { k = 1; cp = UInt32(c & 0x1F); minCP = 0x80 }
            else if c & 0xF0 == 0xE0 { k = 2; cp = UInt32(c & 0x0F); minCP = 0x800 }
            else if c & 0xF8 == 0xF0 { k = 3; cp = UInt32(c & 0x07); minCP = 0x10000 }
            else { return false }
            if n - i <= k { return false }
            for j in 1...k {
                let b = s[i + j]
                if b & 0xC0 != 0x80 { return false }
                cp = (cp << 6) | UInt32(b & 0x3F)
            }
            if cp < minCP || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) { return false }
            i += k + 1
        }
        return true
    }

    static func eq(_ s: [UInt8], _ lit: String) -> Bool { s.elementsEqual(lit.utf8) }
    static func hasPrefix(_ s: [UInt8], _ lit: String) -> Bool { s.starts(with: lit.utf8) }
    static func lookup(_ s: [UInt8], _ table: [String]) -> Int? { table.firstIndex { eq(s, $0) } }

    /// 1–2 ASCII digits at `s[i]` (value < 78), −1 otherwise (`card_num`: up to three digits are read).
    static func cardNumber(_ s: [UInt8], _ i: inout Int, end: Int? = nil) -> Int {
        let n = end ?? s.count
        var v = 0, d = 0
        while i < n, s[i] >= 0x30, s[i] <= 0x39, d < 3 { v = v * 10 + Int(s[i] - 0x30); i += 1; d += 1 }
        return (d < 1 || d > 2 || v >= maxCards) ? -1 : v
    }

    /// `<prefix><a>-<b><suffix>` (a ≠ b), the kinds tried in the engine's order.
    static func pairSection(_ s: [UInt8]) -> Section? {
        for kind in PairKind.allCases {
            let pl = kind.prefix.utf8.count, sl = kind.suffix.utf8.count
            guard s.count > pl + sl, hasPrefix(s, kind.prefix) else { continue }
            if sl > 0 && !s[(s.count - sl)...].elementsEqual(kind.suffix.utf8) { continue }
            let end = s.count - sl
            var i = pl
            let a = cardNumber(s, &i, end: end)
            guard a >= 0, i < end, s[i] == 0x2D else { continue }
            i += 1
            let b = cardNumber(s, &i, end: end)
            guard b >= 0, i == end, a != b else { continue }
            return .pair(kind, a, b)
        }
        return nil
    }

    /// A placeholder key ("A.kw", "X.srole", "tag"): 0 = `{tag}`, 1 + who × 16 + field for the text fields (the
    /// eight, and §5f.4's `srole`), nil = invalid.
    static func placeholderKey(_ s: ArraySlice<UInt8>) -> Int? {
        let a = Array(s)
        if eq(a, "tag") { return 0 }
        guard a.count >= 3, a[1] == 0x2E else { return nil }
        let rest = Array(a[2...])
        guard let w = who.lastIndex(of: a[0]),
              let f = lookup(rest, Array(fieldNames.prefix(Field.question.rawValue + 1))) ?? (eq(rest, "srole") ? Field.srole.rawValue : nil) else {
            return nil
        }
        return 1 + w * 16 + f
    }

    static func phraseOK(_ s: [UInt8]) -> Bool {
        var i = 0
        while i < s.count {
            if s[i] != 0x7B { i += 1; continue }
            var k = i + 1
            while k < s.count && s[k] != 0x7D { k += 1 }
            if k >= s.count || placeholderKey(s[(i + 1)..<k]) == nil { return false }
            i = k + 1
        }
        return true
    }

    // MARK: The table

    /// A card's field line (nil when absent).
    public func field(_ card: Int, _ f: Field) -> String? { line(card, f.rawValue).map { String(decoding: $0, as: UTF8.self) } }

    /// `prompt` / `prompt.armed` / `question.lead` (§5f.2, §5f.8), nil when absent.
    public func text(_ section: String) -> String? { texts[section].map { String(decoding: $0, as: UTF8.self) } }

    private func line(_ card: Int, _ f: Int) -> [UInt8]? {
        guard card >= 0, card < cards else { return nil }
        return table[card][f]
    }

    private func has(_ i: Int) -> Bool { i >= 0 && line(i, Field.name.rawValue) != nil }

    /// The value of a numeric line: 1–3 ASCII digits, anything else (or absent) is 0.
    private func numOf(_ card: Int, _ f: Field) -> Int {
        guard let l = line(card, f.rawValue), (1...3).contains(l.count) else { return 0 }
        var v = 0
        for c in l {
            guard c >= 0x30, c <= 0x39 else { return 0 }
            v = v * 10 + Int(c - 0x30)
        }
        return v
    }

    private func degree(_ i: Int) -> Int {
        let d = numOf(i, .degree)
        return d == 21 ? 11 : d
    }

    /// The book's number: 0 (row 0), 21 (row 3), degree (row 1), degree + 10 (row 2).
    private func number(_ i: Int) -> Int {
        let r = numOf(i, .row), d = numOf(i, .degree)
        return r == 0 ? 0 : r == 3 ? 21 : r == 2 ? d + 10 : d
    }

    /// The number in sums: Le Mat (row 0) counts 22.
    private func n22(_ i: Int) -> Int { numOf(i, .row) == 0 ? 22 : number(i) }

    /// A sum over 22 reduced by adding its digits until ≤ 22.
    static func reduce22(_ x: Int) -> Int {
        var x = x
        while x > 22 {
            var d = 0, y = x
            while y > 0 { d += y % 10; y /= 10 }
            x = d
        }
        return x
    }

    enum Gaze { case other, left, right, front }

    private func gaze(_ i: Int) -> Gaze {
        guard let l = line(i, Field.gaze.rawValue) else { return .other }
        if Self.eq(l, "left") { return .left }
        if Self.eq(l, "right") { return .right }
        if Self.eq(l, "front") { return .front }
        return .other
    }

    private func hasTag(_ i: Int, _ tag: String) -> Bool {
        guard let l = line(i, Field.symbols.rawValue) else { return Self.eq([], tag) }
        return l.split(separator: 0x2C, omittingEmptySubsequences: false).contains { Self.eq(Array($0), tag) }
    }

    // MARK: Composing

    /// The paragraph and how it was made.
    public struct Paragraph: Sendable, Equatable {
        /// UTF-8, at most `textMax` bytes.
        public var bytes: [UInt8]
        /// The sections of its sentences in paragraph order ("question", "couple.1-11", …, "closing").
        public var sections: [String]
        /// The budget steps taken, in the engine's bit order (`dropBits`).
        public var dropped: [String]

        public var text: String { String(decoding: bytes, as: UTF8.self) }
    }

    /// §5f.6: the paragraph for the row `a b c` (no question card: the closing is B's). Nil, like the engine's −1,
    /// for a card that isn't in the table (no name line).
    public func compose(a: Int, b: Int, c: Int) -> Paragraph? { compose(q: -1, a: a, b: b, c: c) }

    /// `orr_compose(b, q, A, B, C, …)` as the engine and the fixtures call it: `q` must be −1 (§5f.6).
    func compose(q: Int, a: Int, b: Int, c: Int) -> Paragraph? {
        guard let (s, ssec) = sentences(q: q, a: a, b: b, c: c) else { return nil }
        var sent = s
        return budget(&sent, ssec)
    }

    // MARK: The lean draw (§5f.7)

    /// The five lean screens: by card, by position, by the numbers, together, and.
    public static let leanScreens = 5
    /// The reference "fits one page" (`ORR_LEAN_PAGE_CHARS`): at most 150 code points (the fixtures use it; the
    /// clip and the app ask the body font's page at the item's size).
    public static let leanPageChars = 150
    /// `orr_compose_lean`'s out capacity per screen as the firmware and the fixtures use it (`ORR_OUT_MIN`).
    static let leanCap = textMax + 1

    /// `fits` = nil: the reference rule (≤ 150 code points, `orr_chars`).
    public static func fitsDefault(_ text: [UInt8]) -> Bool { text.reduce(0) { $0 + ($1 & 0xC0 != 0x80 ? 1 : 0) } <= leanPageChars }

    /// `orr_compose_lean` (PROTOCOL §5f.7), byte for byte; nil like `compose` (a card not in the table):
    /// 0. by card: one `[short.card]` variant for the row (hashed once as `"-1,A,B,C,short.card"`), filled with `{X}`
    ///    = A, B, C in turn (`{X.srole}`, else the role), the lines joined with one space;
    /// 1. by position: a `[short.positions]` variant;
    /// 2. by the numbers: the arc sentence (numerals and `[depth]` words included);
    /// 3. together: the strongest finding of `compose`'s ranking (before any budget) other than the arc, gaze.front,
    ///    gaze.follow and echo ("" when there is none);
    /// 4. and: the second such finding + " " + B's closing when that fits one page, else the finding alone when it
    ///    fits, else B's closing alone (also when there is no second finding).
    /// `fits` decides "fits one page" (the body font's page at the item's size); nil = the reference ≤ 150 code points.
    public func composeLean(a: Int, b: Int, c: Int, fits: ((String) -> Bool)? = nil) -> [String]? {
        guard let (sent, ssec) = sentences(q: -1, a: a, b: b, c: c) else { return nil }
        let (A, B, C) = (a, b, c)
        let key = Array("-1,\(A),\(B),\(C),".utf8)
        let base = [-1, A, B, C, -1, -1, -1]
        func fitsPage(_ t: [UInt8]) -> Bool { fits.map { $0(String(decoding: t, as: UTF8.self)) } ?? Self.fitsDefault(t) }
        func pick(_ sec: Int, name: String) -> [UInt8]? {
            guard let vs = variants[.phrase(sec)], !vs.isEmpty else { return nil }
            return vs[Int(Oracle.fnv1a(key + Array(name.utf8)) % UInt32(vs.count))]
        }
        /// `append`: " " + src when it fits whole in `leanCap` (NUL included), else nothing.
        func append(_ out: inout [UInt8], _ src: [UInt8]) {
            let sep = out.isEmpty ? 0 : 1
            guard out.count + sep + src.count + 1 <= Self.leanCap else { return }
            if sep == 1 { out.append(0x20) }
            out += src
        }
        /// `copy_slot`: cut to `leanCap − 1` bytes at a UTF-8 boundary.
        func copied(_ d: [UInt8]) -> [UInt8] {
            guard d.count > Self.leanCap - 1 else { return d }
            var n = Self.leanCap - 1
            while n > 0 && d[n] & 0xC0 == 0x80 { n -= 1 }
            return Array(d[0..<n])
        }
        var out = [[UInt8]](repeating: [], count: Self.leanScreens)
        // 2: by the numbers
        out[2] = copied(sent[Self.sArc])
        // 3, 4: the strongest findings other than the arc, gaze.front, follow and echo
        let lean = (Self.sCouple...Self.sEcho).filter { slot in
            !sent[slot].isEmpty && slot != Self.sArc && slot != Self.sFollow && slot != Self.sEcho && ssec[slot] != .phrase(Self.pFront)
        }
        if let first = lean.first { out[3] = copied(sent[first]) }
        let closing = sent[Self.sClosing]
        if lean.count > 1 {
            let f2 = sent[lean[1]]
            let both = f2 + (closing.isEmpty ? [] : [0x20] + closing)
            // the C joins them in a sentence slot: longer than `sentenceMax + 1` bytes never fits a page anyway
            let room = both.count < Self.sentenceMax + 2
            if room && fitsPage(both) { append(&out[4], both) } else if fitsPage(f2) { append(&out[4], f2) }
        }
        if out[4].isEmpty { append(&out[4], closing) }
        // 1: by position
        if let t = pick(Self.pShortPositions, name: "short.positions") { out[1] = copied(fill(t, who: base, tag: nil, depth: false)) }
        // 0: by card, one variant for the row
        if let t = pick(Self.pShortCard, name: "short.card") {
            for x in [A, B, C] {
                var w = base
                w[4] = x
                append(&out[0], fill(t, who: w, tag: nil, depth: false))
            }
        }
        return out.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Every sentence slot as written before the budget (`slotCount` slots, empty = not written), and its section.
    private func sentences(q: Int, a: Int, b: Int, c: Int) -> ([[UInt8]], [Section?])? {
        // §5f.6: no question card (q is −1), A, B and C in the table
        guard q == -1, has(a), has(b), has(c) else { return nil }
        let (A, B, C) = (a, b, c)
        let key = Array("\(q),\(A),\(B),\(C),".utf8)
        var sent = [[UInt8]](repeating: [], count: Self.slotCount)
        var ssec = [Section?](repeating: nil, count: Self.slotCount)
        // {q} {A} {B} {C} {X} {Y} {S}
        let base = [q, A, B, C, -1, -1, -1]
        func pair(_ x: Int, _ y: Int) -> [Int] { [q, x, y, C, -1, -1, -1] }
        func samePair(_ x: Int, _ y: Int, _ cx: Int, _ cy: Int) -> Bool { (x == cx && y == cy) || (x == cy && y == cx) }

        func pick(_ sec: Section) -> [UInt8]? {
            guard let vs = variants[sec], !vs.isEmpty else { return nil }
            let h = Oracle.fnv1a(key + Array(sec.name.utf8))
            return vs[Int(h % UInt32(vs.count))]
        }
        @discardableResult
        func say(_ slot: Int, _ sec: Section, _ who: [Int], tag: [UInt8]? = nil, depth withDepth: Bool = false) -> Bool {
            guard let t = pick(sec) else { return false }
            sent[slot] = fill(t, who: who, tag: tag, depth: withDepth)
            ssec[slot] = sec
            return true
        }
        func phrase(_ p: Int) -> Section { .phrase(p) }

        do {
            // §5f.6: the row's pairs only (no question card, no question sentence, no question sum)
            let pairs = [(A, B), (B, C), (A, C)]
            let adjacent = [(A, B), (B, C)]

            // couple (5): the first pair of the scan with a section; a row pair in its order, else unordered (.any)
            var cx = -1, cy = -1
            for (x, y) in pairs where x != y {
                let lo = min(x, y), hi = max(x, y)
                var said = say(Self.sCouple, .pair(.couple, x, y), pair(x, y))
                if !said { said = say(Self.sCouple, .pair(.coupleAny, lo, hi), pair(lo, hi)) }
                if said { cx = x; cy = y; break }
            }

            // encounter (4): meet.<x>-<y> (order of appearance), else meet.<y>-<x>
            for (x, y) in pairs where x != y {
                if say(Self.sMeet, .pair(.meet, x, y), pair(x, y)) { break }
                if say(Self.sMeet, .pair(.meet, y, x), pair(y, x)) { break }
            }

            // centre gaze (4): B addresses A (left), C (right) or you (front)
            var coverAB = false, coverBC = false
            switch gaze(B) {
            case .left: coverAB = say(Self.sCenter, phrase(Self.pCenterLeft), base)
            case .right: coverBC = say(Self.sCenter, phrase(Self.pCenterRight), base)
            case .front: say(Self.sCenter, phrase(Self.pFront), base)
            case .other: break
            }

            // facing / back to back (3) for (A,B), (B,C), skipping a covered pair; follow (1): the first uncovered
            // pair looking the same way, the follower as {A}
            var fb = Self.sFB1
            var followed = false
            for (i, (x, y)) in adjacent.enumerated() {
                if i == 0 ? coverAB : coverBC { continue }
                let gx = gaze(x), gy = gaze(y)
                guard gx == .left || gx == .right, gy == .left || gy == .right else { continue }
                if gx == .right && gy == .left {
                    if say(fb, phrase(Self.pFacing), pair(x, y)) { fb += 1 }
                } else if gx == .left && gy == .right {
                    if say(fb, phrase(Self.pBack), pair(x, y)) { fb += 1 }
                } else if !followed {
                    followed = say(Self.sFollow, phrase(Self.pFollow), gx == .right ? pair(x, y) : pair(y, x))
                }
            }

            // kinship (3): outside the couple's pair, a pair summing to 21 before one of a degree in rows 1 and 2;
            // its own section ({A} = lo) or the generic one ({A} = x)
            var kin: (x: Int, y: Int, pass: Int)?
            for pass in 0..<2 where kin == nil {
                for (x, y) in pairs where x != y && !samePair(x, y, cx, cy) {
                    let rx = numOf(x, .row), ry = numOf(y, .row)
                    let hit = pass == 0 ? number(x) + number(y) == 21
                        : degree(x) == degree(y) && ((rx == 1 && ry == 2) || (rx == 2 && ry == 1))
                    if hit { kin = (x, y, pass); break }
                }
            }
            if let kin {
                let lo = min(kin.x, kin.y), hi = max(kin.x, kin.y)
                if !say(Self.sKin, .pair(kin.pass == 0 ? .kinSum : .kinSame, lo, hi), pair(lo, hi)) {
                    say(Self.sKin, phrase(kin.pass == 0 ? Self.pSum21 : Self.pSame), pair(kin.x, kin.y))
                }
            }

            // succession (3): (A,B) then (B,C), the first with succ.<x>-<y>
            var sx = -1, sy = -1
            for (x, y) in adjacent where say(Self.sSucc, .pair(.succ, x, y), pair(x, y)) {
                sx = x; sy = y
                break
            }

            // degree step (2): (A,B) then (B,C), both in rows 1–2, not the couple's nor the succession's pair
            for (x, y) in adjacent {
                if samePair(x, y, cx, cy) || samePair(x, y, sx, sy) { continue }
                let rx = numOf(x, .row), ry = numOf(y, .row)
                guard (1...2).contains(rx), (1...2).contains(ry) else { continue }
                let dx = degree(x), dy = degree(y)
                let sec = (dx == 10 && dy == 1) ? Self.pStepRestart : dy == dx + 1 ? Self.pStepUp : dy == dx - 1 ? Self.pStepDown : -1
                if sec >= 0 && say(Self.sStep, phrase(sec), pair(x, y)) { break }
            }

            // arc (2)
            let dA = degree(A), dB = degree(B), dC = degree(C)
            let arc: Int
            if dA == dB && dB == dC { arc = Self.pStill }
            else if dA == dB || dB == dC || dA == dC { arc = Self.pPlateau }
            else if dA < dB && dB < dC { arc = Self.pRising }
            else if dA > dB && dB > dC { arc = Self.pFalling }
            else if dB > dA && dB > dC { arc = Self.pPeak }
            else { arc = Self.pDip }
            say(Self.sArc, phrase(arc), base, depth: true)

            // placement (2): the Wheel first / later, the World first / last, Le Mat walking towards the card on his
            // right ({X}; in C: towards B), unless that pair is the couple's
            var place: (sec: Int, x: Int)?
            if A == 10 { place = (Self.pWheelFirst, 10) }
            else if B == 10 || C == 10 { place = (Self.pWheelLater, 10) }
            else if A == 21 { place = (Self.pWorldFirst, 21) }
            else if C == 21 { place = (Self.pWorldLast, 21) }
            else if A == 0 || B == 0 || C == 0 {
                let p = A == 0 ? 0 : B == 0 ? 1 : 2
                let nb = p < 2 ? [A, B, C][p + 1] : B
                if !samePair(0, nb, cx, cy) { place = (p < 2 ? Self.pFoolBefore : Self.pFoolAfter, nb) }
            }
            if let place { say(Self.sPlace, phrase(place.sec), [q, A, B, C, place.x, -1, -1]) }

            // hidden sum (2): S = reduced nA + nB + nC (22 = Le Mat); hsum.drawn when in the row
            let S = Self.reduce22(n22(A) + n22(B) + n22(C)) % 22
            say(Self.sHsum, phrase((S == A || S == B || S == C) ? Self.pHsumDrawn : Self.pHsum), [q, A, B, C, -1, -1, S])

            // open / closed (1)
            let gA = gaze(A), gC = gaze(C)
            let rowSec = gA == .left ? Self.pRowOpenLeft : gC == .right ? Self.pRowOpenRight : (gA == .right && gC == .left) ? Self.pRowClosed : -1
            if rowSec >= 0 { say(Self.sRow, phrase(rowSec), base) }

            // echo (1): the first tag (fixed order, with a gloss) on two or three of A, B, C
            for (t, name) in Self.tags.enumerated() {
                guard let gloss = tagGloss[t] else { continue }
                if [A, B, C].filter({ hasTag($0, name) }).count >= 2 {
                    say(Self.sEcho, phrase(Self.pEcho), base, tag: gloss)
                    break
                }
            }

            say(Self.sPositions, phrase(Self.pPositions), base)
        }
        // §5f.6: the centre card's closing
        sent[Self.sClosing] = Self.cutSentence(line(B, Field.closing.rawValue) ?? [])
        return (sent, ssec)
    }

    private func budget(_ sent: inout [[UInt8]], _ ssec: [Section?]) -> Paragraph {
        // The budget: the weakest finding first (equal strengths: the one written later first); at strength 2 the
        // arc first loses its " (...)" numerals.
        var droppedSlots = Set<Int>()
        var numerals = false
        func joinedLength() -> Int {
            let parts = sent.filter { !$0.isEmpty }
            return parts.isEmpty ? 0 : parts.reduce(0) { $0 + $1.count } + parts.count - 1
        }
        var total = joinedLength()
        var str = 1
        while str <= 5 && total > Self.textMax {
            if str == 2 && !sent[Self.sArc].isEmpty {
                let before = sent[Self.sArc].count
                sent[Self.sArc] = Self.stripNumerals(sent[Self.sArc])
                if sent[Self.sArc].count != before {
                    numerals = true
                    total = joinedLength()
                }
            }
            var s = Self.slotCount - 1
            while s >= 0 && total > Self.textMax {
                if Self.strength[s] == str && !sent[s].isEmpty {
                    sent[s] = []
                    droppedSlots.insert(s)
                    total = joinedLength()
                }
                s -= 1
            }
            str += 1
        }
        let joined = Array(sent.filter { !$0.isEmpty }.joined(separator: [0x20]))
        var out: [UInt8]
        var cut = false
        if total <= Self.textMax {
            out = joined
        } else {
            // the prefix up to byte textMax − 3 inclusive decides the cut
            let lim = Self.textMax - 3
            let prefix = Array(joined.prefix(lim + 1))
            var at = 0
            var i = lim
            while i >= 1 {
                if prefix[i] == 0x20 { at = i; break }
                i -= 1
            }
            if at == 0 {
                at = lim
                while at > 0 && prefix[at] & 0xC0 == 0x80 { at -= 1 }
            }
            out = Array(prefix[0..<at]) + [0xE2, 0x80, 0xA6]
            cut = true
        }
        var sections: [String] = []
        for i in 0..<Self.slotCount where !sent[i].isEmpty {
            if i == Self.sClosing { sections.append("closing") } else if let sec = ssec[i] { sections.append(sec.name) }
        }
        var dropped = (1..<Self.sPositions).filter(droppedSlots.contains).compactMap { Self.slotDropNames[$0] }
        if numerals { dropped.append("numerals") }
        if cut { dropped.append("cut") }
        return Paragraph(bytes: out, sections: sections, dropped: dropped)
    }

    /// Template `t` with `who` = the cards {q} {A} {B} {C} {X} {Y} {S} stand for (−1: empty), cut to `sentenceMax`.
    private func fill(_ t: [UInt8], who: [Int], tag: [UInt8]?, depth withDepth: Bool) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(t.count + 64)
        var p = 0
        while p < t.count {
            if t[p] != 0x7B {
                var q = p
                while q < t.count && t[q] != 0x7B { q += 1 }
                out += t[p..<q]
                p = q
                continue
            }
            var c = p + 1
            while c < t.count && t[c] != 0x7D { c += 1 }   // validated at parse: always closed and valid
            let k = Self.placeholderKey(t[(p + 1)..<min(c, t.count)])
            p = c + 1
            guard let k else { continue }
            if k == 0 {
                if let tag { out += tag }
            } else {
                let card = who[(k - 1) / 16]
                var f = (k - 1) % 16
                if card < 0 { continue }
                if f == Field.srole.rawValue && line(card, f) == nil { f = Field.role.rawValue }   // §5f.4: else the role
                out += line(card, f) ?? []
                if withDepth && f == Field.kw.rawValue && numOf(card, .row) == 2, let depth {
                    out.append(0x20)
                    out += depth
                }
            }
        }
        return Self.cutSentence(out)
    }

    /// Cut to `sentenceMax` bytes at a UTF-8 boundary.
    static func cutSentence(_ d: [UInt8]) -> [UInt8] {
        guard d.count > sentenceMax else { return d }
        var n = sentenceMax
        while n > 0 && d[n] & 0xC0 == 0x80 { n -= 1 }
        return Array(d[0..<n])
    }

    /// Removes `" ?\([^)]*\)"` matches (leftmost first, as Python's `re.sub`).
    static func stripNumerals(_ s: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var r = 0
        let n = s.count
        while r < n {
            var open: Int?
            if s[r] == 0x20 && r + 1 < n && s[r + 1] == 0x28 { open = r + 1 } else if s[r] == 0x28 { open = r }
            if let open, let close = s[(open + 1)...].firstIndex(of: 0x29) {
                r = close + 1
                continue
            }
            out.append(s[r])
            r += 1
        }
        return out
    }
}

// MARK: - The bundle the app uploads

/// The phrase bundle as a file: the app's bundled `reader-<lang>.txt`, with the `card.<i>.*` lines
/// regenerated from the person's edits, so the clip and the phone read and show the same thing.
///
/// Since §5f.2 the bundle also carries what the clip writes on its text screens: the edits to a card's
/// keyword, question, closing, **reading** and name on the clip (`printed`) all go into its card lines.
/// The number notes stay in the notes asset.
public enum ReaderBundle {
    /// `/texts` ids: `tarot-reader-<lang>-<10 hex of the file's SHA-256>` (≤ 32 characters, like Reader texts).
    public static let textPrefix = "tarot-reader-"

    public static func textID(language: TarotLanguage, data: Data) -> String {
        "\(textPrefix)\(language.rawValue)-\(Hashing.sha256Hex(data).prefix(10))"
    }

    /// The bundle with every `[card.<i>.<field>]` section replaced (the builder's order: the other sections as
    /// they are, then the cards in index order, each with every field the bundle uses, in `Field` order; an
    /// absent value is a header with no line, as XIII's `printed`). `overrides` replace values (newlines become
    /// spaces; an empty override keeps the bundle's line, except `printed`, which may be emptied). With no
    /// overrides the result is the input, byte for byte (for a bundle written by the builder).
    public static func rewriting(_ bundle: String, overrides: [Int: [SentenceReader.Field: String]]) -> String {
        guard !overrides.isEmpty else { return bundle }
        let reader = SentenceReader(text: bundle)
        var out: [String] = []
        var inCard = false
        var used = Set<SentenceReader.Field>()
        var maxCard = -1
        for raw in bundle.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inCard = line.hasPrefix("[card.")
                if inCard {
                    let parts = line.dropFirst(6).dropLast().split(separator: ".", maxSplits: 1)
                    if parts.count == 2, let i = Int(parts[0]), let f = SentenceReader.fieldNames.firstIndex(of: String(parts[1])) {
                        used.insert(SentenceReader.Field(rawValue: f)!)
                        maxCard = max(maxCard, i)
                    }
                    continue
                }
            }
            if inCard { continue }
            out.append(line)
        }
        while out.last == "" { out.removeLast() }
        if maxCard >= 0 {
            for i in 0...maxCard {
                for f in SentenceReader.Field.allCases where used.contains(f) {
                    out.append("[card.\(i).\(f.key)]")
                    let edited = overrides[i]?[f].map(clean)
                    let v: String?
                    if let edited, !edited.isEmpty || f == .printed { v = edited } else { v = reader.field(i, f) }
                    if let v, !v.isEmpty { out.append(v) }
                }
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// One line: newlines and tabs to spaces, runs collapsed, trimmed.
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: " ").map { $0.isNewline || $0 == "\t" ? " " : String($0) }.joined()
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// The overrides for the edits in `language`: keyword → `kw`, question → `question`, closing → `closing`,
    /// reading → `reading`, name on the clip → `printed` (only where the text differs from the bundle's).
    public static func overrides(edits: TarotEdits, language: TarotLanguage, bundle: SentenceReader) -> [Int: [SentenceReader.Field: String]] {
        var out: [Int: [SentenceReader.Field: String]] = [:]
        for card in 0..<bundle.cards {
            let e = edits[card, language]
            var o: [SentenceReader.Field: String] = [:]
            for (f, v) in [(SentenceReader.Field.kw, e.keyword), (.question, e.question), (.closing, e.closing), (.reading, e.reading),
                           (.printed, e.name)] {
                guard let v else { continue }
                let c = clean(v)
                if (!c.isEmpty || f == .printed) && c != (bundle.field(card, f) ?? "") { o[f] = c }
            }
            if !o.isEmpty { out[card] = o }
        }
        return out
    }

    /// The bundle to upload for `language` with the edits laid over its card lines.
    public static func applying(edits: TarotEdits, language: TarotLanguage, to bundle: String) -> String {
        let reader = SentenceReader(text: bundle)
        return rewriting(bundle, overrides: overrides(edits: edits, language: language, bundle: reader))
    }
}
