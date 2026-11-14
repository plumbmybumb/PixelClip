import XCTest
@testable import PixelClipKit

/// The clip's text wrapping (`TextWrap`, the rules of `core/include/textlay.h`): greedy wrap, French punctuation
/// glued to its word, the "…" of a cut line, and page cuts after a sentence end, else a comma, else the line end.
final class TextWrapTests: XCTestCase {
    static let fredoka = FontSelection(familyID: "fredoka", weight: 0.23)

    static let face: ReaderBoundFont.Face = {
        _ = BundledFontsTests.registered
        let font = try! ReaderFontRenderer.render(name: "Fredoka Medium", normalSize: 30, compactSize: 22, prefix: "test-font-") { size in
            FontCatalog.ctFont(for: fredoka, size: size)
        }
        return ReaderBoundFont(font).normal
    }()

    static let maxw = ClipCanvas.width - 24

    /// `n` copies of `word` (for building texts that break where a test wants).
    static func mots(_ n: Int, _ word: String = "mot") -> [String] { Array(repeating: word, count: n) }

    static func entries(_ text: String) -> TextWrap.Entries {
        var e = TextWrap.Entries(text)
        e.measure(face)
        return e
    }

    /// What a line says (separators as spaces).
    static func text(_ e: TextWrap.Entries, _ r: Range<Int>) -> String {
        String(String.UnicodeScalarView(e.trimmed(r).map { e.kind[$0] == .glyph ? e.cp[$0] : 0x20 }.compactMap(Unicode.Scalar.init)))
    }

    static func plainLines(_ text: String) -> Int { TextWrap.wrap(entries(text), from: 0, maxw: maxw).count }

    /// The most copies of `word` that wrap to `lines` lines.
    static func wordsFilling(lines: Int, _ word: String = "mot") -> Int {
        var k = 1
        while k < 200, plainLines(mots(k + 1, word).joined(separator: " ")) <= lines { k += 1 }
        return k
    }

    /// Pages of 3 lines as their lines' texts.
    static func pages(_ text: String, cap: Int = 10) -> [[String]] {
        let e = entries(text)
        return TextWrap.paginate(e, maxw: maxw, maxl: 3, cap: cap).pages.map { $0.lines.map { Self.text(e, $0) } }
    }

    func testFrenchPunctuationStaysWithItsWord() {
        let e = Self.entries((Self.mots(30) + ["fin", "!"]).joined(separator: " "))
        let lines = TextWrap.wrap(e, from: 0, maxw: Self.maxw).lines.map { Self.text(e, $0) }
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertTrue(lines.allSatisfy { !$0.hasPrefix("!") && !$0.hasPrefix(" ") && !$0.hasSuffix(" ") })
        XCTAssertTrue(lines.last!.hasSuffix("fin !"), lines.last!)
        // Every line fits.
        XCTAssertTrue(TextWrap.wrap(e, from: 0, maxw: Self.maxw).lines.allSatisfy { e.width($0.lowerBound, $0.upperBound) <= Self.maxw })
    }

    func testPagesSplitAtSentenceThenCommaThenLineEnd() {
        let tail = Self.mots(20)   // enough to need a second page
        // `prefix` fills two lines and puts one word on line 3.
        let prefix = Self.mots(Self.wordsFilling(lines: 2) + 1)
        XCTAssertEqual(Self.plainLines(prefix.joined(separator: " ")), 3)
        // A sentence end inside line 3: page 1 ends after it, page 2 starts with the next word.
        let s1 = prefix + ["fin.", "suite,"] + tail
        let l1 = Self.pages(s1.joined(separator: " "))
        XCTAssertGreaterThanOrEqual(l1.count, 2)
        XCTAssertEqual(l1[0].count, 3)
        XCTAssertTrue(l1[0][2].hasSuffix("fin."), l1[0][2])
        XCTAssertTrue(l1[1].joined(separator: " ").hasPrefix("suite,"))
        // A later comma on the same line doesn't beat the sentence end; no sentence end: the last comma.
        let s2 = prefix + ["virgule,", "fin"] + tail
        let l2 = Self.pages(s2.joined(separator: " "))
        XCTAssertTrue(l2[0][2].hasSuffix("virgule,"), l2[0][2])
        XCTAssertTrue(l2[1].joined(separator: " ").hasPrefix("fin mot"))
        // A sentence end followed by a closing quote counts.
        for quoted in [["«", "oui.»"], ["«", "oui", "!", "»"]] {
            let l3 = Self.pages((prefix + quoted + ["puis"] + tail).joined(separator: " "))
            XCTAssertTrue(l3[0].joined(separator: " ").hasSuffix(quoted.last!), l3[0].joined(separator: " "))
            XCTAssertTrue(l3[1].joined(separator: " ").hasPrefix("puis"))
        }
        // No punctuation in line 3: the page is the first three lines, whole.
        let plain = Self.mots(40).joined(separator: " ")
        let e = Self.entries(plain)
        let wrapped = TextWrap.wrap(e, from: 0, maxw: Self.maxw).lines.map { Self.text(e, $0) }
        XCTAssertEqual(Self.pages(plain)[0], Array(wrapped.prefix(3)))
        // Punctuation on lines 1–2 only (or inside a word) doesn't move the break.
        let s5 = ["un.", "deux,"] + Self.mots(40) + ["12,5"]
        let l5 = Self.pages(s5.joined(separator: " "))
        XCTAssertEqual(l5[0].count, 3)
        XCTAssertTrue(l5[0][2].hasSuffix("mot"), l5[0][2])
        // Every page ≤ 3 lines; nothing lost or repeated.
        for l in [l1, l2, l5] { XCTAssertTrue(l.allSatisfy { (1...3).contains($0.count) }) }
        XCTAssertEqual(l1.flatMap { $0 }.joined(separator: " "), s1.joined(separator: " "))
        XCTAssertEqual(l5.flatMap { $0 }.joined(separator: " "), s5.joined(separator: " "))
    }

    func testCapAndEllipsis() {
        let text = Self.mots(150, "WWW").joined(separator: " ")
        let e = Self.entries(text)
        let (needed, pages, last) = TextWrap.paginate(e, maxw: Self.maxw, maxl: 3, cap: 4)
        XCTAssertEqual(needed, 5, "more than the cap")
        XCTAssertEqual(pages.count, 4)
        XCTAssertGreaterThan(last, 0)
        // The cut line: as much as fits before "…", at a word boundary.
        let (r, ell) = TextWrap.ellipsisLine(e, from: last, face: Self.face, maxw: Self.maxw)
        XCTAssertEqual(ell, [0x2026])
        let line = Self.text(e, r)
        XCTAssertTrue(line.hasSuffix("WWW"), line)
        XCTAssertLessThanOrEqual(e.width(r.lowerBound, r.upperBound) + Self.face.glyph(0x2026).advance, Self.maxw)
        // Longer texts are laid out up to `maxBytes`.
        XCTAssertEqual(TextWrap.Entries(String(repeating: "a", count: 2_000)).count, TextWrap.maxBytes)
    }
}
