import Foundation

/// The clip's text wrapping, used by the Oracle's text screens (`OracleScreens`): a line-for-line port of the
/// firmware's text layout (`core/include/textlay.h`, `core/src/textlay.c`), so a text breaks into the same lines
/// on the phone as on the clip. Entries are glyphs and single separators (whitespace runs collapsed); lines
/// wrap greedily; a cut line ends with "…". On top of it, pages (§5f.3): a page that isn't the last ends after
/// its last sentence end, else after its last comma / semicolon / colon.
enum TextWrap {
    /// Bytes of UTF-8 laid out; the rest of a longer text is ignored.
    static let maxBytes = 900

    enum Kind: Equatable { case glyph, space, glue, newline }

    /// A text as entries: glyphs and single separators (whitespace runs collapsed).
    struct Entries {
        var cp: [UInt32] = []
        var kind: [Kind] = []
        /// Advance of each entry in the face being tried.
        var adv: [Int] = []
        var count: Int { cp.count }

        init(_ text: String) {
            var pending = 0, pendingGlue = false, bytes = 0
            for s in text.unicodeScalars {
                bytes += String(s).utf8.count
                if bytes > TextWrap.maxBytes { break }
                let v = s.value
                if v == 0x0D { continue }
                switch RSVPText.charClass(v) {
                case .newline, .paragraphSeparator: pending = 2; continue
                case .space: pending = max(pending, 1); continue
                case .join: pending = max(pending, 1); pendingGlue = true; continue
                default: break
                }
                if pending > 0, !cp.isEmpty {
                    cp.append(0x20); kind.append(pending == 2 ? .newline : (pendingGlue ? .glue : .space))
                }
                pending = 0; pendingGlue = false
                cp.append(v); kind.append(.glyph)
            }
            // French punctuation stays with its word.
            for j in kind.indices where kind[j] == .space {
                let before = j + 1 < count && kind[j + 1] == .glyph && Self.glueBefore(cp[j + 1])
                let after = j > 0 && kind[j - 1] == .glyph && Self.glueAfter(cp[j - 1])
                if before || after { kind[j] = .glue }
            }
            adv = Array(repeating: 0, count: cp.count)
        }

        /// ! ? : ; » ” … › never start a line after a space.
        static func glueBefore(_ cp: UInt32) -> Bool {
            [0x21, 0x3F, 0x3A, 0x3B, 0xBB, 0x201D, 0x2026, 0x203A].contains(cp)
        }
        /// « “ ‹ never end a line before a space.
        static func glueAfter(_ cp: UInt32) -> Bool { cp == 0xAB || cp == 0x201C || cp == 0x2039 }
        /// A word that doesn't fit may break after - / ‐ – —.
        static func breakAfter(_ cp: UInt32) -> Bool { [0x2D, 0x2F, 0x2010, 0x2013, 0x2014].contains(cp) }

        mutating func measure(_ face: ReaderBoundFont.Face) {
            for i in cp.indices { adv[i] = kind[i] == .glyph ? face.glyph(cp[i]).advance : face.spaceAdvance }
        }

        func width(_ a: Int, _ b: Int) -> Int { a < b ? adv[a..<b].reduce(0, +) : 0 }
        func isSep(_ i: Int) -> Bool { kind[i] == .space || kind[i] == .newline }
        func skipSeps(_ i: Int) -> Int {
            var i = i
            while i < count, kind[i] != .glyph { i += 1 }
            return i
        }
        /// Without separators / glued spaces at either end.
        func trimmed(_ r: Range<Int>) -> Range<Int> {
            var a = r.lowerBound, b = r.upperBound
            while a < b, kind[a] != .glyph { a += 1 }
            while b > a, kind[b - 1] != .glyph { b -= 1 }
            return a..<b
        }
    }

    /// The rest of the text from entry `from` on, cut to one line ending with "…" (or "..." when the face
    /// has no ellipsis): as much as fits, at a word boundary when that keeps ≥ 60 % of the line.
    static func ellipsisLine(_ text: Entries, from: Int, face: ReaderBoundFont.Face, maxw: Int) -> (Range<Int>, [UInt32]) {
        var ell: [UInt32] = []
        if face.map[0x2026] != nil { ell = [0x2026] } else if face.map[0x2E] != nil { ell = [0x2E, 0x2E, 0x2E] }
        let ew = ell.reduce(0) { $0 + face.glyph($1).advance }
        let rest = text.trimmed(from..<text.count)
        let a = rest.lowerBound, b = rest.upperBound
        let room = maxw - ew
        var bestW = -1, bestG = a, w = 0, wBestW = 0
        var k = a + 1
        while k <= b {
            w += text.adv[k - 1]
            if w > room { break }
            if text.kind[k - 1] == .glyph { bestG = k }
            if k < b, text.isSep(k), text.kind[k - 1] == .glyph { bestW = k; wBestW = w }
            k += 1
        }
        let cut = (bestW > a && wBestW * 10 >= room * 6) ? bestW : bestG
        return (text.trimmed(a..<cut), ell)
    }

