import CoreText
import XCTest
@testable import PixelClipKit

/// Reader mode (PROTOCOL §5c): the tokeniser/timing/ORP cases of `core/tests/test_rsvp.c`, the font
/// renderer and document, the painter port, importers (Markdown, EPUB, readability), the composer,
/// the pusher and the virtual clip reading with pause and seek.
final class ReaderTests: XCTestCase {

    // MARK: Helpers

    /// Words of a byte string (no title break), as the clip's `rsvp_tokenize` sees them.
    func tok(_ bytes: [UInt8], titleBreak: Bool = false) -> [RSVPWord] { RSVPText.tokenize(Data(bytes), titleBreak: titleBreak) }
    func tok(_ s: String, titleBreak: Bool = false) -> [RSVPWord] { tok(Array(s.utf8), titleBreak: titleBreak) }

    func w(_ core: Int, _ flags: RSVPWord.Flags = [], glyphs: Int? = nil) -> RSVPWord {
        RSVPWord(offset: 0, byteCount: glyphs ?? core, glyphs: glyphs ?? core, lead: 0, core: core, flags: flags, text: "")
    }

    /// The test typeface: SF Pro Medium through Core Text (what the app's default resolves to on macOS too).
    static let testFont: ReaderFont = {
        try! ReaderFontRenderer.render(name: "SF Pro") { size in
            FontCatalog.ctFont(for: FontSelection(familyID: FontCatalog.sfPro, weight: 0.23), size: size)
        }
    }()

    // MARK: Tokeniser (test_tok_*)

    func testTokeniserASCII() {
        let t = "Hello, world. This is  a test!\n\nNew para; here"
        let ws = tok(t)
        XCTAssertEqual(ws.map(\.text), ["Hello,", "world.", "This", "is", "a", "test!", "New", "para;", "here"])
        XCTAssertEqual(ws[0].flags, .comma); XCTAssertEqual(ws[0].offset, 0)
        XCTAssertEqual(ws[1].flags, .sentence)
        XCTAssertEqual(ws[2].flags, [])
        XCTAssertEqual(ws[4].offset, 23)
        XCTAssertEqual(ws[5].flags, [.sentence, .paragraph])
        XCTAssertEqual(ws[7].flags, .comma)
        XCTAssertEqual(ws[8].flags, [])
        XCTAssertEqual(ws[0].glyphs, 6); XCTAssertEqual(ws[0].lead, 0); XCTAssertEqual(ws[0].core, 5)
        XCTAssertTrue(tok("").isEmpty)
        XCTAssertTrue(tok(" \n\t \r\n ").isEmpty)
    }

    func testTokeniserFrench() {
        let t = "L’été, à Paris — c’était « magnifique » ! Peut-être…"
        let ws = tok(t)
        XCTAssertEqual(ws.map(\.text), ["L’été,", "à", "Paris", "—", "c’était", "«", "magnifique", "»", "!", "Peut-être…"])
        XCTAssertEqual(ws[0].glyphs, 6); XCTAssertEqual(ws[0].byteCount, 10); XCTAssertEqual(ws[0].core, 5); XCTAssertEqual(ws[0].flags, .comma)
        XCTAssertEqual(ws[1].glyphs, 1)
        XCTAssertEqual(ws[3].flags, .comma); XCTAssertEqual(ws[3].core, 0)
        XCTAssertEqual(ws[4].glyphs, 7); XCTAssertEqual(ws[4].core, 7)
        XCTAssertEqual(ws[8].flags, .sentence)
        XCTAssertEqual(ws[9].flags, .sentence); XCTAssertEqual(ws[9].glyphs, 10); XCTAssertEqual(ws[9].core, 9); XCTAssertEqual(ws[9].lead, 0)

        // No-break spaces keep guillemets and ! with their word.
        let t2 = "«\u{A0}Bonjour\u{A0}!\u{A0}» dit-il."
        let w2 = tok(t2)
        XCTAssertEqual(w2.map(\.text), ["«\u{A0}Bonjour\u{A0}!\u{A0}»", "dit-il."])
        XCTAssertEqual(w2[0].flags, .sentence, "the closing » is skipped, the ! counts")
        XCTAssertEqual(w2[0].lead, 2); XCTAssertEqual(w2[0].core, 7)
        XCTAssertEqual(w2[0].orp, 4, "Bonjour: 7 letters → 2, after « + nbsp")
        XCTAssertEqual(w2[1].flags, .sentence)

        // Dashes end the word they're attached to.
        let w3 = tok("oui—non 1914–1918")
        XCTAssertEqual(w3.map(\.text), ["oui—", "non", "1914–", "1918"])
        XCTAssertEqual(w3[0].flags, .comma)
    }

