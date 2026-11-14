import CoreText
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PixelClipKit

/// Oracle (tarot) (PROTOCOL §5f): the four assets' frames and sizes, text fitting, the item JSON,
/// `/status.oracle`, the state machine in both modes, the virtual clip and the fast lane.
final class TarotTests: XCTestCase {
    static let resources = Paths.iosDir.appendingPathComponent("Sources/Resources/Tarot")

    static func fonts() throws -> TarotRenderer.Fonts {
        XCTAssertTrue(BundledFontsTests.registered)
        return TarotRenderer.Fonts.bundled()
    }

    static func deck() throws -> TarotDeck { try TarotDeck(folder: resources.appendingPathComponent("dodal")) }
    static func readings() throws -> TarotReadings { try TarotReadings(data: Data(contentsOf: resources.appendingPathComponent("readings.json"))) }

    /// Rendered once per language for the whole class (it takes a few seconds).
    nonisolated(unsafe) static var cache: [TarotLanguage: TarotRenderer.Rendered] = [:]
    static func rendered(_ l: TarotLanguage) throws -> TarotRenderer.Rendered {
        if let hit = cache[l] { return hit }
        let deckFrames = cache.values.first?.assets.deck
        let r = try TarotRenderer.render(deck: deck(), readings: readings(), spec: TarotSpec(language: l), fonts: fonts(), deckFrames: deckFrames)
        cache[l] = r
        return r
    }