    /// Largest k in (a, b) with `w0 + width(a..<k) ≤ maxw`, preferring a break after a hyphen/dash/slash;
    /// with `glyphOK`, else the largest glyph boundary (at least a + 1). −1 if none.
    static func splitPoint(_ nt: Entries, _ a: Int, _ b: Int, _ w0: Int, _ maxw: Int, glyphOK: Bool) -> Int {
        var bestH = -1, bestG = -1, w = w0
        var k = a + 1
        while k < b {
            w += nt.adv[k - 1]
            if w > maxw { break }
            bestG = k
            if nt.kind[k - 1] == .glyph, Entries.breakAfter(nt.cp[k - 1]) { bestH = k }
            k += 1
        }
        if bestH > 0 { return bestH }
        if !glyphOK { return -1 }
        return bestG > 0 ? bestG : a + 1
    }

    /// Greedy wrap of the entries from `from` on; stops once `stop` lines are complete and more text
    /// follows (the count is then `stop + 1`). Lines exclude the separators they break at.
    static func wrap(_ nt: Entries, from: Int, maxw: Int, stop: Int = .max) -> (lines: [Range<Int>], count: Int) {
        var lines: [Range<Int>] = []
        var s = nt.skipSeps(from), i = s, w = 0
        while i < nt.count {
            if lines.count >= stop { return (lines, lines.count + 1) }
            var j = i
            while j < nt.count, !nt.isSep(j) { j += 1 }
            let ww = nt.width(i, j)
            if i == s {
                if ww > maxw {
                    var k = splitPoint(nt, i, j, 0, maxw, glyphOK: true)
                    lines.append(s..<k)
                    if k >= j, j < nt.count { k = j + 1 }   // one glyph wider than the line: skip its separator
                    s = nt.skipSeps(k); i = s; w = 0
                    continue
                }
                w = ww
            } else {
                let sp = nt.adv[i - 1]
                if w + sp + ww > maxw {
                    let k = splitPoint(nt, i, j, w + sp, maxw, glyphOK: false)
                    if k > 0 { lines.append(s..<k); s = k; i = k } else { lines.append(s..<(i - 1)); s = i }
                    w = 0
                    continue
                }
                w += sp + ww
            }
            if j >= nt.count { lines.append(s..<j); break }
            if nt.kind[j] == .newline {
                lines.append(s..<j)
                s = nt.skipSeps(j + 1); i = s; w = 0
            } else {
                i = j + 1
            }
        }
        return (lines, lines.count)
    }

    /// Where a page that isn't the last ends inside its last line `a..<b`: after the last sentence end
    /// (. ! ? … possibly followed by closing quotes/brackets, and one glued space before them, "! »")
    /// right before a space; else after the last
    /// comma / semicolon / colon there; else at `b`.
    static func pageCut(_ nt: Entries, _ a: Int, _ b: Int) -> Int {
        var sentence = -1, pause = -1
        var k = a + 1
        while k < b {
            defer { k += 1 }
            guard nt.isSep(k), nt.kind[k - 1] == .glyph else { continue }
            var q = k - 1
            while q > a, nt.kind[q] == .glyph, RSVPText.charClass(nt.cp[q]) == .close { q -= 1 }   // .» .” .)
            if nt.kind[q] == .glue, q > a { q -= 1 }                                                  // "! »"
            guard nt.kind[q] == .glyph else { continue }
            let c = RSVPText.charClass(nt.cp[q])
            if c == .sentence { sentence = k } else if c == .pause || nt.cp[q] == 0x3A { pause = k }
        }
        return sentence > 0 ? sentence : pause > 0 ? pause : b
    }

    struct PageLines { var lines: [Range<Int>] }

    /// Pages of at most `maxl` lines, at most `cap` of them. `needed` is the page count, or `cap + 1` when
    /// more would be needed; `last` is then where page `cap` (the one to cut) starts.
    static func paginate(_ nt: Entries, maxw: Int, maxl: Int, cap: Int) -> (needed: Int, pages: [PageLines], last: Int) {
        var from = nt.skipSeps(0), pages: [PageLines] = [], last = -1
        while from < nt.count {
            if pages.count == cap { return (cap + 1, pages, last) }
            if pages.count == cap - 1 { last = from }
            let (ls, n) = wrap(nt, from: from, maxw: maxw, stop: maxl)
            if n <= maxl { pages.append(PageLines(lines: ls)); break }
            var lines = Array(ls.prefix(maxl))
            let end = pageCut(nt, lines[maxl - 1].lowerBound, lines[maxl - 1].upperBound)
            lines[maxl - 1] = lines[maxl - 1].lowerBound..<end
            pages.append(PageLines(lines: lines))
            from = nt.skipSeps(end)
        }
        return (pages.count, pages, last)
    }
}