    func testTokeniserNumbersAndWhitespace() {
        let ws = tok("Il a 1 234,56 € et 3.14 ou 42%. (vraiment) \"Oui.\"")
        XCTAssertEqual(ws.count, 11)
        XCTAssertEqual(ws[3].text, "234,56"); XCTAssertEqual(ws[3].flags, [])
        XCTAssertEqual(ws[4].text, "€")
        XCTAssertEqual(ws[6].text, "3.14"); XCTAssertEqual(ws[6].flags, [])
        XCTAssertEqual(ws[8].text, "42%."); XCTAssertEqual(ws[8].flags, .sentence); XCTAssertEqual(ws[8].core, 2)
        XCTAssertEqual(ws[9].text, "(vraiment)"); XCTAssertEqual(ws[9].lead, 1); XCTAssertEqual(ws[9].core, 8); XCTAssertEqual(ws[9].flags, [])
        XCTAssertEqual(ws[10].text, "\"Oui.\""); XCTAssertEqual(ws[10].flags, .sentence)

        // CRLF blank line, spaces on a blank line, single newlines, U+2029, em space.
        let w2 = tok("a  \t b\r\n\r\nc\n \n d\ne\u{2029}f\u{2003}g")
        XCTAssertEqual(w2.map(\.text), ["a", "b", "c", "d", "e", "f", "g"])
        XCTAssertEqual(w2.map(\.flags), [[], .paragraph, .paragraph, [], .paragraph, [], []])
        // "\r\r" is two line breaks, "\r\n" one.
        let w3 = tok("x\r\ry\r\nz")
        XCTAssertEqual(w3.map(\.flags), [.paragraph, [], []])
        // NUL and control characters separate; a BOM is a separator.
        XCTAssertEqual(tok([0x61, 0, 0x62, 1, 0x63]).count, 3)
        let w4 = tok("\u{FEFF}Hi there")
        XCTAssertEqual(w4.count, 2); XCTAssertEqual(w4[0].offset, 3)
    }

    func testTokeniserLongWordsAndInvalidBytes() {
        let w1 = tok(String(repeating: "x", count: 40))
        XCTAssertEqual(w1.map(\.glyphs), [32, 8]); XCTAssertEqual(w1[1].offset, 32)
        let w2 = tok(String(repeating: "é", count: 40))
        XCTAssertEqual(w2.map(\.byteCount), [64, 16]); XCTAssertEqual(w2[1].offset, 64)
        let w3 = tok([0x61, 0x62, 0xFF, 0x63, 0x64, 0x20, 0xC3, 0x20, 0x65, 0x80])
        XCTAssertEqual(w3.map(\.glyphs), [5, 1, 2])
        let w4 = tok([0x61, 0x62, 0xE2, 0x80])
        XCTAssertEqual(w4.count, 1); XCTAssertEqual(w4[0].byteCount, 4); XCTAssertEqual(w4[0].glyphs, 3)
    }

    func testTitleBreakAndTitle() {
        let t = "Le titre\nPremier mot. Suite\n\nFin"
        let ws = tok(t, titleBreak: true)
        XCTAssertEqual(ws.count, 6)
        XCTAssertEqual(ws[1].text, "titre"); XCTAssertEqual(ws[1].flags, .paragraph, "end of the title line")
        XCTAssertEqual(ws[3].flags, .sentence)
        XCTAssertEqual(ws[4].text, "Suite"); XCTAssertEqual(ws[4].flags, .paragraph)
        XCTAssertEqual(tok(t)[1].flags, [], "without the option a single newline is no break")

        XCTAssertEqual(RSVPText.title(of: Data("\u{FEFF}  Le Petit Livre  \nreste".utf8)), "Le Petit Livre")
        XCTAssertEqual(RSVPText.title(of: Data("Une ligne".utf8)), "Une ligne")
        XCTAssertEqual(RSVPText.title(of: Data("\r\nx".utf8)), "")
        XCTAssertEqual(RSVPText.title(of: Data([0x61, 0xFF, 0x09, 0x62])), "a? b")
        let file = RSVPText(file: "Le titre\nPremier mot.")
        XCTAssertEqual(file.title, "Le titre")
        XCTAssertEqual(file.wordCount, 4, "the title is read first")
    }

    // MARK: Timing and ORP (test_orp_rule, test_timing)

    func testORPRule() {
        let expect = [0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4]
        XCTAssertEqual((0...20).map(ORP.index(forLength:)), expect)
        XCTAssertEqual(ORP.index(forLength: 1000), 4)
        let ws = tok("\"quoi\" !? (l’homme)")
        XCTAssertEqual(ws.map(\.orp), [2, 1, 3], "lead + ORP(core); no letters → ORP(glyphs)")
    }