    static func writePNG(_ f: RGB565Frame, _ url: URL) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ClipRenderer.makeCGImage(f)), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// `PIXELCLIP_TAROT_PNG=<dir> swift test --filter TarotTests/testWriteScreens` writes composed screens.
    func testWriteScreens() throws {
        guard let dir = ProcessInfo.processInfo.environment["PIXELCLIP_TAROT_PNG"] else { throw XCTSkip("set PIXELCLIP_TAROT_PNG to write PNGs") }
        for l in TarotLanguage.allCases {
            let r = try Self.rendered(l)
            print("TAROT_SIZE \(l.rawValue) deck=\(r.deck.count) text=\(r.text.count) keys=\(r.keys.count) notes=\(r.notes.count) total=\(r.totalBytes)")
            let a = r.assets
            let shots: [(String, OracleView)] = [("waits", .waits), ("question", .question(17)), ("three", .three([17, 1, 13])),
                                                 ("reading0", .reading(card: 17, page: 0)), ("reading1", .reading(card: 17, page: 1)),
                                                 ("thread", .thread([17, 1, 13])), ("face", .face(17)), ("face0", .face(0)), ("face10", .face(10)),
                                                 ("reading10", .reading(card: 10, page: 0)), ("question12", .question(12))]
            for (name, v) in shots {
                try Self.writePNG(OracleCompositor.frame(v, a), URL(fileURLWithPath: dir).appendingPathComponent("tarot-\(l.rawValue)-\(name).png"))
            }
        }
    }

    // MARK: Renderer

    func testIndexHelpersAndFrameCounts() throws {
        XCTAssertEqual(Oracle.textFrames(cards: 22, pages: 2), 89)
        XCTAssertEqual(Oracle.deckFrames(cards: 22), 23)
        XCTAssertEqual(Oracle.base(0, pages: 2), 1)
        XCTAssertEqual(Oracle.face(3, pages: 2), 13)
        XCTAssertEqual(Oracle.question(3, pages: 2), 14)
        XCTAssertEqual(Oracle.reading(3, 1, pages: 2), 16)
        XCTAssertEqual(Oracle.reading(21, 1, pages: 2), 88, "the last frame")
        XCTAssertEqual(Oracle.cards(textFrames: 89, pages: 2), 22)
        XCTAssertNil(Oracle.cards(textFrames: 90, pages: 2))

        for l in TarotLanguage.allCases {
            let r = try Self.rendered(l)
            let d = try HCAFile(data: r.deck), t = try HCAFile(data: r.text), k = try HCAFile(data: r.keys), n = try HCAFile(data: r.notes)
            XCTAssertEqual([d.width, d.height, d.frameCount], [108, 206, 23], "§5f.12: the deck at 108×206")
            XCTAssertEqual([t.width, t.height, t.frameCount], [536, 240, 89])
            XCTAssertEqual([k.width, k.height, k.frameCount], [160, 34, 22], "§5f.12: keys 160×34")
            XCTAssertEqual([n.width, n.height, n.frameCount], [536, 72, 22])
            XCTAssertFalse(t.isGlyphAtlas, "T is a normal 536×240 asset")
            XCTAssertTrue(d.isGlyphAtlas && k.isGlyphAtlas && n.isGlyphAtlas, "D, K and N carry the glyph-atlas flag (firmware storage)")
            // Decoded = rendered, frame for frame, in the contract's order.
            XCTAssertEqual(try t.decodeFrame(Oracle.question(17, pages: 2)), r.assets.text[Oracle.question(17, pages: 2)])
            XCTAssertEqual(try d.decodeFrame(18), r.assets.deck[18])
            print("TAROT_SIZE \(l.rawValue) deck=\(r.deck.count) text=\(r.text.count) keys=\(r.keys.count) notes=\(r.notes.count) total=\(r.totalBytes)")
        }
        XCTAssertEqual(try Self.rendered(.fr).deck, try Self.rendered(.en).deck, "one deck for both languages")
    }

    /// Every text frame leaves the card slot black (the clip pastes the card there).
    func testTextFramesLeaveTheSlotBlack() throws {
        let s = Oracle.slot
        for l in TarotLanguage.allCases {
            for (i, f) in try Self.rendered(l).assets.text.enumerated() {
                for y in s.y..<(s.y + s.h) {
                    for x in s.x..<(s.x + s.w) where f.pixels[y * f.width + x] != 0 {
                        return XCTFail("\(l) T[\(i)] has ink at (\(x), \(y)) in the slot")
                    }
                }
            }
        }
    }

    /// §5f.12: every keyword tile (both languages) at one size — the largest at which the longest keyword's ink fits
    /// 140 px and the line 28 px — its ink in the 140×28 box at (10, 2).
    func testKeywordsAtOneSize() throws {
        var sizes: [String] = []
        let fonts = try Self.fonts()
        let box = Oracle.keyInkBox
        XCTAssertEqual([box.x, box.y, box.w, box.h], [10, 2, 140, 28])
        for l in TarotLanguage.allCases {
            let r = try Self.rendered(l)
            XCTAssertEqual(r.assets.keys.count, 22)
            let keywords = try Self.readings().texts(l).map(\.keyword)
            let size = TarotRenderer.keySize(keywords, fonts: fonts)
            // The longest keyword fits at that size; half a point more and the width or the line height doesn't.
            let widest = keywords.max { TarotRenderer.keyInkWidth($0, fonts: fonts, size: size) < TarotRenderer.keyInkWidth($1, fonts: fonts, size: size) }!
            XCTAssertLessThanOrEqual(TarotRenderer.keyInkWidth(widest, fonts: fonts, size: size), 140)
            XCTAssertLessThanOrEqual(TarotRenderer.keyLineHeight(fonts: fonts, size: size), 28)
            let up = size + 0.5
            XCTAssertTrue(TarotRenderer.keyInkWidth(widest, fonts: fonts, size: up) > 140 || TarotRenderer.keyLineHeight(fonts: fonts, size: up) > 28
                          || !TarotRenderer.keyInkFits(TarotRenderer.keyTile(widest, fonts: fonts, size: up)), "\(l): \(up) pt would fit too")
            for (i, tile) in r.assets.keys.enumerated() {
                XCTAssertEqual([tile.width, tile.height], [160, 34])
                XCTAssertEqual(tile, TarotRenderer.keyTile(keywords[i], fonts: fonts, size: size), "\(l) key \(i) at the one size")
                XCTAssertTrue(TarotRenderer.keyInkFits(tile), "\(l) key \(i): ink in the 140×28 box")
                XCTAssertTrue(tile.pixels.contains { $0 != 0 }, "\(l) key \(i) has ink")
            }
            sizes.append("\(l.rawValue) \(size) pt (widest “\(widest)” \(Int(TarotRenderer.keyInkWidth(widest, fonts: fonts, size: size).rounded())) px)")
        }
        print("TAROT_KEY_SIZE " + sizes.joined(separator: ", "))
    }

    /// No text overflows, for every card in both languages at the bundled font: the face info and the
    /// question inside the column, the reading in its area in ≤ 4 lines per page (never cut), keyword
    /// tiles ≤ 160 px wide, notes in two lines inside 536×72.
    func testTextNeverOverflows() throws {
        let fonts = try Self.fonts()
        let col = TarotRenderer.column, area = TarotRenderer.readingArea
        let screen = CGRect(x: 0, y: 0, width: 536, height: 240)
        var longest: (String, Int, CGFloat) = ("", 0, 0)
        for l in TarotLanguage.allCases {
            for t in try Self.readings().texts(l) {
                let face = TarotRenderer.faceLayout(t, fonts: fonts)
                for r in face.inks { XCTAssertTrue(col.insetBy(dx: -1, dy: -1).contains(r), "\(l) face \(t.index) \(r)") }
                XCTAssertFalse(face.name.lines.joined().hasSuffix("…"), "\(l) name \(t.index) cut")
                let q = TarotRenderer.questionLayout(t, language: l, fonts: fonts)
                for r in q.inks { XCTAssertTrue(col.insetBy(dx: -1, dy: -1).contains(r), "\(l) question \(t.index) \(r)") }
                XCTAssertFalse(q.question.lines.joined().hasSuffix("…"), "\(l) question \(t.index) cut")
                let reading = TarotRenderer.readingLayout(t, fonts: fonts)
                XCTAssertFalse(reading.truncated, "\(l) reading \(t.index) cut")
                XCTAssertLessThanOrEqual(reading.maxLines, 4)
                XCTAssertGreaterThanOrEqual(reading.bodySize, TarotRenderer.minBodySize)
                XCTAssertEqual(reading.pages.flatMap(\.lines).joined(separator: " "), TarotRenderer.tokens(t.reading).joined(separator: " "),
                               "every word, in order")
                for p in reading.pages {
                    for r in p.inks {
                        XCTAssertGreaterThanOrEqual(r.minX, area.minX - 1, "\(l) reading \(t.index)")
                        XCTAssertLessThanOrEqual(r.maxX, area.maxX + 1, "\(l) reading \(t.index) \(r)")
                        XCTAssertTrue(screen.insetBy(dx: 2, dy: 2).contains(r), "\(l) reading \(t.index) \(r)")
                    }
                }
                if CGFloat(t.reading.count) > longest.2 { longest = (l.rawValue, t.index, CGFloat(t.reading.count)) }
                XCTAssertFalse(t.keyword.contains("\n"), "\(l) keyword \(t.index) is one line")
                let note = TarotRenderer.noteTileLayout(t.threadNote, fonts: fonts)
                XCTAssertLessThanOrEqual(note.lines.count, 2)
                XCTAssertFalse(note.lines.joined().hasSuffix("…"), "\(l) note \(t.index) cut")
                XCTAssertLessThanOrEqual(note.layout.maxInkWidth, 536)
                XCTAssertLessThanOrEqual(note.height, 72)
            }
        }
        // The rendered reading frames: nothing right of the text area but the page marks, nothing at the edges.
        for l in TarotLanguage.allCases {
            let a = try Self.rendered(l).assets
            for i in 0..<22 {
                for p in 0..<2 {
                    let f = a.text[Oracle.reading(i, p, pages: 2)]
                    for y in 0..<240 {
                        for x in 0..<536 where f.pixels[y * 536 + x] != 0 {
                            let inBorder = x >= 39 && x <= 144 && y >= 20 && y <= 219
                            let inText = CGFloat(x) >= area.minX - 2 && CGFloat(x) <= area.maxX + 2 && y >= 2 && y < 238
                            let inMarks = x >= 518 && x <= 526 && y >= 108 && y <= 132
                            XCTAssertTrue(inBorder || inText || inMarks, "\(l) R(\(i),\(p)) ink at (\(x), \(y))")
                            if !(inBorder || inText || inMarks) { return }
                        }
                    }
                }
            }
        }
        print("TAROT_LONGEST reading \(longest)")
    }

    func testReadingsAndEdits() throws {
        let r = try Self.readings()
        XCTAssertEqual(r.cards.count, 22)
        XCTAssertEqual(r.cards.map(\.index), Array(0..<22))
        let star = try XCTUnwrap(r[17])
        XCTAssertEqual(star.numeral, "XVII")
        XCTAssertFalse(star.question(.fr).isEmpty)
        XCTAssertFalse(star.reading(.en).isEmpty)
        // XIII has no printed name: the clip shows its name in the language.
        XCTAssertEqual(TarotCardText(try XCTUnwrap(r[13]), language: .en).name, try XCTUnwrap(r[13]).displayName(.en))
        // Edits lay over the original, per language, and restore.
        var edits = TarotEdits()
        edits[17, .fr] = TarotCardEdit(keyword: "Offrir", question: "À qui donnes-tu ?")
        let fr = r.texts(.fr, edits: edits)[17], en = r.texts(.en, edits: edits)[17]
        XCTAssertEqual(fr.keyword, "Offrir")
        XCTAssertEqual(fr.question, "À qui donnes-tu ?")
        XCTAssertEqual(fr.reading, star.readingFR)
        XCTAssertEqual(en.keyword, star.keywordEN)
        XCTAssertTrue(edits.isEdited(17))
        XCTAssertEqual(TarotSpec(language: .en, edits: edits).edits, [:], "a spec keeps only its language's edits")
        let back = try JSONDecoder().decode(TarotEdits.self, from: JSONEncoder().encode(edits))
        XCTAssertEqual(back, edits)
        edits.restore(17)
        XCTAssertFalse(edits.isEdited(17))
        // The thread note leads with the numeral.
        XCTAssertEqual(TarotCardText(index: 2, numeral: "II", name: "", keyword: "", reading: "", note: "accumuler, préparer").threadNote,
                       "II · accumuler, préparer")
        XCTAssertEqual(TarotCardText(index: 2, numeral: "II", name: "", keyword: "", reading: "", note: "II · déjà là").threadNote, "II · déjà là")
        // An object-wrapped or bare array both decode; missing keys are empty strings.
        let bare = try TarotReadings(data: Data(#"[{"index":0,"numeral":"","name_printed":"LE FOL"}]"#.utf8))
        XCTAssertEqual(bare.cards.first?.namePrinted, "LE FOL")
        XCTAssertEqual(bare.cards.first?.questionFR, "")
        XCTAssertFalse(bare.cards[0].question(.fr).isEmpty, "a stand-in question until the file has one")
    }

    // MARK: Item and status JSON

    // §5f.2: the oracle is its phrase bundle (the French one the app ships) with the deck, keys and two fonts (§5f.7: no notes).
    static let bundleData: Data = try! Data(contentsOf: resources.appendingPathComponent("reader-fr.txt"))
    static let bundleID = ReaderBundle.textID(language: .fr, data: bundleData)
    static let bundle = SentenceReader(bundle: bundleData)
    static let atlasFonts: (body: ReaderFont, big: ReaderFont) = {
        _ = BundledFontsTests.registered
        return (try! TarotFonts.body(), try! TarotFonts.big())
    }()
    static let item = OracleItem(id: bundleID, deck: "tarot-dodal-dk108-9c1e", keys: "tarot-dodal-fr-keys-1a2b",
                                 font: atlasFonts.body.id, fontBig: atlasFonts.big.id)

    /// What the virtual clip composes from (the fake deck and keys, the bundle and the fonts).
    static func clipAssets() throws -> OracleCompositor.Assets {
        let a = try fakeAssets()
        return OracleCompositor.Assets(deck: try HCAFile(data: a.deck).decodeAllFrames(), keys: try HCAFile(data: a.keys).decodeAllFrames(),
                                       notes: [], font: ReaderBoundFont(atlasFonts.body),
                                       bundle: bundle, fontBig: ReaderBoundFont(atlasFonts.big))
    }

    /// Puts the bundle and both fonts on `clip`.
    static func putReader(_ clip: VirtualClipClient) async throws {
        for f in [atlasFonts.body, atlasFonts.big] {
            for a in f.atlases { _ = try await clip.putAsset(id: a.id, data: a.data, progress: nil) }
            try await clip.putFont(id: f.id, f.document)
        }
        _ = try await clip.putText(id: bundleID, data: bundleData)
    }

    /// Something written in the text column (x 168…520).
    func ink(_ f: RGB565Frame) -> Int {
        var n = 0
        for y in 0..<f.height { for x in OracleScreens.columnX..<(OracleScreens.columnX + OracleScreens.columnWidth) where f.pixels[y * f.width + x] != 0 { n += 1 } }
        return n
    }

    func testItemJSONMatchesTheContract() throws {
        let item = Self.item.playlistItem(durationMs: 0, transition: .fade)
        let json = try jsonObject(ClipJSON.encoder().encode(item))
        XCTAssertEqual(json, try jsonObject("""
            {"type":"oracle","id":"\(Self.bundleID)","reader":"\(Self.bundleID)","deck":"tarot-dodal-dk108-9c1e",
             "keys":"tarot-dodal-fr-keys-1a2b","font":"\(Self.atlasFonts.body.id)",
             "font_big":"\(Self.atlasFonts.big.id)","cards":22,"shake_g":0.9,
             "face_ms":0,"page_ms":0,"hold_ms":300000,"duration_ms":0,"transition":"fade"}
            """), "§5f.2/§5f.6/§5f.7: no text asset, no pages, no mode, no daily, no notes; id = the bundle's /texts id")
        // Older items' mode / daily / notes are read and ignored.
        let decoded = try JSONDecoder().decode(PlaylistItem.self, from: Data("""
            {"type":"oracle","id":"t","deck":"d","keys":"k","notes":"n","mode":"day","daily":false}
            """.utf8))
        let o = try XCTUnwrap(OracleItem(item: decoded))
        XCTAssertEqual(o, OracleItem(id: "t", deck: "d", keys: "k"), "defaults for the rest")
        XCTAssertNil((try jsonObject(ClipJSON.encoder().encode(o.playlistItem())) as! NSDictionary)["notes"], "never sent again")
        let back = try jsonObject(ClipJSON.encoder().encode(decoded)) as! NSDictionary
        XCTAssertNil(back["mode"]); XCTAssertNil(back["daily"])
        XCTAssertNil(OracleItem(item: PlaylistItem(type: .oracle, id: "t", durationMs: 0)), "needs its deck")
        XCTAssertEqual(item.assetRefs, Self.item.assetIDs)
        // A queue entry names the bundle "asset" and carries the rest.
        let m = Moment(id: "t-or", at: 1_760_000_000, content: .oracle(Self.item), durationS: 60, title: "Tarot")
        let entry = try jsonObject(ClipJSON.encoder().encode(m.entry)) as! NSDictionary
        XCTAssertEqual(entry["asset"] as? String, Self.bundleID)
        XCTAssertEqual(entry["font_big"] as? String, Self.atlasFonts.big.id)
        XCTAssertEqual(entry["deck"] as? String, "tarot-dodal-dk108-9c1e")
        XCTAssertNil(entry["mode"])
        XCTAssertEqual(m.entry.asPlaylistItem.assetRefs, Self.item.assetIDs)
        // The playlist's asset ids carry the deck and keys (§5f.12).
        let pl = Playlist(items: [.asset("pic", durationMs: 0), item], queue: [m.entry])
        XCTAssertEqual(pl.assetIDs, ["pic"] + Self.item.assetIDs)
        XCTAssertEqual(Self.item.assetIDs, ["tarot-dodal-dk108-9c1e", "tarot-dodal-fr-keys-1a2b"])
        XCTAssertEqual(pl.oracleReaderIDs, [Self.bundleID])
        XCTAssertEqual(pl.oracleFontIDs, [Self.atlasFonts.body.id, Self.atlasFonts.big.id])
        XCTAssertEqual(pl.oracleItem(for: Self.item.id)?.deck, Self.item.deck)
        // Ids are valid asset ids.
        for part in [nil, Oracle.deckIDPart] {
            let id = OracleItem.makeID(language: "fr", part: part, existing: [])
            XCTAssertTrue(HCA.isValidAssetID(id), id)
            XCTAssertTrue(id.hasPrefix("tarot-dodal-fr"), id)
        }
        XCTAssertTrue(OracleItem.makeID(language: nil, part: "deck", existing: []).hasPrefix("tarot-dodal-deck-"))
        // §5f.12: the 108×206 deck has its own id (`dk108`), so a deck of another size is remade and sent once.
        let deckID = OracleItem.makeID(language: nil, part: Oracle.deckIDPart, existing: [])
        XCTAssertTrue(deckID.hasPrefix("tarot-dodal-dk108-") && Oracle.isCurrentDeckID(deckID), deckID)
        XCTAssertFalse(Oracle.isCurrentDeckID("tarot-dodal-deck-9c1e"))
        XCTAssertFalse(Oracle.isCurrentDeckID("tarot-dodal-deck11-9c1e"))
        // The draw request.
        XCTAssertEqual(try jsonObject(ClipJSON.encoder().encode(OracleDrawRequest(cards: [3, 9, 17]))), try jsonObject(#"{"cards":[3,9,17]}"#))
        XCTAssertEqual(try jsonObject(ClipJSON.encoder().encode(OracleDrawRequest())), try jsonObject("{}"))
    }

    func testStatusDecoding() throws {
        let st = try JSONDecoder().decode(ClipStatus.OracleStatus.self, from: Data("""
            {"cards":22,"state":"detail","cards_drawn":[17,1,13],"card":1,"page":1,"reading":""}
            """.utf8))
        XCTAssertEqual(st, ClipStatus.OracleStatus(cards: 22, state: .detail, cardsDrawn: [17, 1, 13], card: 1, page: 1))
        XCTAssertEqual(st.three, [17, 1, 13])
        XCTAssertTrue(st.cardShowing)
        // Older firmware's keys are read and ignored.
        let older = try JSONDecoder().decode(ClipStatus.OracleStatus.self, from: Data("""
            {"mode":"sentence","cards":22,"state":"question","question":4,"cards_drawn":[-1,-1,-1],"card":4,"page":-1,"daily_card":4}
            """.utf8))
        XCTAssertEqual(older.state, .waits, "the question state is no more: read as waits")
        XCTAssertEqual(older.card, 4)
        let lean = try JSONDecoder().decode(ClipStatus.OracleStatus.self, from: Data(#"{"state":"lean","page":4,"reading":"x"}"#.utf8))
        XCTAssertEqual(lean.state, .lean)
        XCTAssertEqual(lean.page, 4)
        XCTAssertEqual(lean.reading, "x")
        let armed = try JSONDecoder().decode(ClipStatus.OracleStatus.self, from: Data(#"{"state":"armed","cards_drawn":[-1,-1,-1]}"#.utf8))
        XCTAssertEqual(armed.state, .armed, "§5f.8")
        XCTAssertFalse(armed.cardShowing)
        XCTAssertTrue(armed.drawInProgress)
        for retired in ["short", "thread", "reading", "paragraph", "face", "question"] {
            let old = try JSONDecoder().decode(ClipStatus.OracleStatus.self, from: Data(#"{"state":"\#(retired)"}"#.utf8))
            XCTAssertEqual(old.state, .waits, "§5f.7: \(retired) reads as waits")
        }
        let out = try jsonObject(ClipJSON.encoder().encode(st)) as! NSDictionary
        XCTAssertEqual(Set(out.allKeys as! [String]), ["cards", "state", "cards_drawn", "card", "page", "reading"])
        let sparse = try JSONDecoder().decode(ClipStatus.OracleStatus.self, from: Data(#"{"state":"levitating"}"#.utf8))
        XCTAssertEqual(sparse.state, .waits, "unknown states read as waits")
        XCTAssertEqual(sparse.cardsDrawn, [-1, -1, -1])
        XCTAssertNil(sparse.three)
        // Old firmware: no "oracle" key at all.
        let old = """
            {"ok":true,"device":{"name":"PixelClip","id":"a1b2","fw":"0.1.0","hw":"x","protocol":1},"battery":{"mv":3870,"pct":64,"charging":false},
             "storage":{"total":1,"used":0,"free":1},"playlist":{"count":1,"index":0,"current":"oracle:tarot-dodal-fr-3f2a"},
             "time":{"epoch":1760100000,"tz_offset_s":7200,"synced":true},"uptime_s":5}
            """
        let s = try JSONDecoder().decode(ClipStatus.self, from: Data(old.utf8))
        XCTAssertNil(s.oracle)
        XCTAssertEqual(Oracle.fnv1a(Array("".utf8)), 0x811C_9DC5)
        XCTAssertEqual(Oracle.fnv1a(Array("foobar".utf8)), 0xBF9C_F968)
    }

    // MARK: State machine (§5f.6 one reading only, §5f.7 the lean draw)

    static let t0 = Date(timeIntervalSince1970: 1_792_310_400)   // 2026-10-18 08:00 UTC

    /// Without a reader (no lean screens, no details, no paragraph): waits → armed → shuffle → three → hold → waits.
    func testFlowWithTaps() {
        var m = OracleMachine(cards: 22, faceMs: 0, pageMs: 0, holdMs: 0, seed: 7)
        var t = Self.t0
        XCTAssertEqual(m.state, .waits)
        m.turn(at: t)
        XCTAssertEqual(m.state, .armed, "§5f.8: a tap on waits arms")
        m.turn(at: t)
        XCTAssertEqual(m.state, .shuffle, "a tap on armed deals")
        XCTAssertEqual(m.cardsDrawn, [-1, -1, -1], "not before they land")
        if case .shuffleThree = m.view(at: t) {} else { XCTFail("the shuffle") }
        m.turn(at: t + 0.5)
        XCTAssertEqual(m.state, .shuffle, "a tap during the shuffle does nothing")
        t += 1.2
        m.advance(to: t)
        XCTAssertEqual(m.state, .three)
        let abc = m.cardsDrawn
        XCTAssertEqual(Set(abc).count, 3, "three different cards")
        XCTAssertEqual(m.view(at: t), .three(abc))
        XCTAssertEqual(m.card, -1)
        m.turn(at: t)
        XCTAssertEqual(m.state, .hold)
        XCTAssertEqual(m.view(at: t), .hold(abc), "the three again")
        XCTAssertEqual(m.card, -1)
        t += 3600
        m.advance(to: t)
        XCTAssertEqual(m.state, .hold, "hold_ms 0: no idle timeout")
        m.turn(at: t)
        XCTAssertEqual(m.state, .waits)
        XCTAssertEqual(m.cardsDrawn, [-1, -1, -1])
        m.back(at: t)
        XCTAssertEqual(m.state, .waits, "back on waits does nothing")
    }

    func testTimersStillWorkWhenSet() {
        // §5f.3: non-zero timers still auto-advance; hold_ms is the idle timeout from the draw (the last input).
        var m = OracleMachine(cards: 22, faceMs: 9000, pageMs: 12000, holdMs: 300_000, seed: 3, reader: Self.bundle)
        let t = Self.t0
        m.draw(at: t)
        // shuffle 1.2 + three 9 + five lean screens and three details × 12, then the hold until 300 s idle.
        let marks: [(Double, OracleState)] = [(0.5, .shuffle), (1.3, .three), (10.1, .three), (10.3, .lean), (10.2 + 59.9, .lean),
                                              (10.2 + 60.1, .detail), (10.2 + 95.9, .detail), (10.2 + 96.1, .hold), (299.9, .hold),
                                              (300.1, .waits)]
        for (dt, state) in marks {
            m.advance(to: t + dt)
            XCTAssertEqual(m.state, state, "at \(dt) s")
        }
    }

    func testEveryDrawIsANewRow() {
        var m = OracleMachine(cards: 22, seed: 9)
        var t = Self.t0
        var rows: [[Int]] = []
        for _ in 0..<300 {
            m.draw(at: t)
            t += 2
            m.advance(to: t)
            rows.append(m.cardsDrawn)
        }
        XCTAssertTrue(rows.allSatisfy { Set($0).count == 3 && $0.allSatisfy { (0..<22).contains($0) } }, "three distinct cards")
        XCTAssertTrue(zip(rows, rows.dropFirst()).allSatisfy { Set($0) != Set($1) }, "never the previous row as a set")
        XCTAssertGreaterThan(Set(rows.flatMap { $0 }).count, 20, "every card turns up")
        // A forced row wins (a bad one is ignored by the machine; the clip answers 422).
        m.draw(at: t, cards: [3, 9, 17])
        m.advance(to: t + 1.2)
        XCTAssertEqual(m.cardsDrawn, [3, 9, 17])
        XCTAssertTrue(m.isRow([0, 1, 21]))
        XCTAssertFalse(m.isRow([1, 1, 2]))
        XCTAssertFalse(m.isRow([1, 2, 22]))
        XCTAssertFalse(m.isRow([1, 2]))
        // A three-card deck can only repeat its one set.
        var tiny = OracleMachine(cards: 3, seed: 1)
        tiny.draw(at: t); tiny.draw(at: t + 1)
        XCTAssertEqual(Set(tiny.lastThree), [0, 1, 2])
    }

    func testShakeIsCountedOnce() {
        var m = OracleMachine(cards: 22, shakeG: 0.9, seed: 1)
        let t = Self.t0
        m.turn(at: t)                                    // armed
        m.sample(1.2, at: t)
        m.sample(1.0, at: t + 0.1)
        m.sample(0.6, at: t + 0.2)
        XCTAssertEqual(m.drawn.count, 1, "still above shake_g/2: one shake")
        m.advance(to: t + 1.3)
        m.back(at: t + 1.3)                              // three → waits
        m.turn(at: t + 1.3)                              // armed again
        m.sample(1.0, at: t + 1.4)
        XCTAssertEqual(m.drawn.count, 1, "not re-armed: the metric never fell below shake_g/2")
        m.sample(0.3, at: t + 1.5)
        m.sample(1.0, at: t + 1.6)
        XCTAssertEqual(m.drawn.count, 2, "re-armed below shake_g/2")
    }

    /// §5f.8: a tap arms, a shake (or a tap) deals; shakes do nothing on waits and from the shuffle through the hold;
    /// back disarms; armed idles out; `POST /oracle/draw` deals from waits.
    func testArmingAndTheShakeGate() {
        var m = OracleMachine(cards: 22, holdMs: 60_000, seed: 4)
        var t = Self.t0
        func shake() { t += 0.1; m.sample(0.1, at: t); t += 0.1; m.sample(1.5, at: t) }
        shake()
        XCTAssertEqual(m.state, .waits, "a shake on waits does nothing")
        XCTAssertTrue(m.drawn.isEmpty)
        t += 1; m.turn(at: t)
        XCTAssertEqual(m.state, .armed)
        XCTAssertEqual(m.view(at: t), .armed)
        XCTAssertEqual(m.status(at: t), ClipStatus.OracleStatus(cards: 22, state: .armed))
        t += 1; m.back(at: t)
        XCTAssertEqual(m.state, .waits, "back on armed disarms")
        XCTAssertEqual(m.waitsSince, t)
        t += 1; m.turn(at: t)
        shake()
        XCTAssertEqual(m.state, .shuffle, "a shake on armed deals")
        XCTAssertEqual(m.drawn.count, 1)
        shake()
        XCTAssertEqual(m.state, .shuffle, "ignored during the shuffle")
        t += 1.3; m.advance(to: t)
        XCTAssertEqual(m.state, .three)
        let row = m.three
        shake()
        XCTAssertEqual(m.state, .three, "ignored on the three")
        XCTAssertEqual(m.three, row)
        m.turn(at: t)
        XCTAssertEqual(m.state, .hold)
        shake()
        XCTAssertEqual(m.state, .hold, "ignored on the hold")
        XCTAssertEqual(m.drawn.count, 1)
        m.turn(at: t)
        XCTAssertEqual(m.state, .waits, "the only way to a new draw: back to waits")
        shake()
        XCTAssertEqual(m.state, .waits)
        m.turn(at: t); m.turn(at: t)
        XCTAssertEqual(m.state, .shuffle, "a tap on armed deals too (a clip on the table)")
        XCTAssertEqual(m.drawn.count, 2)
        t += 1.3; m.advance(to: t)
        m.back(at: t)
        XCTAssertEqual(m.state, .waits)
        // Armed idles to waits after hold_ms.
        t += 1; m.turn(at: t)
        m.advance(to: t + 59.9)
        XCTAssertEqual(m.state, .armed)
        m.advance(to: t + 60.1)
        XCTAssertEqual(m.state, .waits)
        XCTAssertEqual(m.waitsSince, t + 60, "the end of the draw, for the deferred playlist")
        // POST /oracle/draw deals from waits.
        m.draw(at: t + 61)
        XCTAssertEqual(m.state, .shuffle)
    }

    func testShuffleEndsOnTheChosenCard() {
        for seed: UInt32 in [1, 2, 3, 99] {
            let ticks = (0..<OracleMachine.shuffleTicks).map { OracleMachine.shuffleCard(tick: $0, chosen: 7, cards: 22, seed: seed) }
            XCTAssertEqual(ticks.last, 7)
            XCTAssertFalse(ticks.dropLast().contains(7), "the chosen card only lands at the end")
            XCTAssertTrue(zip(ticks, ticks.dropFirst()).allSatisfy { $0 != $1 }, "never the same twice running")
        }
    }

    // MARK: Virtual clip

    /// Small stand-in assets with a distinct flat colour per frame, so a composed screen shows which
    /// frame went where.
    static func fakeAssets(cards: Int = 22, pages: Int = 2) throws -> (text: Data, deck: Data, keys: Data, notes: Data) {
        func enc(_ w: Int, _ h: Int, _ n: Int, _ base: UInt16, slot: Bool = false) throws -> Data {
            try HCAEncoder.encode(frames: (0..<n).map { i -> HCAEncoder.Frame in
                var f = RGB565Frame(width: w, height: h, fill: base &+ UInt16(i))
                if slot {
                    let s = Oracle.slot
                    for y in s.y..<(s.y + s.h) { for x in s.x..<(s.x + s.w) { f.pixels[y * w + x] = 0 } }
                }
                return .init(pixels: f, durationMs: 0)
            }, glyphAtlas: !slot)
        }
        return (try enc(536, 240, Oracle.textFrames(cards: cards, pages: pages), 0x1000, slot: true),
                try enc(Oracle.cardWidth, Oracle.cardHeight, Oracle.deckFrames(cards: cards), 0x4000),
                try enc(Oracle.keyWidth, Oracle.keyHeight, cards, 0x6000), try enc(536, 72, cards, 0x8000))
    }

    static func seededClip(synced: Bool = true) async throws -> (VirtualClipClient, ClockBox) {
        let clock = ClockBox(t0)
        let clip = VirtualClipClient(options: .instant, clock: { clock.now })
        await clip.setOracleSeed(21)
        if synced { try await clip.setTime(TimeSync(epoch: Int(t0.timeIntervalSince1970), tzOffsetS: 0)) }
        let a = try fakeAssets()
        let o = item
        try await putReader(clip)
        _ = try await clip.putAsset(id: o.deck, data: a.deck, progress: nil)
        _ = try await clip.putAsset(id: o.keys!, data: a.keys, progress: nil)
        return (clip, clock)
    }

    func px(_ f: RGB565Frame, _ x: Int, _ y: Int) -> UInt16 { f.pixels[y * f.width + x] }

    func testVirtualClipFlow() async throws {
        let (clip, clock) = try await Self.seededClip()
        await expectHTTP(409, "not_showing") { try await clip.oracleDraw(cards: nil) }
        await expectHTTP(409, "not_showing") { try await clip.oracleTurn() }
        await expectHTTP(409, "not_showing") { try await clip.oracleBack() }
        let o = Self.item
        try await clip.putPlaylist(Playlist(items: [o.playlistItem(durationMs: 0, transition: nil)]))
        var st = try await clip.status()
        XCTAssertEqual(st.playlist.current, "oracle:\(o.id)")
        XCTAssertEqual(st.oracle, ClipStatus.OracleStatus(cards: 22, state: .waits))
        var d = await clip.display()
        XCTAssertEqual(d.nowShowing, "oracle:\(o.id)")
        XCTAssertGreaterThan(ink(d.frame), 200, "the prompt, written from the bundle")
        XCTAssertEqual(px(d.frame, Oracle.singleCardX(flipped: false) + 50, 120), 0x4000, "the back, left")
        XCTAssertEqual(px(d.frame, Oracle.singleCardX(flipped: false) + 50, 5), 0, "at y 13")
        XCTAssertEqual(d.frame, OracleCompositor.frame(.waits, try Self.clipAssets()))
        try await clip.oracleBack()
        st = try await clip.status()
        XCTAssertEqual(st.oracle?.state, .waits, "back on waits does nothing")

        // §5f.8: a tap on waits arms (the back, the armed prompt), a second tap deals: the shuffle, then the three.
        try await clip.oracleTurn()
        st = try await clip.status()
        XCTAssertEqual(st.oracle?.state, .armed)
        d = await clip.display()
        XCTAssertEqual(d.frame, OracleCompositor.frame(.armed, try Self.clipAssets()))
        XCTAssertEqual(px(d.frame, Oracle.singleCardX(flipped: false) + 50, 120), 0x4000, "the back, left")
        XCTAssertEqual(px(d.frame, Oracle.singleCardX(flipped: false) + 50, 5), 0, "at y 13")
        XCTAssertNotEqual(d.frame, OracleCompositor.frame(.waits, try Self.clipAssets()), "its own line")
        try await clip.oracleTurn()
        st = try await clip.status()
        XCTAssertEqual(st.oracle?.state, .shuffle)
        clock.now += 1.2
        st = try await clip.status()
        XCTAssertEqual(st.oracle?.state, .three)
        let abc = try XCTUnwrap(st.oracle?.three)
        XCTAssertEqual(Set(abc).count, 3)
        d = await clip.display()
        for k in 0..<3 {
            XCTAssertEqual(px(d.frame, Oracle.threeCardX[k] + 50, 100), 0x4000 + UInt16(1 + abc[k]), "card \(k)")
        }
        for k in 0..<3 { XCTAssertEqual(px(d.frame, Oracle.threeKeyX[k] + 80, Oracle.threeKeyY + 13), 0x6000 + UInt16(abc[k]), "key \(k)") }
        XCTAssertEqual(px(d.frame, 30, 100), 0, "black ground (the cards are centred: 50, 212, 374)")
        let body = ReaderBoundFont(Self.atlasFonts.body).normal

        // §5f.7: the five lean screens (one page each, written full width), then each card's brief, then the hold.
        let fits: @Sendable (String) -> Bool = { OracleScreens.fitsLeanPage($0, face: body) }
        let lean = try XCTUnwrap(Self.bundle.composeLean(a: abc[0], b: abc[1], c: abc[2], fits: fits))
        XCTAssertEqual(lean.count, 5)
        let paragraph = try XCTUnwrap(Self.bundle.compose(a: abc[0], b: abc[1], c: abc[2])?.text)
        XCTAssertEqual(st.oracle?.reading, paragraph, "the whole paragraph on the three")
        XCTAssertTrue(paragraph.hasSuffix(try XCTUnwrap(Self.bundle.field(abc[1], .closing))), "the centre card's closing")
        var screens: [String] = []
        for _ in 0..<12 {
            try await VirtualClipClient.$transport.withValue(.bluetooth) { try await clip.oracleTurn() }
            st = try await clip.status()
            let o = try XCTUnwrap(st.oracle)
            d = await clip.display()
            switch o.state {
            case .lean:
                XCTAssertEqual(o.reading, lean[o.page])
                XCTAssertEqual(o.card, -1)
                XCTAssertEqual(d.frame, OracleCompositor.frame(.lean(lean[o.page]), try Self.clipAssets()))
                XCTAssertTrue(OracleScreens.fitsLeanPage(lean[o.page], face: body), "lean \(o.page) is one page")
                screens.append("lean\(o.page)")
            case .detail:
                XCTAssertEqual(o.card, abc[o.page])
                let brief = try XCTUnwrap(Self.bundle.field(abc[o.page], .brief))
                XCTAssertEqual(o.reading, brief)
                let laid = OracleScreens.detail(brief, font: ReaderBoundFont(Self.atlasFonts.body))
                XCTAssertTrue(laid.card, "detail \(o.page): the brief fits beside its card")
                XCTAssertEqual(px(d.frame, Oracle.singleCardX(flipped: false) + 50, 120), 0x4000 + UInt16(1 + abc[o.page]), "the card beside the brief")
                screens.append("detail\(o.page)")
            default:
                screens.append(o.state.rawValue)
            }
            XCTAssertGreaterThan(d.frame.pixels.filter { $0 != 0 }.count, 300, "\(screens.last!) has ink")
            if o.state == .hold { break }
        }
        XCTAssertEqual(screens, ["lean0", "lean1", "lean2", "lean3", "lean4", "detail0", "detail1", "detail2", "hold"],
                       "at most 11 one-page screens: waits, three, five lean, three details, the three again")
        XCTAssertEqual(st.oracle?.three, abc)
        XCTAssertEqual(st.oracle?.reading, paragraph, "the whole paragraph on the hold")
        XCTAssertEqual(st.oracle?.page, -1)
        // Back walks the reverse: the hold → the last detail → … → the first lean screen → the three → waits.
        var backs: [String] = []
        for _ in 0..<12 {
            try await clip.oracleBack()
            st = try await clip.status()
            let o = try XCTUnwrap(st.oracle)
            backs.append(o.state == .lean || o.state == .detail ? "\(o.state.rawValue)\(o.page)" : o.state.rawValue)
            if o.state == .waits { break }
        }
        XCTAssertEqual(backs, ["detail2", "detail1", "detail0", "lean4", "lean3", "lean2", "lean1", "lean0", "three", "waits"])

        // A forced row over the fast lane; a bad one is refused.
        try await VirtualClipClient.$transport.withValue(.bluetooth) { try await clip.oracleDraw(cards: [3, 9, 17]) }
        clock.now += 1.3
        st = try await clip.status()
        XCTAssertEqual(st.oracle?.three, [3, 9, 17])
        await expectHTTP(422, "invalid_cards") { try await clip.oracleDraw(cards: [3, 3, 17]) }
        await expectHTTP(422, "invalid_cards") { try await clip.oracleDraw(cards: [3, 9, 22]) }
        // The next random draw is another row.
        try await clip.oracleDraw(cards: nil)
        clock.now += 1.3
        st = try await clip.status()
        XCTAssertNotEqual(Set(try XCTUnwrap(st.oracle?.three)), [3, 9, 17])

        // The phone's own shake: ignored mid-draw and on waits, it deals once armed.
        let metric = ClockBox(Date(timeIntervalSince1970: 0))
        await clip.setShakeSource { metric.now.timeIntervalSince1970 }
        try await clip.oracleTurn()
        st = try await clip.status()
        XCTAssertEqual(st.oracle?.state, .lean)
        metric.now = Date(timeIntervalSince1970: 1.5)
        st = try await clip.status()
        XCTAssertEqual(st.oracle?.state, .lean, "§5f.8: shakes are ignored during a draw")
        metric.now = Date(timeIntervalSince1970: 0.1)
        for _ in 0..<4 { try await clip.oracleBack() }   // lean 0 → three → waits (then nothing)
        st = try await clip.status()
        XCTAssertEqual(st.oracle?.state, .waits)
        metric.now = Date(timeIntervalSince1970: 1.5)
        st = try await clip.status()
        XCTAssertEqual(st.oracle?.state, .waits, "a shake on waits does nothing")
        metric.now = Date(timeIntervalSince1970: 0.1)
        _ = try await clip.status()
        try await clip.oracleTurn()
        metric.now = Date(timeIntervalSince1970: 1.5)
        st = try await clip.status()
        XCTAssertEqual(st.oracle?.state, .shuffle, "armed: the shake deals")
        XCTAssertEqual(try XCTUnwrap(Self.bundle.text("prompt.armed")).isEmpty, false)

        // Nothing showing → 409, no oracle status.
        _ = try await clip.putAsset(id: "pic", data: try clipAsset(0x1234), progress: nil)
        try await clip.putPlaylist(Playlist(items: [.asset("pic", durationMs: 0)]))
        await expectHTTP(409, "not_showing") { try await clip.oracleTurn() }
        st = try await clip.status()
        XCTAssertNil(st.oracle)
    }

    /// §5f.8: while a draw is in progress the item's end and queue entries wait; back at waits they fire at once.
    func testNoInterruptionsWhileADrawIsInProgress() async throws {
        let (clip, clock) = try await Self.seededClip()
        _ = try await clip.putAsset(id: "pic", data: try clipAsset(0x1234), progress: nil)
        _ = try await clip.putAsset(id: "pic2", data: try clipAsset(0x2345), progress: nil)
        let t0 = clock.now
        let o = Self.item
        let entry = Moment(id: "q-pic2", at: Int(t0.timeIntervalSince1970) + 30, content: .asset("pic2"), durationS: 30, title: "Pic").entry
        try await clip.putPlaylist(Playlist(items: [o.playlistItem(durationMs: 20_000, transition: .cut), .asset("pic", durationMs: 20_000)],
                                            queue: [entry]))
        var st = try await clip.status()
        XCTAssertEqual(st.playlist.current, "oracle:\(o.id)")
        clock.now = t0 + 1
        try await clip.oracleTurn()                                  // arm
        try await clip.oracleTurn()                                  // deal
        clock.now = t0 + 21
        st = try await clip.status()
        XCTAssertEqual(st.playlist.current, "oracle:\(o.id)", "the rotation end waits for the draw")
        XCTAssertEqual(st.oracle?.state, .three)
        clock.now = t0 + 35
        st = try await clip.status()
        XCTAssertEqual(st.playlist.current, "oracle:\(o.id)", "the queue entry waits for the draw")
        XCTAssertEqual(st.queue?.pending, 1)
        // Back on the three → waits: the deferred entry fires at once.
        clock.now = t0 + 40
        try await clip.oracleBack()
        st = try await clip.status()
        XCTAssertEqual(st.playlist.current, "pic2", "due, fired as soon as the draw ended")
        XCTAssertNil(st.oracle)
        // After the entry (30 s from 40), the interrupted oracle restarts; a new draw holds it past 20 s again.
        clock.now = t0 + 71
        st = try await clip.status()
        XCTAssertEqual(st.playlist.current, "oracle:\(o.id)")
        try await clip.oracleTurn()
        st = try await clip.status()
        XCTAssertEqual(st.oracle?.state, .armed, "armed is a draw in progress too")
        clock.now = t0 + 100
        st = try await clip.status()
        XCTAssertEqual(st.playlist.current, "oracle:\(o.id)", "held past its 20 s while armed")
        try await clip.oracleBack()                                  // disarm at 100
        clock.now = t0 + 100.5
        st = try await clip.status()
        XCTAssertEqual(st.playlist.current, "pic", "the rotation moves on when the draw ends")
        clock.now = t0 + 119
        st = try await clip.status()
        XCTAssertEqual(st.playlist.current, "pic", "the next item's 20 s count from the draw's end")
        clock.now = t0 + 121
        st = try await clip.status()
        XCTAssertEqual(st.playlist.current, "oracle:\(o.id)")
        // A /show still takes effect at once.
        try await clip.oracleTurn()
        try await clip.show(id: "pic", durationMs: 5_000, scroll: nil)
        st = try await clip.status()
        XCTAssertEqual(st.playlist.current, "pic")
    }

    /// §5f.8 in the playback engine: an oracle mid-draw stays past its window; the window applies again once it ends.
    func testDrawHoldsTheOraclePastItsWindow() {
        let t0 = Self.t0                                     // 08:00 UTC
        var oracle = Self.item.playlistItem(durationMs: 0, transition: .cut)
        oracle.from = TimeOfDay(hour: 7, minute: 0); oracle.until = TimeOfDay(hour: 8, minute: 1)
        var e = PlaybackEngine(now: t0)
        e.setClockSynced(now: t0)
        e.setPlaylist(Playlist(items: [oracle, .asset("pic", durationMs: 10_000)]), now: t0)
        XCTAssertEqual(e.state(at: t0 + 1, timing: { _ in nil }).content, .oracle(Self.item))
        e.setDrawInProgress(true, at: t0 + 2)
        XCTAssertEqual(e.state(at: t0 + 90, timing: { _ in nil }).content, .oracle(Self.item), "08:01:30, outside its window: held")
        e.setDrawInProgress(false, at: t0 + 100)
        XCTAssertEqual(e.state(at: t0 + 101, timing: { _ in nil }).content, .asset(id: "pic", frame: 0), "the window applies again")
    }

    func testVirtualClipTimersAndIdle() async throws {
        let (clip, clock) = try await Self.seededClip(synced: false)
        var o = Self.item
        o.faceMs = 9000; o.pageMs = 12_000; o.holdMs = 600_000    // timers on (they still work when set)
        try await clip.putPlaylist(Playlist(items: [o.playlistItem(durationMs: 0, transition: nil)]))
        try await clip.oracleDraw(cards: [17, 3, 9])
        clock.now += 1.2
        var st = try await clip.status()
        XCTAssertEqual(st.oracle?.state, .three)
        clock.now += 9
        st = try await clip.status()
        XCTAssertEqual(st.oracle?.state, .lean)
        XCTAssertEqual(st.oracle?.page, 0)
        clock.now += 12 * 5
        st = try await clip.status()
        XCTAssertEqual(st.oracle?.state, .detail)
        XCTAssertEqual(st.oracle?.card, 17)
        clock.now = Self.t0 + 600.1                                // 10 minutes after the draw, the last input
        st = try await clip.status()
        XCTAssertEqual(st.oracle?.state, .waits, "the idle timeout")
    }

    func testVirtualClipValidatesOracleItems() async throws {
        let (clip, _) = try await Self.seededClip()
        var bad = Self.item
        bad.font = nil
        await expectHTTP(422, "invalid_playlist") { try await clip.putPlaylist(Playlist(items: [bad.playlistItem()])) }
        bad = Self.item
        bad.font = "tarot-font22-00000000"
        await expectHTTP(422, "unknown_font") { try await clip.putPlaylist(Playlist(items: [bad.playlistItem()])) }
        bad = Self.item
        bad.fontBig = "tarot-big56-00000000"
        await expectHTTP(422, "unknown_font") { try await clip.putPlaylist(Playlist(items: [bad.playlistItem()])) }
        bad = Self.item
        bad.id = "tarot-reader-fr-0000000000"
        await expectHTTP(422, "unknown_text") { try await clip.putPlaylist(Playlist(items: [bad.playlistItem()])) }
        var mismatched = Self.item.playlistItem()
        mismatched.reader = "tarot-reader-fr-1111111111"
        await expectHTTP(422, "invalid_playlist") { try await clip.putPlaylist(Playlist(items: [mismatched])) }
        // A bundle without the prompt (or a card's reading) can't be written: 422 invalid_playlist.
        let stripped = String(decoding: Self.bundleData, as: UTF8.self).replacingOccurrences(of: "[prompt]", with: "[no-prompt]")
        _ = try await clip.putText(id: "tarot-reader-fr-2222222222", data: Data(stripped.utf8))
        bad = Self.item
        bad.id = "tarot-reader-fr-2222222222"
        await expectHTTP(422, "invalid_playlist") { try await clip.putPlaylist(Playlist(items: [bad.playlistItem()])) }
        bad = Self.item
        bad.deck = "nope"
        await expectHTTP(422, "unknown_asset") { try await clip.putPlaylist(Playlist(items: [bad.playlistItem()])) }
        bad = Self.item
        bad.shakeG = 3
        await expectHTTP(422, "invalid_playlist") { try await clip.putPlaylist(Playlist(items: [bad.playlistItem()])) }
        bad = Self.item
        bad.cards = 2
        await expectHTTP(422, "invalid_playlist") { try await clip.putPlaylist(Playlist(items: [bad.playlistItem()])) }
        // §5f.7: notes are accepted and ignored. §5f.12: keys are optional (absent: no keyword row); named, they must be there
        // and 160×34 × cards.
        var withOld = Self.item.playlistItem()
        withOld.notes = "tarot-dodal-fr-notes-never-uploaded"
        try await clip.putPlaylist(Playlist(items: [withOld]))
        var noKeys = Self.item
        noKeys.keys = nil
        try await clip.putPlaylist(Playlist(items: [noKeys.playlistItem()]))
        var missingKeys = Self.item
        missingKeys.keys = "tarot-dodal-fr-keys-never-uploaded"
        await expectHTTP(422, "unknown_asset") { try await clip.putPlaylist(Playlist(items: [missingKeys.playlistItem()])) }
        let wrongKeys = try HCAEncoder.encode(frames: (0..<22).map { _ in .init(pixels: RGB565Frame(width: 160, height: 30, fill: 1), durationMs: 0) },
                                              glyphAtlas: true)
        _ = try await clip.putAsset(id: "tarot-dodal-fr-keys-bad1", data: wrongKeys, progress: nil)
        missingKeys.keys = "tarot-dodal-fr-keys-bad1"
        await expectHTTP(422, "invalid_playlist") { try await clip.putPlaylist(Playlist(items: [missingKeys.playlistItem()])) }
        // §5f.12: a deck of another size (the old 104×198) is a misfitting atlas → invalid_playlist.
        let oldDeck = try HCAEncoder.encode(frames: (0..<23).map { _ in .init(pixels: RGB565Frame(width: 104, height: 198, fill: 0x1234), durationMs: 0) },
                                            glyphAtlas: true)
        _ = try await clip.putAsset(id: "tarot-dodal-deck-old1", data: oldDeck, progress: nil)
        var oldSize = Self.item
        oldSize.deck = "tarot-dodal-deck-old1"
        await expectHTTP(422, "invalid_playlist") { try await clip.putPlaylist(Playlist(items: [oldSize.playlistItem()])) }
        // The firmware stores the deck only as a glyph atlas: a plain 112×214 file is refused at upload.
        let plainDeck = try HCAEncoder.encode(frames: [.init(pixels: RGB565Frame(width: 112, height: 214), durationMs: 0)])
        await expectHTTP(422, "malformed") { _ = try await clip.putAsset(id: "plain-deck", data: plainDeck, progress: nil) }
        // The deck can't be shown as a plain picture.
        await expectHTTP(422, "unknown_asset") { try await clip.putPlaylist(Playlist(items: [.asset(Self.item.deck, durationMs: 0)])) }
        // A queue entry is accepted; deleting any of its pieces takes the item out.
        let m = Moment(id: "t-or", at: Int(Self.t0.timeIntervalSince1970) + 600, content: .oracle(Self.item), durationS: 60, title: "Tarot")
        try await clip.putPlaylist(Playlist(items: [Self.item.playlistItem()], queue: [m.entry]))
        let st = try await clip.status()
        XCTAssertEqual(st.playlist.current, "oracle:\(Self.item.id)")
        try await clip.deleteAsset(id: Self.item.keys!)
        var pl = try await clip.playlist()
        XCTAssertTrue(pl.items.isEmpty)
        _ = try await clip.putAsset(id: Self.item.keys!, data: try Self.fakeAssets().keys, progress: nil)
        try await clip.putPlaylist(Playlist(items: [Self.item.playlistItem()]))
        try await clip.deleteText(id: Self.bundleID)
        pl = try await clip.playlist()
        XCTAssertTrue(pl.items.isEmpty)
    }

    @MainActor
    func testDrawTurnAndBackOverTheFastLaneAndHTTP() async throws {
        let (clip, clock) = try await Self.seededClip()
        try await clip.putPlaylist(Playlist(items: [Self.item.playlistItem(durationMs: 0, transition: nil)]))
        let lane = VirtualFastLane(clip: clip, timing: .instant)
        lane.setConnected(true)
        let http = CountingClipClient(clip)
        let links = FakeLinks(lane: FastLaneClipClient(transport: BLETransport(link: lane)))
        let smart = SmartClipClient(http: http, links: links)
        try await smart.oracleDraw(cards: [3, 9, 17])
        clock.now += 1.3
        try await smart.oracleTurn()
        try await smart.oracleBack()
        let calls = await http.calls
        XCTAssertEqual(calls, [], "Bluetooth first")
        let log = await clip.fastLaneLog
        XCTAssertEqual(Array(log.suffix(3)), ["POST /oracle/draw", "POST /oracle/turn", "POST /oracle/back"])
        let st = try await clip.status()
        XCTAssertEqual(st.oracle?.three, [3, 9, 17])
        XCTAssertEqual(st.oracle?.state, .three, "turned to the first lean screen, then back")
        for path in ["/oracle/draw", "/oracle/turn", "/oracle/back"] {
            XCTAssertFalse(FastLaneRoute("POST", path).isIdempotent, "\(path) is never retried over Wi‑Fi")
            XCTAssertTrue(FastLaneRoute("POST", path).isEligible)
        }

        // On the wire.
        let scripted = ScriptedLink()
        let fl = FastLaneClipClient(transport: BLETransport(link: scripted))
        try await fl.oracleDraw(cards: [5, 6, 7])
        XCTAssertEqual(scripted.requests.last, FastLaneRequest("POST", "/oracle/draw", body: Data(#"{"cards":[5,6,7]}"#.utf8)))
        try await fl.oracleDraw(cards: nil)
        XCTAssertEqual(scripted.requests.last, FastLaneRequest("POST", "/oracle/draw", body: Data("{}".utf8)))
        try await fl.oracleTurn()
        XCTAssertEqual(scripted.requests.last?.path, "/oracle/turn")
        try await fl.oracleBack()
        XCTAssertEqual(scripted.requests.last?.method, "POST")
        XCTAssertEqual(scripted.requests.last?.path, "/oracle/back")

        let client = HTTPClipClient(baseURL: URL(string: "http://clip.test")!, protocolClasses: [CaptureProtocol.self])
        CaptureProtocol.reset()
        try await client.oracleDraw(cards: [7, 8, 9])
        try await client.oracleTurn()
        try await client.oracleBack()
        let reqs = CaptureProtocol.requests
        XCTAssertEqual(reqs.map(\.path), ["/oracle/draw", "/oracle/turn", "/oracle/back"])
        XCTAssertEqual(reqs.map(\.method), ["POST", "POST", "POST"])
        XCTAssertEqual(try jsonObject(reqs[0].body), try jsonObject(#"{"cards":[7,8,9]}"#))
    }

    // MARK: Now / playlist / sync plumbing

    func testNowPlaylistAndSyncPlumbing() async throws {
        let o = Self.item
        let now = NowItem(content: .oracle(o), title: "Tarot")
        XCTAssertEqual(now.content.assetID, o.libraryKey)
        XCTAssertEqual(now.content.assetIDs, o.assetIDs)
        XCTAssertEqual(try JSONDecoder().decode(NowItem.self, from: JSONEncoder().encode(now)), now)
        XCTAssertEqual(MomentContent(item: o.playlistItem()), .oracle(o))
        XCTAssertTrue(MomentContent.oracle(o).sameContent(as: .oracle(OracleItem(id: o.id, deck: "x", cards: 21))))

        // Held when alone; a minute in rotation with a fade next to a picture.
        let alone = PlaylistComposer.playlist(.init(now: now.slot { _ in nil }), now: Date())
        XCTAssertEqual(alone.items.map(\.type), [.oracle])
        XCTAssertEqual(alone.items[0].durationMs, 0)
        let layer = TonightLayer(extras: [.init(id: "x-pic", item: .asset("pic", durationMs: 10_000), title: "Pic")])
        let pl = PlaylistComposer.playlist(.init(now: now.slot { _ in nil }, tonight: layer), now: Date())
        XCTAssertEqual(pl.items.map(\.type), [.oracle, .asset])
        XCTAssertEqual(pl.items[0].durationMs, Oracle.rotationMs)
        XCTAssertEqual(pl.assetIDs, o.assetIDs + ["pic"])
        // The playlist gives an oracle three minutes (the clip cuts a reading off at the item's end).
        XCTAssertEqual(PlaylistSchedule.minute(o.playlistItem()).durationMs, 180_000)
        XCTAssertEqual(PlaylistSchedule.minute(.asset("pic", durationMs: 0)).durationMs, 60_000)

        // The playback engine plays it as an oracle.
        var engine = PlaybackEngine(now: Self.t0)
        engine.setPlaylist(alone, now: Self.t0)
        XCTAssertEqual(engine.state(at: Self.t0 + 500, timing: { _ in nil }).content, .oracle(o))

        // The pieces: the bundle and the fonts first (ReaderPusher), then the deck, the keys and the item (SyncEngine); a
        // failed piece drops the item.
        let a = try Self.fakeAssets()
        let local = [LocalAsset(id: o.deck, data: a.deck, name: nil), LocalAsset(id: o.keys!, data: a.keys, name: nil)]
        let text = ReaderPusher.Text(id: Self.bundleID, data: Self.bundleData, title: "Tarot")
        let clip = VirtualClipClient(options: .instant)
        let prepared = try await ReaderPusher(client: clip).prepareOracleReaders(alone, texts: [text], fonts: [Self.atlasFonts.body, Self.atlasFonts.big],
                                                                                keep: nil)
        XCTAssertEqual(prepared.playlist, alone)
        let report = await SyncEngine(client: clip).sync(local: local, playlist: prepared.playlist, options: SyncOptions(endSession: false))
        XCTAssertTrue(report.succeeded, "\(report.failures)")
        let ids = try await clip.assets().map(\.id)
        XCTAssertEqual(Set(ids), Set(o.assetIDs + Self.atlasFonts.body.atlases.map(\.id) + Self.atlasFonts.big.atlases.map(\.id)))
        let onClip = try await clip.playlist()
        XCTAssertEqual(onClip.items.first?.type, .oracle)

        let clip2 = VirtualClipClient(options: .instant)
        _ = try await ReaderPusher(client: clip2).prepareOracleReaders(alone, texts: [text], fonts: [Self.atlasFonts.body, Self.atlasFonts.big], keep: nil)
        await clip2.failUploads(of: [o.deck])
        let r2 = await SyncEngine(client: clip2).sync(local: local, playlist: alone, options: SyncOptions(endSession: false))
        XCTAssertFalse(r2.succeeded)
        let pl2 = try await clip2.playlist()
        XCTAssertTrue(pl2.items.isEmpty, "no oracle without its deck")
    }
}
