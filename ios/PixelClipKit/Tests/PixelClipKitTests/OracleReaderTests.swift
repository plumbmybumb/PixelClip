import Foundation
import XCTest
@testable import PixelClipKit

/// The Oracle written from its phrase bundle (PROTOCOL §5f.1 paragraph, §5f.2 text screens, §5f.7 the lean draw): the
/// status, the machine's lean screens and details, the clip's text screens and their fit, the virtual clip, and the
/// sync keeping or dropping the four pieces (deck, keys, bundle, fonts).
final class OracleReaderTests: XCTestCase {
    static var bundle: SentenceReader { TarotTests.bundle }
    static var atlasFonts: (body: ReaderFont, big: ReaderFont) { TarotTests.atlasFonts }
    static var body: ReaderBoundFont.Face { ReaderBoundFont(atlasFonts.body).normal }
    static var big: ReaderBoundFont.Face { ReaderBoundFont(atlasFonts.big).normal }
    static let bundles: [TarotLanguage: SentenceReader] = Dictionary(uniqueKeysWithValues: TarotLanguage.allCases.map { l in
        (l, SentenceReader(bundle: try! Data(contentsOf: TarotTests.resources.appendingPathComponent("reader-\(l.rawValue).txt"))))
    })

    // MARK: The status

    func testStatusReading() throws {
        let st = try JSONDecoder().decode(ClipStatus.OracleStatus.self, from: Data("""
            {"cards":22,"state":"lean","cards_drawn":[17,1,13],"card":-1,"page":2,"reading":"Montée (XVII, I, XIII)…"}
            """.utf8))
        XCTAssertEqual(st.state, .lean)
        XCTAssertEqual(st.page, 2)
        XCTAssertEqual(st.reading, "Montée (XVII, I, XIII)…")
        XCTAssertEqual(st.three, [17, 1, 13])
        XCTAssertNil(try JSONDecoder().decode(ClipStatus.OracleStatus.self, from: Data(#"{"state":"hold","reading":""}"#.utf8)).reading)
        let none = try jsonObject(ClipJSON.encoder().encode(ClipStatus.OracleStatus(cards: 22, state: .hold)))
        XCTAssertEqual((none as! NSDictionary)["reading"] as? String, "")
        let out = try jsonObject(ClipJSON.encoder().encode(st)) as! NSDictionary
        XCTAssertEqual(out["state"] as? String, "lean")
        XCTAssertEqual(try JSONDecoder().decode(ClipStatus.OracleStatus.self, from: ClipJSON.encoder().encode(st)), st)
        XCTAssertEqual(OracleState.allCases.map(\.rawValue), ["waits", "armed", "shuffle", "three", "hold", "lean", "detail"])
    }

    // MARK: The machine (§5f.3 paged by hand, §5f.7 the lean draw)

    /// Walks a draw with taps only: three, the five lean screens, the three details, hold, waits; nothing moves by
    /// itself with the default (0) timings.
    func testTapsWalkTheScreensAndNothingMovesByItself() throws {
        let r = Self.bundle
        let t0 = TarotTests.t0
        let o = TarotTests.item
        XCTAssertEqual([o.faceMs, o.pageMs, o.holdMs], [0, 0, 300_000], "§5f.3 defaults")
        var m = OracleMachine(item: o, seed: 5, reader: r)
        m.turn(at: t0)
        XCTAssertEqual(m.state, .armed)
        m.turn(at: t0)
        XCTAssertEqual(m.state, .shuffle)
        var t = t0 + 1.2
        m.advance(to: t)
        XCTAssertEqual(m.state, .three)
        m.advance(to: t + 250)
        XCTAssertEqual(m.state, .three, "no timer")
        t += 250
        let abc = m.three
        let lean = try XCTUnwrap(r.composeLean(a: abc[0], b: abc[1], c: abc[2]))
        let paragraph = try XCTUnwrap(r.compose(a: abc[0], b: abc[1], c: abc[2])).text
        XCTAssertEqual(m.status(at: t).reading, paragraph, "the whole paragraph on the three")
        XCTAssertEqual(m.leanTexts, lean, "no page test given: ≤ 150 code points, as the fixtures")
        var screens: [String] = []
        m.turn(at: t)
        for _ in 0..<12 where m.state == .lean || m.state == .detail {
            let st = m.status(at: t)
            if m.state == .lean {
                XCTAssertEqual(st.reading, lean[m.page], "the lean screen's text")
                XCTAssertEqual(st.card, -1)
                XCTAssertEqual(m.view(at: t), .lean(lean[m.page]))
            } else {
                let brief = try XCTUnwrap(r.field(abc[m.page], .brief))
                XCTAssertEqual(st.reading, brief, "the card's brief")
                XCTAssertEqual(st.card, abc[m.page], "card = the detail card")
                XCTAssertEqual(m.view(at: t), .detail(card: abc[m.page], text: brief))
            }
            screens.append("\(m.state.rawValue)\(m.page)")
            m.turn(at: t)
        }
        XCTAssertEqual(screens, ["lean0", "lean1", "lean2", "lean3", "lean4", "detail0", "detail1", "detail2"])
        XCTAssertEqual(m.state, .hold)
        XCTAssertEqual(m.page, -1)
        XCTAssertEqual(m.status(at: t).reading, paragraph)
        XCTAssertEqual(m.view(at: t), .hold(abc), "the three again, with the end hint")
        m.advance(to: t + 299)
        XCTAssertEqual(m.state, .hold, "holds until the idle timeout")
        m.turn(at: t + 299)
        XCTAssertEqual(m.state, .waits, "a tap in hold goes back to waits")
    }

    /// The "and" screen asks the caller's page test; empty lean screens and cards without a brief are skipped.
    func testPageTestAndSkippedScreens() throws {
        let t0 = TarotTests.t0
        var m = OracleMachine(item: TarotTests.item, seed: 5, reader: Self.bundle, fits: { _ in false })
        m.draw(at: t0, cards: [17, 3, 9])
        m.advance(to: t0 + 1.2)
        XCTAssertEqual(m.leanTexts[4], try XCTUnwrap(Self.bundle.field(3, .closing)), "nothing fits: B's closing alone")
        XCTAssertEqual(Array(m.leanTexts[0...3]), Array(try XCTUnwrap(Self.bundle.composeLean(a: 17, b: 3, c: 9))[0...3]))
        // A bundle without briefs: no detail screens; without short phrases: no by-card / by-position screens.
        let stripped = String(decoding: TarotTests.bundleData, as: UTF8.self)
            .replacingOccurrences(of: ".brief]", with: ".nobrief]")
            .replacingOccurrences(of: "[short.card]", with: "[short.nocard]")
            .replacingOccurrences(of: "[short.positions]", with: "[short.nopositions]")
        var bare = OracleMachine(item: TarotTests.item, seed: 5, reader: SentenceReader(text: stripped))
        bare.draw(at: t0, cards: [17, 3, 9])
        bare.advance(to: t0 + 1.2)
        var screens: [String] = []
        for _ in 0..<12 where bare.state != .hold { bare.turn(at: t0 + 2); screens.append("\(bare.state.rawValue)\(bare.page)") }
        XCTAssertEqual(screens, ["lean2", "lean3", "lean4", "hold-1"])
        bare.back(at: t0 + 3)
        XCTAssertEqual(bare.page, 4, "back from the hold: the last lean screen")
    }

    /// Back walks the same list in reverse (nothing on waits; the three go back to waits).
    func testBackWalksTheListInReverse() throws {
        let t0 = TarotTests.t0
        var m = OracleMachine(item: TarotTests.item, seed: 5, reader: Self.bundle)
        m.back(at: t0)
        XCTAssertEqual(m.state, .waits, "the floor")
        m.draw(at: t0)
        m.back(at: t0 + 0.5)
        XCTAssertEqual(m.state, .shuffle, "nothing during the shuffle")
        let t = t0 + 1.2
        m.advance(to: t)
        var forward: [String] = []
        func label() -> String { "\(m.state.rawValue)\(m.page >= 0 ? ".\(m.page)" : "")" }
        forward.append(label())
        for _ in 0..<40 where m.state != .hold { m.turn(at: t); forward.append(label()) }
        XCTAssertEqual(forward, ["three", "lean.0", "lean.1", "lean.2", "lean.3", "lean.4", "detail.0", "detail.1", "detail.2", "hold"],
                       "≤ 11 one-page screens with waits")
        var backward: [String] = [label()]
        for _ in 0..<40 where m.state != .three { m.back(at: t); backward.append(label()) }
        XCTAssertEqual(Array(backward.reversed()), forward, "back retraces every screen")
        m.back(at: t)
        XCTAssertEqual(m.state, .waits)
        m.back(at: t)
        XCTAssertEqual(m.state, .waits)
    }

    /// `hold_ms` is the idle timeout from the last tap / back / shake, on any screen; non-zero timers still
    /// auto-advance (lean and detail screens by `page_ms`, the three by `face_ms`).
    func testIdleTimeoutAndOptionalTimers() throws {
        let t0 = TarotTests.t0
        var o = TarotTests.item
        o.holdMs = 60_000
        var m = OracleMachine(item: o, seed: 5, reader: Self.bundle)
        m.draw(at: t0)
        m.advance(to: t0 + 30)
        XCTAssertEqual(m.state, .three)
        m.turn(at: t0 + 50)                        // a tap restarts the idle clock
        m.advance(to: t0 + 109)
        XCTAssertEqual(m.state, .lean)
        m.back(at: t0 + 100)
        m.advance(to: t0 + 159)
        XCTAssertEqual(m.state, .three, "back counts as a tap")
        m.advance(to: t0 + 160)
        XCTAssertEqual(m.state, .waits, "idle for hold_ms: back to waits")
        o.holdMs = 0
        var never = OracleMachine(item: o, seed: 5)
        never.draw(at: t0)
        never.advance(to: t0 + 86_400)
        XCTAssertEqual(never.state, .three)
        // Timers set: shuffle 1.2 + three 1, then 5 lean + 3 details × 2 = 16 → the hold at 18.2.
        o.faceMs = 1000; o.pageMs = 2000; o.holdMs = 600_000
        var timed = OracleMachine(item: o, seed: 5, reader: Self.bundle)
        timed.draw(at: t0)
        timed.advance(to: t0 + 2.25)
        XCTAssertEqual(timed.state, .lean)
        XCTAssertEqual(timed.page, 0)
        timed.advance(to: t0 + 10.25)
        XCTAssertEqual(timed.state, .lean)
        XCTAssertEqual(timed.page, 4)
        timed.advance(to: t0 + 12.25)
        XCTAssertEqual(timed.state, .detail)
        XCTAssertEqual(timed.page, 0)
        timed.advance(to: t0 + 18.15)
        XCTAssertEqual(timed.state, .detail)
        timed.advance(to: t0 + 18.25)
        XCTAssertEqual(timed.state, .hold)
        timed.advance(to: t0 + 600)
        XCTAssertEqual(timed.state, .waits, "idle 10 minutes after the draw")
    }

    // MARK: The clip's text screens (§5f.2)

    func testFontsCarryTheirSizeAndCoverTheBundles() throws {
        let body = Self.atlasFonts.body, big = Self.atlasFonts.big
        XCTAssertTrue(body.id.hasPrefix("tarot-font22-"), body.id)
        XCTAssertTrue(big.id.hasPrefix("tarot-big56-"), big.id)
        XCTAssertEqual(TarotFonts.fontKey(inID: body.atlases[0].id), body.id, "§5f.9: with accent atlases, no \"-w\" suffix")
        XCTAssertEqual(body.atlases.count, 6, "n, na, c, ca and §5f.11's l, la")
        XCTAssertEqual(body.atlases.suffix(2).map(\.id), ["\(body.id)-l", "\(body.id)-la"])
        XCTAssertEqual(TarotFonts.fontKey(inID: big.id), big.id)
        XCTAssertNil(TarotFonts.fontKey(inID: "tarot-font-1a2b3c4d-n"), "pre-§5f.3 ids carry no size")
        XCTAssertNil(TarotFonts.fontKey(inID: "reader-font-1a2b3c4d-n"))
        XCTAssertTrue(body.atlases.allSatisfy { HCA.isValidAssetID($0.id) } && big.atlases.allSatisfy { HCA.isValidAssetID($0.id) })
        XCTAssertEqual(try TarotFonts.body().atlases.map(\.sha256), body.atlases.map(\.sha256), "deterministic: same ids every render")
        var report: [String] = []
        for size in TarotTextSize.allCases {
            let b = size == .medium ? body : try TarotFonts.body(size), g = size == .medium ? big : try TarotFonts.big(size)
            XCTAssertTrue(b.id.hasPrefix("tarot-font\(Int(size.bodySize))-") && g.id.hasPrefix("tarot-big\(Int(size.bigSize))-"))
            let face = ReaderBoundFont(b).normal
            var missing = Set<Character>()
            for (_, bundle) in Self.bundles {
                var texts = [bundle.text("prompt"), bundle.text("question.lead")]
                for c in 0..<22 {
                    texts += [bundle.field(c, .reading), bundle.field(c, .printed), bundle.field(c, .kw), bundle.field(c, .question), bundle.field(c, .closing)]
                }
                for t in texts.compactMap({ $0 }) {
                    for ch in t where face.glyph(ch.unicodeScalars.first!.value).missing { missing.insert(ch) }
                }
            }
            XCTAssertEqual(missing, [], "\(size) glyphs missing")
            // §5f.11: the large face at 1.3× (23 / 29 / 34 pt); its two atlases are the extra bytes.
            let large = try XCTUnwrap(b.large, "\(size) large face")
            XCTAssertEqual(large.pointSize, Double(size.largeSize))
            XCTAssertEqual(Int(size.largeSize), [23, 29, 34][TarotTextSize.allCases.firstIndex(of: size)!])
            let largeBytes = b.atlases.suffix(2).reduce(0) { $0 + $1.data.count }
            report.append("\(size.rawValue) \(b.id) cell \(face.document.cellH) \(b.atlasBytes) B (large \(Int(size.largeSize)) pt, cell \(large.document.cellH): +\(largeBytes) B) + \(g.id) \(g.atlasBytes) B")
        }
        print("TAROT_FONTS " + report.joined(separator: "; "))
    }

    /// Every reading of both languages fits the column at all three sizes: ≤ 6 pages of ≤ 4 lines, never cut;
    /// every word in order. Paragraphs (the longest of 2 000 rows per language and size): ≤ 8 full-width pages,
    /// never cut.
    func testReadingsAndParagraphsFitAtEverySize() throws {
        var report: [String] = []
        for size in TarotTextSize.allCases {
            let face = ReaderBoundFont(size == .medium ? Self.atlasFonts.body : try TarotFonts.body(size)).normal
            var maxPages = 0, maxParagraph = 0
            for (l, b) in Self.bundles {
                for c in 0..<22 {
                    let text = try XCTUnwrap(b.field(c, .reading), "\(l) \(c) has a reading")
                    let n = OracleScreens.pageCount(text, face: face)
                    XCTAssertFalse(OracleScreens.overflows(text, face: face), "\(size) \(l) reading \(c) needs more than 6 pages")
                    XCTAssertLessThanOrEqual(n, OracleScreens.maxPages)
                    maxPages = max(maxPages, n)
                    var words: [String] = []
                    for p in 0..<n {
                        let s = OracleScreens.reading(c, page: p, b, body: face)
                        XCTAssertLessThanOrEqual(s.lines.count, OracleScreens.maxLines)
                        for line in s.lines {
                            XCTAssertGreaterThanOrEqual(line.xs.first ?? OracleScreens.columnX, OracleScreens.columnX, "\(size) \(l) \(c).\(p)")
                            XCTAssertLessThanOrEqual(line.top + face.document.cellH, 240)
                            words.append(line.text)
                        }
                    }
                    XCTAssertEqual(words.joined().filter { !$0.isWhitespace }, text.filter { !$0.isWhitespace }, "\(size) \(l) \(c): every word")
                }
                // The longest paragraphs of a sample of rows.
                var rng = SeededRNG(7)
                var longest = ""
                for _ in 0..<2_000 {
                    var cs = Array(0..<22).shuffled(using: &rng)
                    let row = Array(cs.prefix(4)); cs.removeAll()
                    if let p = b.compose(a: row[1], b: row[2], c: row[3])?.text, p.utf8.count > longest.utf8.count {
                        longest = p
                    }
                }
                let n = OracleScreens.paragraphPageCount(longest, face: face)
                XCTAssertFalse(OracleScreens.paragraphOverflows(longest, face: face), "\(size) \(l) paragraph cut")
                XCTAssertLessThanOrEqual(n, OracleScreens.maxParagraphPages)
                maxParagraph = max(maxParagraph, n)
                for p in 0..<n {
                    for line in OracleScreens.paragraph(longest, page: p, body: face).lines {
                        XCTAssertGreaterThanOrEqual(line.xs.first ?? OracleScreens.paragraphX, OracleScreens.paragraphX)
                        XCTAssertLessThanOrEqual(line.xs.last ?? 0, OracleScreens.paragraphX + OracleScreens.paragraphWidth)
                    }
                }
                XCTAssertEqual(OracleScreens.paragraphPageTexts(longest, face: face).joined().filter { !$0.isWhitespace },
                               longest.filter { !$0.isWhitespace })
            }
            report.append("\(size.rawValue) (\(Int(size.bodySize)) pt): readings ≤ \(maxPages) pages, paragraph ≤ \(maxParagraph) pages")
        }
        print("TAROT_PAGES " + report.joined(separator: "; "))
    }

    func testPaintedScreens() throws {
        let a = try TarotTests.clipAssets()
        let reading = OracleCompositor.frame(.reading(card: 17, page: 0), a)
        // (An older view, no longer on the clip.) The card in the old slot, the text in the column, nothing past the dots.
        XCTAssertEqual(reading.pixels[(21 + 50) * 536 + 90], 0x4000 + 18)
        var inColumn = 0, outside = 0
        for y in 0..<240 {
            for x in 0..<536 where reading.pixels[y * 536 + x] != 0 {
                if x >= 168 && x < 520 { inColumn += 1 } else if x >= 530 { outside += 1 }
            }
        }
        XCTAssertGreaterThan(inColumn, 800)
        XCTAssertEqual(outside, 0)
        // Several pages: the dots, the current one accent.
        if OracleScreens.pageCount(Self.bundle.field(17, .reading)!, face: Self.body) > 1 {
            let s = OracleScreens.reading(17, page: 0, Self.bundle, body: Self.body)
            let d = try XCTUnwrap(s.dots)
            let total = d.count * OracleScreens.dotSize + (d.count - 1) * (OracleScreens.dotGap - OracleScreens.dotSize)
            XCTAssertEqual(reading.pixels[((240 - total) / 2 + 1) * 536 + OracleScreens.dotX + 1], BrandPalette.accentPixel)
        }
        // The face's numeral in the accent.
        let face = OracleCompositor.frame(.face(17), a)
        XCTAssertTrue(face.pixels.contains(BrandPalette.accentPixel) || face.pixels.contains { $0 != 0 && $0 != 0xFFFF })
        // §5f.11: a lean screen in the full box (x 8…528, rows 16…240), nothing outside it.
        let lean = try XCTUnwrap(Self.bundle.composeLean(a: 17, b: 3, c: 9))
        let f = OracleCompositor.frame(.lean(lean[3]), a)
        var leanInk = 0, leanOutside = 0
        for y in 16..<240 { for x in 0..<536 where f.pixels[y * 536 + x] != 0 { if x >= 8 && x < 528 { leanInk += 1 } else { leanOutside += 1 } } }
        XCTAssertGreaterThan(leanInk, 500)
        XCTAssertEqual(leanOutside, 0)
        if let dir = ProcessInfo.processInfo.environment["PIXELCLIP_TAROT_PNG"] {
            for (name, v) in [("waits", OracleView.waits), ("face", .face(17)), ("face13", .face(13)), ("question", .question(17)),
                              ("reading0", .reading(card: 17, page: 0)), ("reading1", .reading(card: 17, page: 1))] {
                try TarotTests.writePNG(OracleCompositor.frame(v, a), URL(fileURLWithPath: dir).appendingPathComponent("atlas-fr-\(name).png"))
            }
        }
    }

    /// What one language costs on the clip (§5f.12: deck 108×206, keys 160×34, bundle, fonts with the large face), per size.
    func testClipBytesPerLanguage() throws {
        var lines: [String] = []
        for size in TarotTextSize.allCases {
            let fonts = (size == .medium ? Self.atlasFonts.body : try TarotFonts.body(size)).atlasBytes
                + (size == .medium ? Self.atlasFonts.big : try TarotFonts.big(size)).atlasBytes
            for l in TarotLanguage.allCases {
                let r = try TarotTests.rendered(l)
                let bundle = try Data(contentsOf: TarotTests.resources.appendingPathComponent("reader-\(l.rawValue).txt")).count
                let total = r.deck.count + r.keys.count + bundle + fonts
                lines.append("\(size.rawValue) \(l.rawValue): \(total) B (fonts \(fonts))")
                XCTAssertLessThan(total, 2_000_000, "§5f.12: the 108×206 deck and the large face")
            }
        }
        print("TAROT_CLIP_BYTES " + lines.joined(separator: "; "))
    }

    // MARK: §5f.11 the faces, the corner ▶, the cards and the boxes

    /// §5f.11: every text screen in the largest face that fits its box on one page — the prompt and the armed line
    /// beside the back, the five lean screens of 500 rows per language full width, every brief beside its card —
    /// in both bundles at the three sizes (and both orientations for the screens beside a card); counts per face.
    func testEveryScreenInTheLargestFaceThatFits() throws {
        var report: [String] = []
        for size in TarotTextSize.allCases {
            let font = ReaderBoundFont(size == .medium ? Self.atlasFonts.body : try TarotFonts.body(size))
            XCTAssertNotNil(font.large)
            var counts: [String: Int] = [:]
            func check(_ text: String, box: OracleScreens.Band, laid: OracleScreens.Laid, what: String) {
                // The face fits, and the next larger one doesn't.
                XCTAssertTrue(OracleScreens.fits(text, face: laid.face, band: box), "\(size) \(what)")
                let faces = OracleScreens.faces(font)
                if let i = faces.map(\.0).firstIndex(of: laid.kind), i > 0 {
                    XCTAssertFalse(OracleScreens.fits(text, face: faces[i - 1].1, band: box), "\(size) \(what): a larger face fits")
                }
            }
            for flipped in [false, true] {
                for (l, b) in Self.bundles {
                    for armed in [false, true] {
                        let text = armed ? (b.text("prompt.armed") ?? "") : (b.text("prompt") ?? "")
                        let laid = armed ? OracleScreens.armed(b, font: font, flipped: flipped) : OracleScreens.waits(b, font: font, flipped: flipped)
                        check(text, box: OracleScreens.besideBox(flipped: flipped), laid: laid, what: "\(l) prompt")
                        if !flipped { counts["prompt.\(laid.kind.rawValue)", default: 0] += 1 }
                    }
                    for c in 0..<22 {
                        let brief = try XCTUnwrap(b.field(c, .brief))
                        let d = OracleScreens.detail(brief, font: font, flipped: flipped)
                        check(brief, box: d.card ? OracleScreens.besideBox(flipped: flipped) : OracleScreens.fullBox, laid: d.laid, what: "\(l) brief \(c)")
                        if !flipped { counts["brief.\(d.card ? d.laid.kind.rawValue : "noCard")", default: 0] += 1 }
                    }
                    guard !flipped else { continue }   // the full box is the same both ways
                    var rng = SeededRNG(3)
                    for _ in 0..<500 {
                        let row = Array(Array(0..<22).shuffled(using: &rng).prefix(3))
                        let fits: (String) -> Bool = { OracleScreens.fitsLeanPage($0, face: font.normal) }
                        for text in try XCTUnwrap(b.composeLean(a: row[0], b: row[1], c: row[2], fits: fits)) {
                            let laid = OracleScreens.lean(text, font: font)
                            check(text, box: OracleScreens.fullBox, laid: laid, what: "\(l) \(row)")
                            counts["lean.\(laid.kind.rawValue)", default: 0] += 1
                        }
                    }
                }
            }
            XCTAssertEqual(counts["brief.noCard", default: 0], 0, "\(size): every brief fits beside its card")
            report.append("\(size.rawValue): " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        print("TAROT_FACES " + report.joined(separator: "; "))
    }

    /// §5f.11: the large face in the §5c document (`"large":{…}`), round trip and on the virtual clip.
    func testFontDocumentRoundTripWithLarge() async throws {
        let body = Self.atlasFonts.body
        let doc = body.document
        let large = try XCTUnwrap(doc.large)
        XCTAssertEqual([large.atlasWhite, large.atlasAccent], ["\(body.id)-l", "\(body.id)-la"])
        let json = try JSONEncoder().encode(doc)
        XCTAssertLessThanOrEqual(json.count, ReaderFontDocument.maxJSONBytes)
        XCTAssertNotNil((try jsonObject(json) as! NSDictionary)["large"])
        XCTAssertEqual(try JSONDecoder().decode(ReaderFontDocument.self, from: json), doc)
        XCTAssertNil(doc.validationProblem)
        XCTAssertEqual(Array(doc.atlasIDs.suffix(2)), ["\(body.id)-l", "\(body.id)-la"])
        // A Reader font has no large face; a document without one still decodes.
        let plain = ReaderFontDocument(normal: doc.normal, compact: doc.compact)
        XCTAssertNil(try JSONDecoder().decode(ReaderFontDocument.self, from: JSONEncoder().encode(plain)).large)
        // The virtual clip takes and keeps all three faces.
        let clip = VirtualClipClient(options: .instant)
        for a in body.atlases { _ = try await clip.putAsset(id: a.id, data: a.data, progress: nil) }
        try await clip.putFont(id: body.id, doc)
        let back = try await clip.font(id: body.id)
        XCTAssertEqual(back, doc)
    }

    /// §5f.11/§5f.12 geometry, both orientations: the one ▶ in the BOOT corner (its pixels exactly, the 24×16 reserve
    /// otherwise empty, none on the shuffle), the cards (three at y 0, x 52, 214, 376 with their keys pasted whole at
    /// y 206, x 26, 188, 350; the back and the detail's card at y 17, x 8 / 420), the text boxes (rows 16…240 / 0…224;
    /// x 8…528, beside a card 124…528 / 8…412), all on screen and none overlapping.
    func testCornerTriangleCardsAndBoxes() throws {
        var a = try TarotTests.clipAssets()
        let ac = BrandPalette.accentPixel
        let lean = try XCTUnwrap(Self.bundle.composeLean(a: 17, b: 3, c: 9))[0]
        let brief = try XCTUnwrap(Self.bundle.field(17, .brief))
        let font = ReaderBoundFont(Self.atlasFonts.body)
        let W = Oracle.cardWidth, H = Oracle.cardHeight, KW = Oracle.keyWidth, KH = Oracle.keyHeight
        for flipped in [false, true] {
            a.flipped = flipped
            let o = OracleScreens.hintOrigin(flipped: flipped)
            XCTAssertEqual([o.x, o.y], flipped ? [8, 227] : [520, 4])
            let r = OracleScreens.cornerReserve(flipped: flipped)
            XCTAssertEqual([r.x, r.y, r.w, r.h], flipped ? [0, 224, 24, 16] : [512, 0, 24, 16])
            let views: [(String, OracleView)] = [("waits", .waits), ("armed", .armed), ("three", .three([17, 3, 9])), ("hold", .hold([17, 3, 9])),
                                                 ("lean", .lean(lean)), ("detail", .detail(card: 17, text: brief)),
                                                 ("shuffle", .shuffleThree([17, 3, 9]))]
            for (name, v) in views {
                let f = OracleCompositor.frame(v, a)
                func px(_ x: Int, _ y: Int) -> UInt16 { f.pixels[y * 536 + x] }
                // The reserve holds the ▶ only (nothing on the shuffle): rows 1, 3, 5, 7, 8, 7, 5, 3, 1 px wide = 40 px.
                var tri = 0
                for y in r.y..<(r.y + r.h) {
                    for x in r.x..<(r.x + r.w) where px(x, y) != 0 {
                        XCTAssertEqual(px(x, y), ac, "\(name) \(flipped): only the ▶ in the corner")
                        XCTAssertTrue((o.x..<(o.x + 8)).contains(x) && (o.y..<(o.y + 9)).contains(y), "\(name) \(flipped): (\(x), \(y))")
                        tri += 1
                    }
                }
                XCTAssertEqual(tri, name == "shuffle" ? 0 : 40, "\(name) \(flipped)")
                if name != "shuffle" {
                    // ▶ 8 × 9: the back edge full height away from the button's edge, the point mid-height.
                    let back = flipped ? o.x + 7 : o.x, point = flipped ? o.x : o.x + 7
                    XCTAssertEqual((o.y..<(o.y + 9)).map { px(back, $0) }, Array(repeating: ac, count: 9), "\(name) \(flipped)")
                    XCTAssertEqual(px(point, o.y + 4), ac)
                    XCTAssertNotEqual(px(point, o.y), ac)
                    XCTAssertNotEqual(px(point, o.y + 3), ac)
                }
                switch v {
                case .three, .hold, .shuffleThree:
                    for (k, card) in [17, 3, 9].enumerated() {
                        let x = Oracle.threeCardX[k], col = 0x4000 + UInt16(1 + card)
                        XCTAssertEqual(px(x, 0), col, "\(name) card \(k) from y 0, x \(x)")
                        XCTAssertEqual(px(x + W - 1, H - 1), col, "\(name) card \(k) 108×206")
                        XCTAssertEqual(px(x - 1, 100), 0)
                        XCTAssertEqual(px(x + W, 100), 0)
                        // The keyword row under the three (not on the shuffle), each tile pasted whole: 160×34 at a 162 px
                        // pitch, 2 px apart, to the bottom row.
                        let kx = Oracle.threeKeyX[k], key: UInt16 = name == "shuffle" ? 0 : 0x6000 + UInt16(card)
                        XCTAssertEqual(px(x + W / 2, H), key, "\(name) key \(k) right under its card")
                        XCTAssertEqual(px(kx, 206), key, "\(name) key \(k) from (\(kx), 206)")
                        XCTAssertEqual(px(kx + KW - 1, 239), key, "\(name) key \(k) to (\(kx + KW - 1), 239)")
                        XCTAssertEqual(px(kx - 1, 220), 0, "\(name) key \(k): nothing left of it")
                        XCTAssertEqual(px(kx + KW, 220), 0, "\(name) key \(k): nothing right of it")
                    }
                    XCTAssertEqual(px(30, 120), 0)
                case .waits, .armed, .detail:
                    let x = Oracle.singleCardX(flipped: flipped)
                    let col: UInt16 = name == "detail" ? 0x4000 + 18 : 0x4000
                    XCTAssertEqual(px(x, 17), col, "\(name) card at (\(x), 17)")
                    XCTAssertEqual(px(x + W - 1, 17 + H - 1), col, "\(name) 108×206")
                    XCTAssertEqual(px(x + W / 2, 16), 0)
                    XCTAssertEqual(px(x + W / 2, 17 + H), 0, "to y 222")
                    XCTAssertEqual(px(x - 1, 120), 0)
                    XCTAssertEqual(px(x + W, 120), 0)
                default: break
                }
            }
            // The pieces are on screen and clear of the corner reserve.
            func clearOfReserve(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ what: String) {
                XCTAssertTrue(x0 >= 0 && y0 >= 0 && x0 + w <= 536 && y0 + h <= 240, "\(what) on screen")
                XCTAssertTrue(x0 + w <= r.x || r.x + r.w <= x0 || y0 + h <= r.y || r.y + r.h <= y0, "\(what) \(flipped) clear of the reserve")
            }
            for k in 0..<3 {
                clearOfReserve(Oracle.threeCardX[k], Oracle.threeCardY, W, H, "card \(k)")
                clearOfReserve(Oracle.threeKeyX[k], Oracle.threeKeyY, KW, KH, "key \(k)")
            }
            clearOfReserve(Oracle.singleCardX(flipped: flipped), Oracle.singleCardY, W, H, "the single card")
            // The boxes: every line inside, rows 16…240 normally / 0…224 flipped, clear of the reserve.
            let top = OracleScreens.textTop(flipped: flipped)
            XCTAssertEqual(top, flipped ? 0 : 16)
            XCTAssertEqual(OracleScreens.textBoxHeight, 224)
            func inside(_ l: OracleScreens.Laid, _ box: OracleScreens.Band) {
                clearOfReserve(box.x, top, box.width, OracleScreens.textBoxHeight, "box \(box)")
                for line in l.screen.lines {
                    XCTAssertGreaterThanOrEqual(line.top, top)
                    XCTAssertLessThanOrEqual(line.top + l.face.document.cellH, top + 224)
                    XCTAssertGreaterThanOrEqual(line.xs.first ?? box.x, box.x)
                    XCTAssertLessThanOrEqual(line.xs.last ?? 0, box.x + box.width)
                }
            }
            inside(OracleScreens.lean(lean, font: font, flipped: flipped), OracleScreens.fullBox)
            inside(OracleScreens.waits(Self.bundle, font: font, flipped: flipped), OracleScreens.besideBox(flipped: flipped))
            let d = OracleScreens.detail(brief, font: font, flipped: flipped)
            XCTAssertTrue(d.card)
            inside(d.laid, OracleScreens.besideBox(flipped: flipped))
            let beside = OracleScreens.besideBox(flipped: flipped)
            XCTAssertEqual([beside.x, beside.x + beside.width], flipped ? [8, 412] : [124, 528])
            XCTAssertEqual(Oracle.singleCardX(flipped: flipped), flipped ? 420 : 8)
            // The card beside the box doesn't overlap it (8 px apart).
            let cx = Oracle.singleCardX(flipped: flipped)
            XCTAssertEqual(flipped ? cx - (beside.x + beside.width) : beside.x - (cx + W), 8)
        }
        XCTAssertEqual([OracleScreens.fullBox.x, OracleScreens.fullBox.x + OracleScreens.fullBox.width], [8, 528])
        XCTAssertEqual(Oracle.threeCardX, [52, 214, 376])
        XCTAssertEqual([Oracle.threeCardY, Oracle.threeKeyY, Oracle.singleCardY], [0, 206, 17])
        XCTAssertEqual(Oracle.threeKeyX, [26, 188, 350])
        XCTAssertEqual([Oracle.cardWidth, Oracle.cardHeight, Oracle.keyWidth, Oracle.keyHeight], [108, 206, 160, 34])
        // The key centres sit under the card centres (106, 268, 430), the keys right under the cards.
        for k in 0..<3 { XCTAssertEqual(Oracle.threeKeyX[k] + KW / 2, Oracle.threeCardX[k] + W / 2) }
        XCTAssertEqual(Oracle.threeKeyX.map { $0 + KW / 2 }, [106, 268, 430])
        XCTAssertEqual(Oracle.threeCardY + H, Oracle.threeKeyY)
        XCTAssertEqual(Oracle.threeKeyY + KH, 240)
    }

    // MARK: The virtual clip

    func testVirtualClipPagesAndGoesBack() async throws {
        let (clip, clock) = try await TarotTests.seededClip()
        let o = TarotTests.item
        try await clip.putPlaylist(Playlist(items: [o.playlistItem(durationMs: 0, transition: nil)]))
        try await clip.oracleDraw(cards: [17, 3, 9])
        clock.now += 1.2
        try await clip.oracleTurn()                              // three → the first lean screen
        var st = try await clip.status()
        XCTAssertEqual(st.oracle?.state, .lean)
        XCTAssertEqual(st.oracle?.page, 0)
        let lean = try XCTUnwrap(Self.bundle.composeLean(a: 17, b: 3, c: 9, fits: { OracleScreens.fitsLeanPage($0, face: Self.body) }))
        XCTAssertEqual(st.oracle?.reading, lean[0])
        clock.now += 200                                         // nothing moves by itself…
        let d = await clip.display()
        XCTAssertEqual(d.oracle?.state, .lean)
        XCTAssertEqual(d.oracle?.reading, lean[0], "the display carries the status for Home")
        XCTAssertEqual(d.frame, OracleCompositor.frame(.lean(lean[0]), try TarotTests.clipAssets()), "a static page")
        clock.now += 100                                         // …until 5 minutes without a tap
        st = try await clip.status()
        XCTAssertEqual(st.oracle?.state, .waits, "the idle timeout")
        // Through to the details and back.
        try await clip.oracleDraw(cards: [17, 3, 9])
        clock.now += 1.2
        for _ in 0..<20 {
            st = try await clip.status()
            if st.oracle?.state == .detail { break }
            try await clip.oracleTurn()
        }
        XCTAssertEqual(st.oracle?.card, 17)
        XCTAssertEqual(st.oracle?.page, 0)
        XCTAssertEqual(st.oracle?.reading, Self.bundle.field(17, .brief))
        try await clip.oracleBack()
        st = try await clip.status()
        XCTAssertEqual(st.oracle?.state, .lean)
        XCTAssertEqual(st.oracle?.page, 4, "back from the first detail: the \"and\" screen")
        XCTAssertEqual(st.oracle?.reading, lean[4])
        try await clip.putPlaylist(.empty)
        await expectHTTP(409, "not_showing") { try await clip.oracleBack() }
    }

    // MARK: The sync

    func testPrepareKeepsOrDropsTheFourPieces() async throws {
        let clip = VirtualClipClient(options: .instant)
        let a = try TarotTests.fakeAssets()
        let o = TarotTests.item
        for (id, data) in [(o.deck, a.deck), (o.keys!, a.keys)] { _ = try await clip.putAsset(id: id, data: data, progress: nil) }
        let playlist = Playlist(items: [o.playlistItem()])
        let text = ReaderPusher.Text(id: o.id, data: TarotTests.bundleData, title: "Tarot")
        let fonts = [Self.atlasFonts.body, Self.atlasFonts.big]
        let pusher = ReaderPusher(client: clip)

        // Everything there: atlases, then both fonts, then the bundle; the item unchanged; the clip takes it.
        let r = try await pusher.prepareOracleReaders(playlist, texts: [text], fonts: fonts, keep: Playlist.empty)
        XCTAssertEqual(r.playlist, playlist)
        XCTAssertEqual(r.result.textsPut, [o.id])
        XCTAssertEqual(r.result.fontsPut, [Self.atlasFonts.body.id, Self.atlasFonts.big.id])
        XCTAssertEqual(Set(r.result.uploadedAtlases), Set(fonts.flatMap { $0.atlases.map(\.id) }))
        try await clip.putPlaylist(r.playlist)

        // Again: nothing new.
        let again = try await pusher.prepareOracleReaders(playlist, texts: [text], fonts: fonts, keep: playlist)
        XCTAssertEqual(again.result.textsPut, [])
        XCTAssertEqual(again.result.uploadedAtlases, [])
        XCTAssertEqual(again.deletedTexts, [])
        XCTAssertEqual(again.deletedAtlases, [])

        // No body font (or no bundle): the oracle can't be written, it's left out of this send.
        let noBody = try await pusher.prepareOracleReaders(playlist, texts: [text], fonts: [Self.atlasFonts.big], keep: nil)
        XCTAssertTrue(noBody.playlist.items.isEmpty)
        let noText = try await pusher.prepareOracleReaders(playlist, texts: [], fonts: fonts, keep: nil)
        XCTAssertTrue(noText.playlist.items.isEmpty)
        // No big font: the item stays without font_big.
        let noBig = try await pusher.prepareOracleReaders(playlist, texts: [text], fonts: [Self.atlasFonts.body], keep: nil)
        XCTAssertEqual(noBig.playlist.items.count, 1)
        XCTAssertNil(noBig.playlist.items[0].fontBig)
        XCTAssertEqual(noBig.playlist.items[0].font, Self.atlasFonts.body.id)
        // A bundle the clip refuses (too big for what's left): dropped the same way.
        let tight = VirtualClipClient(options: .init(latency: .zero, bytesPerSecond: 0, storageTotal: 1_000))
        let refused = try await ReaderPusher(client: tight).prepareOracleReaders(playlist, texts: [text], fonts: [], keep: nil)
        XCTAssertTrue(refused.playlist.items.isEmpty)

        // Clean-up: an older bundle and an older Tarot font no playlist names go; Reader texts stay;
        // with the clip's playlist unknown nothing is deleted.
        _ = try await clip.putText(id: "tarot-reader-fr-aaaaaaaaaa", data: Data("[question]\nold\n".utf8))
        _ = try await clip.putText(id: "text-0123456789", data: Data("A Reader text.".utf8))
        _ = try await clip.putAsset(id: "tarot-font18-0badc0de-n", data: Self.atlasFonts.body.atlases[0].data, progress: nil)
        let unknown = try await pusher.prepareOracleReaders(playlist, texts: [text], fonts: fonts, keep: nil)
        XCTAssertEqual(unknown.deletedTexts, [])
        XCTAssertEqual(unknown.deletedAtlases, [])
        let clean = try await pusher.prepareOracleReaders(playlist, texts: [text], fonts: fonts, keep: playlist)
        XCTAssertEqual(clean.deletedTexts, ["tarot-reader-fr-aaaaaaaaaa"])
        XCTAssertEqual(clean.deletedAtlases, ["tarot-font18-0badc0de-n"], "another size's atlas, unused")
        let left = try await clip.texts().map(\.id)
        XCTAssertEqual(Set(left), [o.id, "text-0123456789"])
        // The Tarot's atlases are never orphans for the sync.
        XCTAssertTrue(SyncOptions().protectedPrefixes.contains(TarotFonts.bodyPrefix))
        XCTAssertTrue(SyncOptions().protectedPrefixes.contains(TarotFonts.bigPrefix))
        // Deleting the bundle takes the oracle out on the clip.
        try await clip.deleteText(id: o.id)
        let pl = try await clip.playlist()
        XCTAssertTrue(pl.items.isEmpty)
    }

    func testSyncEngineSendsTheThreeAssetsAndDropsTheItemWithAMissingOne() throws {
        let o = TarotTests.item
        let local = o.assetIDs.map { LocalAsset(id: $0, data: Data($0.utf8)) }
        let pl = Playlist(items: [o.playlistItem()])
        let plan = SyncEngine.plan(local: local, playlist: pl, remote: [], options: SyncOptions())
        XCTAssertEqual(plan.playlist, pl)
        XCTAssertEqual(Set(plan.uploads.map(\.id)), Set(o.assetIDs), "the bundle and fonts aren't assets")
        let noDeck = SyncEngine.plan(local: local.filter { $0.id != o.deck }, playlist: pl, remote: [], options: SyncOptions())
        XCTAssertTrue(noDeck.playlist.items.isEmpty)
        // Missing pieces in the playlist helper.
        XCTAssertTrue(pl.withoutUnavailableOracles(missingTexts: [o.id], missingFonts: []).items.isEmpty)
        XCTAssertTrue(pl.withoutUnavailableOracles(missingTexts: [], missingFonts: [o.font!]).items.isEmpty)
        XCTAssertNil(pl.withoutUnavailableOracles(missingTexts: [], missingFonts: [o.fontBig!]).items.first?.fontBig)
        XCTAssertEqual(pl.withoutUnavailableOracles(missingTexts: [], missingFonts: []), pl)
    }
}