    func testTimingTable() {
        let tab: [(Int, RSVPWord.Flags, Int)] = [
            (3, [], 200), (7, [], 200), (8, [], 260), (11, [], 260), (12, [], 320), (20, [], 320),
            (3, .comma, 300), (3, .sentence, 400), (3, [.comma, .sentence], 400), (8, .comma, 360), (12, .sentence, 520), (5, .paragraph, 200),
        ]
        for (core, flags, ms) in tab { XCTAssertEqual(RSVPTiming.wordMs(w(core, flags), wpm: 300), ms, "core \(core) \(flags)") }
        XCTAssertEqual(RSVPTiming.wordMs(w(5), wpm: 250), 240)
        XCTAssertEqual(RSVPTiming.wordMs(w(5), wpm: 600), 100)
        XCTAssertEqual(RSVPTiming.wordMs(w(5), wpm: 1000), 60)
        XCTAssertEqual(RSVPTiming.wordMs(w(5), wpm: 450), 133)
        XCTAssertEqual(RSVPTiming.wordMs(w(5), wpm: 0), 1200, "clamped to 50 wpm")
        XCTAssertEqual(RSVPTiming.wordMs(w(5), wpm: 60_000), 40, "clamped to 1500 wpm")
        XCTAssertEqual(RSVPTiming.blankMs(w(5)), 0)
        XCTAssertEqual(RSVPTiming.blankMs(w(5, .paragraph)), 300)
        XCTAssertEqual(RSVPTiming.wordMs(w(0, glyphs: 12), wpm: 300), 320, "a word without letters uses its glyphs")

        let ws = tok("One two three, four.\n\nFive extraordinary words here.")
        let sum = ws.reduce(0) { $0 + RSVPTiming.slotMs($1, wpm: 300) }
        XCTAssertEqual(RSVPTiming.totalMs(ws, wpm: 300), sum, "exact at 300 wpm")
        XCTAssertEqual(RSVPTiming.minutes(totalMs: 0), 1)
        XCTAssertEqual(RSVPTiming.minutes(totalMs: 89_999), 1)
        XCTAssertEqual(RSVPTiming.minutes(totalMs: 90_000), 2)
        XCTAssertEqual(RSVPTiming.minutes(totalMs: 240_000), 4)
        XCTAssertEqual(RSVPTiming.endCardText(words: 1234, minutes: 4), "1 234 words · 4 min")
        XCTAssertEqual(RSVPTiming.endCardText(words: 1, minutes: 1), "1 word · 1 min")

        // The schedule: positions, blanks, the end.
        let s = RSVPSchedule(words: ws, wpm: 300)
        XCTAssertEqual(s.totalMs, sum)
        XCTAssertEqual(s.position(from: 0, elapsedMs: 0), .word(0, blank: false))
        let para = ws.firstIndex { $0.flags.contains(.paragraph) }!
        XCTAssertEqual(s.position(from: 0, elapsedMs: s.starts[para] + s.visible[para] + 10), .word(para, blank: true))
        XCTAssertEqual(s.position(from: 2, elapsedMs: 0), .word(2, blank: false))
        XCTAssertEqual(s.position(from: 0, elapsedMs: sum), .end)
    }

    // MARK: Font

    func testFontDocumentRoundTrip() throws {
        let doc = Self.testFont.document
        let json = try ClipJSON.encoder().encode(doc)
        XCTAssertLessThanOrEqual(json.count, ReaderFontDocument.maxJSONBytes)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["glyphs", "advance", "cell_w", "cell_h", "baseline", "atlas_white", "atlas_accent", "compact"],
                       "the normal face's keys sit at the top level, compact nested")
        XCTAssertEqual((obj["compact"] as? [String: Any])?.count, 7)
        XCTAssertEqual(try ClipJSON.decoder().decode(ReaderFontDocument.self, from: json), doc)
        XCTAssertNil(doc.validationProblem)
        // The C test's shape: unknown keys ignored, compact optional.
        let c = #"{"glyphs":"ab?","advance":[10,10,5],"cell_w":12,"cell_h":20,"baseline":16,"atlas_white":"tw","atlas_accent":"ta","extra":{"nested":[1,2,{"x":null}]}}"#
        let parsed = try ClipJSON.decoder().decode(ReaderFontDocument.self, from: Data(c.utf8))
        XCTAssertNil(parsed.compact)
        XCTAssertEqual(parsed.normal.codePoints, [0x61, 0x62, 0x3F])
        XCTAssertNil(parsed.validationProblem)
        var bad = parsed
        bad.normal.advance = [1]
        XCTAssertNotNil(bad.validationProblem)
    }

    func testFontRendererGeometryAndStableIDs() throws {
        let f = Self.testFont
        let glyphCount = ReaderFontRenderer.glyphs.unicodeScalars.count
        XCTAssertEqual(glyphCount, 210)
        XCTAssertLessThanOrEqual(glyphCount, ReaderFontDocument.maxGlyphs)
        for (k, face) in [f.normal, f.compact].enumerated() {
            XCTAssertEqual(face.white.count, glyphCount)
            XCTAssertEqual(face.accent.count, glyphCount)
            XCTAssertEqual(face.document.advance.count, glyphCount)
            XCTAssertTrue(face.white.allSatisfy { $0.width == face.document.cellW && $0.height == face.document.cellH })
            XCTAssertLessThanOrEqual(face.document.cellH, ClipCanvas.height)
            XCTAssertLessThanOrEqual(face.capHeight, k == 0 ? 96.5 : 64.5)
        }
        XCTAssertGreaterThan(f.normal.pointSize, f.compact.pointSize)
        // Ids: reader-font-<hash>-{n,na,c,ca}, stable for the same typeface and sizes.
        XCTAssertEqual(f.atlases.map(\.id), ["n", "na", "c", "ca"].map { "reader-font-\(f.hash)-\($0)" })
        XCTAssertTrue(f.atlases.allSatisfy { HCA.isValidAssetID($0.id) })
        let again = try ReaderFontRenderer.render(name: "SF Pro") { size in
            FontCatalog.ctFont(for: FontSelection(familyID: FontCatalog.sfPro, weight: 0.23), size: size)
        }
        XCTAssertEqual(again.atlases.map(\.id), f.atlases.map(\.id))
        XCTAssertEqual(again.atlases.map(\.sha256), f.atlases.map(\.sha256))
        let other = try ReaderFontRenderer.render(name: "SF Pro Bold") { size in
            FontCatalog.ctFont(for: FontSelection(familyID: FontCatalog.sfPro, weight: 0.4), size: size)
        }
        XCTAssertNotEqual(other.hash, f.hash)
        // White ORP: same atlases, both document keys on the white ones.
        let mono = f.withAccentORP(false)
        XCTAssertEqual(mono.id, "reader-font-\(f.hash)-w")
        XCTAssertEqual(mono.document.normal.atlasAccent, mono.document.normal.atlasWhite)
        XCTAssertEqual(mono.atlases.count, 2)
        // Atlases decode as glyph atlases of the cell size.
        let file = try HCAFile(data: f.atlases[0].data)
        XCTAssertTrue(file.isGlyphAtlas)
        XCTAssertEqual(file.width, f.normal.document.cellW)
        XCTAssertEqual(file.frameCount, glyphCount)
        print("READER_FONT_SIZES normal \(f.normal.pointSize)pt cap \(String(format: "%.1f", f.normal.capHeight)) cell \(f.normal.document.cellW)x\(f.normal.document.cellH) baseline \(f.normal.document.baseline) · compact \(f.compact.pointSize)pt cap \(String(format: "%.1f", f.compact.capHeight)) cell \(f.compact.document.cellW)x\(f.compact.document.cellH) · atlases " + f.atlases.map { "\($0.id.suffix(2)) \($0.data.count)" }.joined(separator: ", ") + " · total \(f.atlasBytes)")
    }

    func testPainterPlacesORPOnTheColumn() throws {
        let font = ReaderBoundFont(Self.testFont)
        // A 12-glyph word fits in the normal size with its ORP centred on x = 230.
        let (lay, face) = try XCTUnwrap(ReaderPreview.layout("connaissance", font: font))
        XCTAssertFalse(lay.compact); XCTAssertFalse(lay.shifted)
        let orp = lay.glyphs[lay.orp]
        XCTAssertEqual(orp.x + orp.advance / 2, ReaderPreview.orpX)
        XCTAssertEqual(face.document.cellH, font.normal.document.cellH)
        // 20 glyphs → compact; 30 → shifted or clipped in compact.
        XCTAssertTrue(try XCTUnwrap(ReaderPreview.layout("internationalisation", font: font)).0.compact)
        XCTAssertFalse(try XCTUnwrap(ReaderPreview.layout("internationalisation", font: font)).0.shifted)
        let long = try XCTUnwrap(ReaderPreview.layout("anticonstitutionnellementissime", font: font)).0
        XCTAssertTrue(long.compact && (long.shifted || long.clipped))

        // The frame: accent pixels only in the ORP glyph's cell, ticks at x 229–230, pause mark.
        let frame = ReaderPreview.frame(word: "lecture", font: font, paused: true)
        let g = ReaderPreview.geometry(font)
        let (l2, f2) = try XCTUnwrap(ReaderPreview.layout("lecture", font: font))
        let accent565 = Set(f2.accent.flatMap(\.pixels)).subtracting(Set(f2.white.flatMap(\.pixels)))
        var accentXs = Set<Int>()
        for y in g.bandY..<(g.bandY + g.bandH) {
            for x in 0..<ClipCanvas.width where accent565.contains(frame.pixels[y * ClipCanvas.width + x]) { accentXs.insert(x) }
        }
        let o = l2.glyphs[l2.orp]
        XCTAssertFalse(accentXs.isEmpty)
        XCTAssertTrue(accentXs.allSatisfy { $0 >= o.x && $0 < o.x + f2.document.cellW }, "accent only in the ORP cell")
        XCTAssertEqual(frame.pixels[(g.bandY - 6) * ClipCanvas.width + 229], ReaderPreview.tickColor)
        XCTAssertEqual(frame.pixels[(g.bandY + g.bandH + 6) * ClipCanvas.width + 230], ReaderPreview.tickColor)
        XCTAssertEqual(frame.pixels[(g.bandY - 6) * ClipCanvas.width + 231], 0)
        let mark = 12 * ClipCanvas.width + 514   // inside the corner box's first bar
        XCTAssertEqual(frame.pixels[mark], ReaderPreview.pauseColor)
        XCTAssertEqual(ReaderPreview.frame(word: "lecture", font: font).pixels[mark], 0)
        // Blank band and end card.
        let blank = ReaderPreview.frame(word: nil, font: font)
        XCTAssertEqual(blank.pixels.filter { $0 != 0 }.count, 2 * 2 * 12, "only the two ticks")
        let card = ReaderPreview.endCard(words: 1234, minutes: 4, font: font)
        XCTAssertGreaterThan(card.pixels.filter { accent565.contains($0) }.count, 20, "“fin” in the accent")
    }

    // MARK: Importers

    func testMarkdownStripping() {
        let md = """
        ---
        title: "Mon carnet"
        ---
        # Mon carnet

        Un **très** _bon_ [lien](https://x.fr) et `du code`, ![image](a.png) voilà.

        ## Deuxième partie

        - premier point
        - second point

        ```swift
        let x = 1
        ```

        > Une citation.
        """
        let t = TextImporter.markdown(md, fallbackTitle: "carnet.md")
        XCTAssertEqual(t.title, "Mon carnet")
        XCTAssertEqual(t.body, "Un très bon lien et du code,  voilà.\n\nDeuxième partie\n\npremier point\n\nsecond point\n\nUne citation.")
        XCTAssertEqual(t.chapters.map(\.title), ["Deuxième partie"])
        let off = t.chapters[0].offset
        XCTAssertTrue(String(decoding: Data(t.body.utf8).dropFirst(off), as: UTF8.self).hasPrefix("Deuxième partie"))
    }

    func testPlainTextTitle() {
        let t = TextImporter.plain("Le Horla\r\n\r\n8 mai. — Quelle journée admirable !\r\nJ’ai passé toute la matinée.")
        XCTAssertEqual(t.title, "Le Horla")
        XCTAssertEqual(t.body, "8 mai. — Quelle journée admirable !\nJ’ai passé toute la matinée.")
        let long = TextImporter.plain(String(repeating: "mot ", count: 60), fallbackTitle: "notes.txt")
        XCTAssertEqual(long.title, "notes")
    }

    func testEPUBSpineChaptersAndText() throws {
        let epub = Self.makeEPUB()
        let t = try TextImporter.epub(epub, fallbackTitle: "livre.epub")
        XCTAssertEqual(t.kind, .epub)
        XCTAssertEqual(t.title, "Le Petit Livre")
        XCTAssertEqual(t.chapters.map(\.title), ["Premier chapitre", "Le second"], "names from the nav document, spine order")
        XCTAssertFalse(t.body.contains("<"), "no markup")
        XCTAssertFalse(t.body.contains("Couverture"), "non-linear spine items are skipped")
        XCTAssertTrue(t.body.hasPrefix("Chapitre un\n\nIl était une fois, dans une ville d’eau, un clip qui lisait."))
        XCTAssertTrue(t.body.contains("Fin & suite"), "entities decoded")
        // Chapter offsets point at their text, and become word indices of the clip file.
        let (doc, file) = ReaderDocument.make(t)
        XCTAssertEqual(doc.chapters.count, 2)
        let words = RSVPText(fileData: file).words
        XCTAssertEqual(words[doc.chapters[0].word].text, "Chapitre")
        XCTAssertEqual(words[doc.chapters[1].word].text, "Deuxième")
        XCTAssertEqual(doc.wordCount, words.count)
        XCTAssertEqual(doc.clipTextID, ReaderDocument.clipID(file))
        XCTAssertTrue(file.starts(with: Data("Le Petit Livre\n".utf8)))
    }

    func testReadabilityOnSavedPage() throws {
        let url = Paths.fixturesDir.appendingPathComponent("reader/article-fr.html")
        let html = HTMLText.decode(try Data(contentsOf: url))
        let t = TextImporter.html(html, url: URL(string: "https://example.com/trains-de-nuit"))
        XCTAssertEqual(t.title, "Le retour des trains de nuit")
        XCTAssertEqual(t.origin, "Le Petit Rail")
        XCTAssertTrue(t.body.hasPrefix("Il est 21 h 47 gare d’Austerlitz, et le quai numéro\u{A0}3"), String(t.body.prefix(80)))
        XCTAssertTrue(t.body.hasSuffix("ces trains auront leur place sur les rails."))
        for kept in ["Une couchette, un livre et la mer au réveil", "Le train de nuit, c’est la lenteur choisie, pas subie.", "«\u{A0}On part le soir"] {
            XCTAssertTrue(t.body.contains(kept), kept)
        }
        for dropped in ["cookies", "Newsletter", "commentaires", "Publicité", "Facebook", "Accepter", "dataLayer", "Les plus lus",
                        "À lire aussi", "Camille Durand", "Mentions légales", "Actualités", "Aller au contenu"] {
            XCTAssertFalse(t.body.contains(dropped), dropped)
        }
        XCTAssertEqual(t.body.components(separatedBy: "\n\n").count, 8, "paragraphs, heading and quote")
    }

    func testDocumentTruncatesAtOneMegabyte() {
        let para = String(repeating: "mot ", count: 249) + "fin."
        let body = Array(repeating: para, count: 1100).joined(separator: "\n\n")
        let (doc, file) = ReaderDocument.make(ImportedText(title: "Long", body: body, kind: .text))
        XCTAssertTrue(doc.truncated)
        XCTAssertLessThanOrEqual(file.count, ReaderLimits.maxTextBytes)
        XCTAssertTrue(String(decoding: file, as: UTF8.self).hasSuffix("fin."), "cut at a paragraph")
    }

    // MARK: Composer and Tonight

    func testComposerCarriesReaderItemsAndMoments() throws {
        let base = Date(timeIntervalSince1970: 1_791_655_200)
        let reader = PlaylistItem.reader(text: "text-abc", font: "reader-font-12345678", wpm: 320)
        let layer = TonightLayer(extras: [.init(id: "x-read", item: reader, title: "Le Horla"),
                                          .init(id: "e-photo", item: .asset("photo-1", durationMs: 10_000), title: "Photo")],
                                 order: ["x-read", "e-photo"],
                                 moments: [Moment(id: "t-r", at: Int(base.timeIntervalSince1970) + 600,
                                                  content: .reader(text: "text-abc", font: "reader-font-12345678", wpm: 320),
                                                  durationS: 900, title: "Lecture")])
        let inputs = PlaylistComposer.Inputs(tonight: layer)
        let pl = PlaylistComposer.playlist(inputs, now: base)
        XCTAssertEqual(pl.items.first, reader, "Tonight's order puts the reading first")
        XCTAssertEqual(pl.queue?.first?.type, .reader)
        XCTAssertEqual(pl.queue?.first?.text, "text-abc")
        XCTAssertEqual(pl.queue?.first?.durationMs, 900_000)
        XCTAssertEqual(pl.textIDs, ["text-abc"])
        XCTAssertEqual(pl.fontIDs, ["reader-font-12345678"])
        // Wire format (§5c): type, text, font, wpm, loop, duration_ms; from_word only when set.
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: ClipJSON.encoder().encode(pl)) as? [String: Any])
        let item = try XCTUnwrap((json["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["type"] as? String, "reader")
        XCTAssertEqual(item["text"] as? String, "text-abc")
        XCTAssertEqual(item["font"] as? String, "reader-font-12345678")
        XCTAssertEqual(item["wpm"] as? Int, 320)
        XCTAssertEqual(item["loop"] as? Bool, false)
        XCTAssertEqual(item["duration_ms"] as? Int, 0)
        XCTAssertNil(item["from_word"])
        let decoded = try ClipJSON.decoder().decode(Playlist.self, from: ClipJSON.encoder().encode(pl))
        XCTAssertEqual(decoded, pl)
        XCTAssertTrue(TonightPlan(slots: PlaylistComposer.plan(inputs).slots).issues(now: base, clock: .synced(at: base)).isEmpty)
        // A missing text or font drops only that reader item.
        let filtered = ReaderPusher.filter(pl, failedTexts: ["text-abc"], failedFonts: [])
        XCTAssertEqual(filtered.items.map(\.type), [.asset])
        XCTAssertNil(filtered.queue)
    }

    // MARK: Virtual clip

    /// Puts a reading on the virtual clip through the pusher and returns the clip, the clock and the words.
    func readingClip(_ body: String, wpm: Int = 300, extra: [PlaylistItem] = [],
                     fromWord: Int? = nil) async throws -> (VirtualClipClient, ClockBox, ReaderDocument, [RSVPWord]) {
        let base = Date(timeIntervalSince1970: 1_791_655_200)
        let clock = ClockBox(base)
        let clip = VirtualClipClient(options: .instant, clock: { clock.now })
        let (doc, file) = ReaderDocument.make(ImportedText(title: "Essai", body: body, kind: .pasted))
        let font = Self.testFont
        let playlist = Playlist(items: [.reader(text: doc.clipTextID, font: font.id, wpm: wpm, fromWord: fromWord)] + extra)
        let r = try await ReaderPusher(client: clip).push(texts: [.init(id: doc.clipTextID, data: file, title: doc.title)], fonts: [font],
                                                          playlist: playlist,
                                                          time: TimeSync(epoch: Int(base.timeIntervalSince1970), tzOffsetS: 7200))
        XCTAssertEqual(r.textsPut, [doc.clipTextID])
        XCTAssertEqual(Set(r.uploadedAtlases), Set(font.atlases.map(\.id)))
        XCTAssertEqual(r.fontsPut, [font.id])
        XCTAssertEqual(r.playlist?.items.first?.type, .reader)
        return (clip, clock, doc, RSVPText(fileData: file).words)
    }

    func testVirtualClipReadsPausesAndSeeks() async throws {
        let body = (1...60).map { "mot\($0)" }.joined(separator: " ") + ". Fin du texte."
        let (clip, clock, doc, words) = try await readingClip(body)
        let schedule = RSVPSchedule(words: words, wpm: 300)
        let t0 = clock.now
        var d = await clip.display()
        XCTAssertEqual(d.nowShowing, "reader:\(doc.clipTextID)")
        var now = await clip.readerNow()
        XCTAssertEqual(now?.word, 0)
        XCTAssertEqual(now?.words, words.count)

        // Words advance with the §5c clock (the title "Essai" first, then its paragraph blank).
        clock.now = t0 + Double(schedule.starts[10] + 5) / 1000
        now = await clip.readerNow()
        XCTAssertEqual(now?.word, 10)
        d = await clip.display()
        XCTAssertTrue(d.key.hasPrefix("r-\(doc.clipTextID)-\(Self.testFont.id)-10-false"), d.key)

        // Pause (the BOOT short press): time passes, the word stays, the mark shows.
        await clip.pressButton()
        clock.now += 30
        now = await clip.readerNow()
        XCTAssertEqual(now?.word, 10)
        XCTAssertEqual(now?.paused, true)
        d = await clip.display()
        XCTAssertEqual(d.frame.pixels[12 * ClipCanvas.width + 514], ReaderPreview.pauseColor, "the pause mark")
        // Resume: it carries on from there.
        await clip.pressButton()
        clock.now += Double(schedule.starts[13] - schedule.starts[10] + 5) / 1000
        now = await clip.readerNow()
        XCTAssertEqual(now?.word, 13)
        XCTAssertEqual(now?.paused, false)

        // POST /reader over the protocol: seek, pause, status, progress in GET /texts.
        try await clip.readerControl(.seek(40))
        var status = try await clip.reader()
        XCTAssertEqual(status.text, doc.clipTextID)
        XCTAssertEqual(status.word, 40)
        XCTAssertEqual(status.wpm, 300)
        try await clip.readerControl(.pause)
        try await clip.endSession()
        clock.now += 5
        status = try await clip.reader()
        XCTAssertTrue(status.paused)
        XCTAssertEqual(status.word, 40)
        try await clip.readerControl(.resume)
        let texts = try await clip.texts()
        XCTAssertEqual(texts.first?.progressWord, 40, "saved on pause")
        XCTAssertEqual(texts.first?.title, "Essai")
        XCTAssertEqual(texts.first?.words, words.count)
        try await clip.endSession()

        // To the end: the "fin" card, then it starts over.
        clock.now += Double(schedule.remainingMs(from: 40) + 500) / 1000
        if case .readerEnd(_, _, let n, let m) = await clip.display().content {
            XCTAssertEqual(n, words.count); XCTAssertEqual(m, 1)
        } else { XCTFail("expected the end card") }
        clock.now += 2.6
        now = await clip.readerNow()
        XCTAssertEqual(now?.word, 0, "only item: starts over from the top")
        let after = try await clip.texts()
        XCTAssertEqual(after.first?.progressWord, 0, "a finished text saves word 0 (firmware reader_save)")
        do { try await clip.readerControl(.seek(words.count)); XCTFail("seek past the end accepted") } catch ClipError.http(let code, let env) {
            XCTAssertEqual(code, 422); XCTAssertEqual(env?.error, "invalid_word")
        }
        let s = try await clip.status()
        XCTAssertEqual(s.playlist.current, "reader:\(doc.clipTextID)")
    }

    func testVirtualClipReaderValidationAndRotation() async throws {
        let (clip, clock, doc, words) = try await readingClip("Un deux trois.", extra: [.scene("sand", durationMs: 5000, transition: .cut)],
                                                               fromWord: 2)
        // from_word applies on the first play after the playlist load.
        let now = await clip.readerNow()
        XCTAssertEqual(now?.word, 2)
        // After the text and its card, the rotation moves on to the scene.
        let schedule = RSVPSchedule(words: words, wpm: 300)
        clock.now += Double(schedule.remainingMs(from: 2) + RSVPTiming.endCardMs + 1000) / 1000
        let d = await clip.display()
        XCTAssertEqual(d.nowShowing, "scene:sand")
        // 422s for unknown content and bad speeds; 409 when nothing is read.
        do {
            try await clip.putPlaylist(Playlist(items: [.reader(text: "text-nope", font: Self.testFont.id, wpm: 300)]))
            XCTFail("unknown text accepted")
        } catch ClipError.http(let code, let env) { XCTAssertEqual(code, 422); XCTAssertEqual(env?.error, "unknown_text") }
        do {
            try await clip.putPlaylist(Playlist(items: [.reader(text: doc.clipTextID, font: "reader-font-00000000", wpm: 300)]))
            XCTFail("unknown font accepted")
        } catch ClipError.http(let code, let env) { XCTAssertEqual(code, 422); XCTAssertEqual(env?.error, "unknown_font") }
        do {
            try await clip.putPlaylist(Playlist(items: [.reader(text: doc.clipTextID, font: Self.testFont.id, wpm: 5000)]))
            XCTFail("bad wpm accepted")
        } catch ClipError.http(let code, _) { XCTAssertEqual(code, 422) }
        try await clip.putPlaylist(Playlist(items: [.scene("sand", durationMs: 5000)]))
        do { try await clip.readerControl(.pause); XCTFail("paused nothing") } catch ClipError.http(let code, let env) {
            XCTAssertEqual(code, 409); XCTAssertEqual(env?.error, "no_reader")
        }
        // A font document needs its atlases; DELETE /texts takes reader items out of the playlist.
        do {
            var doc2 = Self.testFont.document
            doc2.normal.atlasWhite = "reader-font-ffffffff-n"
            try await clip.putFont(id: "reader-font-ffffffff", doc2)
            XCTFail("font without atlases accepted")
        } catch ClipError.http(let code, let env) { XCTAssertEqual(code, 422); XCTAssertEqual(env?.error, "unknown_asset") }
        try await clip.putPlaylist(Playlist(items: [.reader(text: doc.clipTextID, font: Self.testFont.id, wpm: 300)]))
        try await clip.deleteText(id: doc.clipTextID)
        let pl = try await clip.playlist()
        XCTAssertTrue(pl.items.isEmpty)
        // The pusher's clean-up removes atlases no reader item uses any more.
        let deleted = try await ReaderPusher(client: clip).cleanUnusedAtlases(keeping: pl)
        XCTAssertEqual(Set(deleted), Set(Self.testFont.atlases.map(\.id)))
    }

    // MARK: EPUB fixture

    static func makeEPUB() -> Data {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Le Petit Livre</dc:title><dc:language>fr</dc:language></metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>
            <item id="c1" href="text/ch%201.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>
          </manifest>
          <spine><itemref idref="cover" linear="no"/><itemref idref="c1"/><itemref idref="c2"/></spine>
        </package>
        """
        let nav = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
        <nav epub:type="toc"><ol><li><a href="text/ch%201.xhtml">Premier chapitre</a></li><li><a href="text/ch2.xhtml#s">Le second</a></li></ol></nav>
        </body></html>
        """
        let cover = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Couverture</p></body></html>"
        let ch1 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>c1</title><style>p { margin: 0 }</style></head>
        <body><h1>Chapitre un</h1><p>Il était une fois, dans une ville d’eau,
        un clip qui <em>lisait</em>.</p><p>Il lisait vite.<br/>Très vite.</p></body></html>
        """
        let ch2 = """
        <html xmlns="http://www.w3.org/1999/xhtml"><body><section id="s"><h2>Deuxième</h2>
        <p>La suite arrive&#160;: Fin &amp; suite.</p></section></body></html>
        """
        return ZipWriter.archive([("mimetype", Data("application/epub+zip".utf8), false),
                                  ("META-INF/container.xml", Data(container.utf8), true),
                                  ("OEBPS/content.opf", Data(opf.utf8), true),
                                  ("OEBPS/nav.xhtml", Data(nav.utf8), true),
                                  ("OEBPS/text/cover.xhtml", Data(cover.utf8), false),
                                  ("OEBPS/text/ch 1.xhtml", Data(ch1.utf8), true),
                                  ("OEBPS/text/ch2.xhtml", Data(ch2.utf8), true),
                                  ("OEBPS/style.css", Data("p{}".utf8), false)])
    }
}

/// A minimal ZIP writer (stored or deflated entries) to build EPUBs in tests.
enum ZipWriter {
    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    static func archive(_ files: [(String, Data, Bool)]) -> Data {
        var out = Data(), central = Data()
        func le16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8 & 0xFF)) }
        func le32(_ v: UInt32, _ d: inout Data) { for k in 0..<4 { d.append(UInt8(v >> (8 * UInt32(k)) & 0xFF)) } }
        for (name, data, deflate) in files {
            let payload = deflate ? ((try? (data as NSData).compressed(using: .zlib)) as Data? ?? data) : data
            let method = deflate ? 8 : 0
            let crc = crc32(data)
            let offset = out.count
            let n = Data(name.utf8)
            le32(0x0403_4B50, &out); le16(20, &out); le16(0x0800, &out); le16(method, &out); le16(0, &out); le16(0, &out)
            le32(crc, &out); le32(UInt32(payload.count), &out); le32(UInt32(data.count), &out)
            le16(n.count, &out); le16(0, &out); out.append(n); out.append(payload)
            le32(0x0201_4B50, &central); le16(20, &central); le16(20, &central); le16(0x0800, &central); le16(method, &central)
            le16(0, &central); le16(0, &central); le32(crc, &central); le32(UInt32(payload.count), &central); le32(UInt32(data.count), &central)
            le16(n.count, &central); le16(0, &central); le16(0, &central); le16(0, &central); le16(0, &central); le32(0, &central)
            le32(UInt32(offset), &central); central.append(n)
        }
        let cdOffset = out.count
        out.append(central)
        le32(0x0605_4B50, &out); le16(0, &out); le16(0, &out); le16(files.count, &out); le16(files.count, &out)
        le32(UInt32(central.count), &out); le32(UInt32(cdOffset), &out); le16(0, &out)
        return out
    }
}
