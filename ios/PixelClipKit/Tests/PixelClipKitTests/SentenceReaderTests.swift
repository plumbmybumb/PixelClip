import Foundation
import XCTest
@testable import PixelClipKit

/// The sentence reader (PROTOCOL §5f.1 v3, §5f.6 no question card, §5f.7 the lean draw) against the C engine: every
/// shared case of `core/fixtures/tarot/cases.json` and `cases-lean.json` byte for byte, 3 000 more rows the engine
/// wrote (digests of the paragraph and of the five lean screens), every row of a bundle when dumped, and the rules
/// one by one on small synthetic bundles.
final class SentenceReaderTests: XCTestCase {
    static let coreFixtures = Paths.repoRoot.appendingPathComponent("core/fixtures/tarot")
    static let tarotFixtures = Paths.fixturesDir.appendingPathComponent("tarot")

    // MARK: The shared cases

    struct Cases: Decodable {
        struct Case: Decodable {
            var bundle: String, q: Int, A: Int, B: Int, C: Int
            var sections: [String], dropped: [String], bytes: Int, text: String
        }
        struct Invalid: Decodable { var bundle: String, q: Int, A: Int, B: Int, C: Int, why: String }
        var format: Int, limit: Int, invalid: [Invalid], cases: [Case]
    }

    struct LeanCases: Decodable {
        struct Case: Decodable { var bundle: String, A: Int, B: Int, C: Int, texts: [String] }
        var format: Int, page_chars: Int, cases: [Case]
    }

    private var readers: [String: SentenceReader] = [:]
    private func reader(_ name: String, in dir: URL = SentenceReaderTests.coreFixtures) throws -> SentenceReader {
        if let r = readers["\(dir.path)/\(name)"] { return r }
        let r = SentenceReader(bundle: try Data(contentsOf: dir.appendingPathComponent("reader-\(name).txt")))
        readers["\(dir.path)/\(name)"] = r
        return r
    }

    func testEveryFixtureCaseByteForByte() throws {
        let cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: Self.coreFixtures.appendingPathComponent("cases.json")))
        XCTAssertEqual(cases.limit, SentenceReader.textMax)
        var matched = 0
        for c in cases.cases {
            let label = "\(c.bundle) \(c.q),\(c.A),\(c.B),\(c.C)"
            guard let p = try reader(c.bundle).compose(q: c.q, a: c.A, b: c.B, c: c.C) else { XCTFail("\(label): refused"); continue }
            XCTAssertEqual(p.bytes, Array(c.text.utf8), label)
            XCTAssertEqual(p.bytes.count, c.bytes, label)
            XCTAssertEqual(p.sections, c.sections, label)
            XCTAssertEqual(p.dropped, c.dropped, label)
            if p.bytes == Array(c.text.utf8) && p.sections == c.sections && p.dropped == c.dropped { matched += 1 }
        }
        for c in cases.invalid {
            XCTAssertNil(try reader(c.bundle).compose(q: c.q, a: c.A, b: c.B, c: c.C), c.why)
            if c.q == -1 { XCTAssertNil(try reader(c.bundle).composeLean(a: c.A, b: c.B, c: c.C), c.why) }
        }
        XCTAssertGreaterThanOrEqual(cases.cases.count, 100)
        XCTAssertEqual(matched, cases.cases.count)
        print("SENTENCE_READER_FIXTURES \(matched)/\(cases.cases.count) cases, \(cases.invalid.count) refusals")
    }

    /// §5f.7: the five lean screens with the reference page test (≤ `page_chars` code points; `fits` nil).
    func testEveryLeanFixtureCaseByteForByte() throws {
        let cases = try JSONDecoder().decode(LeanCases.self, from: Data(contentsOf: Self.coreFixtures.appendingPathComponent("cases-lean.json")))
        XCTAssertEqual(cases.page_chars, SentenceReader.leanPageChars)
        var matched = 0
        for c in cases.cases {
            let label = "\(c.bundle) \(c.A),\(c.B),\(c.C)"
            guard let got = try reader(c.bundle).composeLean(a: c.A, b: c.B, c: c.C) else { XCTFail("\(label): refused"); continue }
            XCTAssertEqual(got.map { Array($0.utf8) }, c.texts.map { Array($0.utf8) }, label)
            if got == c.texts { matched += 1 }
        }
        XCTAssertGreaterThanOrEqual(cases.cases.count, 100)
        XCTAssertEqual(matched, cases.cases.count)
        print("SENTENCE_READER_LEAN_FIXTURES \(matched)/\(cases.cases.count) cases")
    }

    /// `Fixtures/tarot/reader-rows.txt`: 1 500 random rows per language, written by the C engine over the bundles
    /// beside it (the paragraph's length, FNV-1a and budget bits; each lean screen's length and FNV-1a).
    func testEngineRowDigests() throws {
        let rows = try String(contentsOf: Self.tarotFixtures.appendingPathComponent("reader-rows.txt"), encoding: .utf8)
        XCTAssertEqual(try checkDigests(rows, bundles: Self.tarotFixtures), 3_000)
    }

    /// Every row (9 240 per bundle) when `PIXELCLIP_READER_ALL` names a folder holding the engine's `all-<tag>.txt` dumps
    /// (same format) and the `reader-<tag>.txt` bundles they were made from.
    func testEveryRowWhenDumped() throws {
        guard let dir = ProcessInfo.processInfo.environment["PIXELCLIP_READER_ALL"] else { throw XCTSkip("PIXELCLIP_READER_ALL not set") }
        let d = URL(fileURLWithPath: dir)
        var n = 0
        let dumps = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix("all-") }.sorted()
        for f in dumps { n += try checkDigests(try String(contentsOf: d.appendingPathComponent(f), encoding: .utf8), bundles: d) }
        print("SENTENCE_READER_ALL \(n) rows in \(dumps.count) bundles")
    }

    /// Lines `bundle A B C bytes fnv dropped-bits` then `bytes fnv` of each lean screen 0–4; returns the rows checked.
    private func checkDigests(_ rows: String, bundles: URL) throws -> Int {
        let bits = SentenceReader.dropBits
        var n = 0, bad = 0
        for line in rows.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: " ").map(String.init)
            guard f.count == 7 + 2 * SentenceReader.leanScreens else { continue }
            let r = try reader(f[0], in: bundles)
            let (a, b, c) = (Int(f[1])!, Int(f[2])!, Int(f[3])!)
            let p = r.compose(a: a, b: b, c: c)
            n += 1
            if Int(f[4])! < 0 { if p != nil { bad += 1; XCTFail("\(line): should refuse") }; continue }
            guard let p, let screens = r.composeLean(a: a, b: b, c: c) else { bad += 1; XCTFail("\(line): refused"); continue }
            let mask = p.dropped.reduce(0) { $0 | (bits[$1] ?? 0) }
            var ok = p.bytes.count == Int(f[4])! && Oracle.fnv1a(p.bytes) == UInt32(f[5])! && mask == Int(f[6])!
            for i in 0..<SentenceReader.leanScreens where screens[i].utf8.count != Int(f[7 + 2 * i])! || Oracle.fnv1a(screens[i].utf8) != UInt32(f[8 + 2 * i])! {
                ok = false
            }
            if !ok {
                bad += 1
                if bad <= 5 { XCTFail("\(line): got \(p.bytes.count) \(Oracle.fnv1a(p.bytes)) \(mask) / \(screens)") }
            }
        }
        XCTAssertEqual(bad, 0)
        return n
    }

    // MARK: A synthetic bundle

    struct Card {
        var name: String, kw: String, num: String, gaze: String, degree: Int, row: Int, symbols: String
        var closing: String
        var srole: String?
        var brief: String?
        init(_ i: Int, gaze: String = "left", degree: Int? = nil, row: Int? = nil, symbols: String = "") {
            name = "N\(i)"; kw = "k\(i)"; num = "#\(i)"; self.gaze = gaze
            self.degree = degree ?? (i == 0 ? 0 : i == 21 ? 21 : i <= 10 ? i : i - 10)
            self.row = row ?? (i == 0 ? 0 : i == 21 ? 3 : i <= 10 ? 1 : 2)
            self.symbols = symbols; closing = "Closing \(i)."
        }
        func lines(_ i: Int) -> [String] {
            var v: [(String, String)] = [("name", name), ("kw", kw), ("num", num), ("role", "role\(i)"), ("from", "from\(i)"), ("to", "to\(i)"),
                                         ("closing", closing), ("question", "Q\(i)?"), ("gaze", gaze), ("degree", "\(degree)"),
                                         ("row", "\(row)"), ("symbols", symbols)]
            if let srole { v.append(("srole", srole)) }
            if let brief { v.append(("brief", brief)) }
            return v.flatMap { ["[card.\(i).\($0.0)]", $0.1] }
        }
    }

    static let phrases: [(String, [String])] = [
        ("question", ["Never said {A.name}."]),
        ("couple.1-11", ["Couple {A.name}+{B.name}."]),
        ("meet.2-1", ["Meet back {A.name}>{B.name}."]),
        ("meet.4-6", ["Meet {A.name}>{B.name}."]),
        ("gaze.center.left", ["{B.name} addresses {A.name}, {A.role}."]),
        ("gaze.center.right", ["{B.name} addresses {C.name}, {C.role}."]),
        ("gaze.front", ["{B.name} looks at you."]),
        ("gaze.facing", ["{A.name} faces {B.name}."]),
        ("gaze.back", ["{A.name} turns from {B.name}."]),
        ("gaze.follow", ["{A.name} follows {B.name}."]),
        ("kin.sum21", ["{A.name}+{B.name}=21."]),
        ("kin.same", ["{A.name}~{B.name}."]),
        ("arc.rising", ["Rising ({A.num}, {B.num}, {C.num}): {A.kw}, {B.kw}, {C.kw}."]),
        ("arc.falling", ["Falling ({A.num}, {B.num}, {C.num}): {A.kw}, {B.kw}, {C.kw}."]),
        ("arc.peak", ["Peak ({A.num}, {B.num}, {C.num}): {A.kw}, {B.kw}, {C.kw}."]),
        ("arc.dip", ["Dip ({A.num}, {B.num}, {C.num}): {A.kw}, {B.kw}, {C.kw}."]),
        ("arc.plateau", ["Plateau ({A.num}, {B.num}, {C.num}): {A.kw}, {B.kw}, {C.kw}."]),
        ("arc.still", ["Still ({A.num}, {B.num}, {C.num}): {A.kw}, {B.kw}, {C.kw}."]),
        ("positions", ["Centre {B.name}; from {A.from} to {C.to}."]),
        ("echo", ["Echo: {tag}."]),
        ("depth", ["deep"]),
        ("tag.water", ["water"]),
        ("tag.crown", ["crown"]),
    ]

    func bundle(_ cards: [Card], phrases: [(String, [String])] = SentenceReaderTests.phrases, drop: Set<String> = []) -> SentenceReader {
        var lines: [String] = []
        for (s, vs) in phrases where !drop.contains(s) { lines.append("[\(s)]"); lines += vs }
        for (i, c) in cards.enumerated() { lines += c.lines(i) }
        return SentenceReader(text: lines.joined(separator: "\n") + "\n")
    }

    /// 22 cards, every one looking left unless set.
    func deck(_ gazes: [Int: String] = [:], symbols: [Int: String] = [:]) -> [Card] {
        (0..<22).map { Card($0, gaze: gazes[$0] ?? "left", symbols: symbols[$0] ?? "") }
    }

    // MARK: The rules

    func testNoQuestionCardAndTheCentreCardsClosing() {
        let r = bundle(deck())
        let p = r.compose(a: 3, b: 5, c: 7)!
        XCTAssertFalse(p.sections.contains("question"), "§5f.6: never a question sentence")
        XCTAssertFalse(p.text.contains("Never said"))
        XCTAssertEqual(p.sections.last, "closing")
        XCTAssertTrue(p.text.hasSuffix("Closing 5."), "B's closing: \(p.text)")
        // The engine refuses a question card, a missing card, a card past the table.
        XCTAssertNil(r.compose(q: 1, a: 3, b: 5, c: 7))
        XCTAssertNil(r.compose(a: 3, b: 5, c: -1))
        XCTAssertNil(r.compose(a: 3, b: 5, c: 22))
        XCTAssertNil(r.composeLean(a: 3, b: 5, c: 22))
        XCTAssertEqual(r.cards, 22)
    }

    func testVariantIsFNVOverTheRowAndTheSectionName() {
        // Seven variants: which one shows is fnv1a("-1,A,B,C,<section>") mod 7, decimal.
        let vs = (0..<7).map { "v\($0) {B.name}." }
        var ph = Self.phrases.filter { $0.0 != "positions" }
        ph.append(("positions", vs))
        let r = bundle(deck(), phrases: ph)
        let p = r.compose(a: 2, b: 11, c: 19)!
        let want = Int(Oracle.fnv1a(Array("-1,2,11,19,positions".utf8)) % 7)
        XCTAssertTrue(p.text.contains("v\(want) N11."), p.text)
        XCTAssertEqual(Oracle.fnv1a(Array("-1,2,11,19,arc.dip".utf8)), Oracle.fnv1a(Array("-1,2,11,19,".utf8) + Array("arc.dip".utf8)))
    }

    func testCoupleByOrderThenAny() {
        var ph = Self.phrases
        ph.append(("couple.1-11.any", ["Any {A.name}+{B.name}."]))
        let r = bundle(deck(), phrases: ph)
        let p = r.compose(a: 1, b: 11, c: 8)!
        XCTAssertEqual(p.sections.first, "couple.1-11")
        XCTAssertTrue(p.text.contains("Couple N1+N11."), p.text)
        // 11 before 1: no couple.11-1, so the unordered one, {A} = the lower index.
        let a = r.compose(a: 11, b: 1, c: 8)!
        XCTAssertEqual(a.sections.first, "couple.1-11.any")
        XCTAssertTrue(a.text.contains("Any N1+N11."), a.text)
        // Without .any, 11 before 1 makes no couple.
        XCTAssertFalse(bundle(deck()).compose(a: 11, b: 1, c: 8)!.sections.contains { $0.hasPrefix("couple.") })
    }

    func testEncounterFallsBackToTheOtherOrder() {
        let r = bundle(deck())
        let p = r.compose(a: 1, b: 2, c: 8)!
        XCTAssertTrue(p.sections.contains("meet.2-1"))
        XCTAssertTrue(p.text.contains("Meet back N2>N1."), p.text)
        let o = r.compose(a: 4, b: 8, c: 6)!
        XCTAssertTrue(o.text.contains("Meet N4>N6."), o.text)
        XCTAssertEqual(o.sections.filter { $0.hasPrefix("meet.") }, ["meet.4-6"])
    }

    func testCentreGazeCoversItsPair() {
        let r = bundle(deck([3: "right", 5: "left", 7: "right"]))
        let p = r.compose(a: 3, b: 5, c: 7)!
        XCTAssertEqual(p.sections, ["gaze.center.left", "gaze.back", "arc.rising", "positions", "closing"])
        XCTAssertTrue(p.text.contains("N5 addresses N3, role3. N5 turns from N7."), p.text)
        let u = bundle(deck([3: "right", 5: "left", 7: "right"]), drop: ["gaze.center.left"]).compose(a: 3, b: 5, c: 7)!
        XCTAssertEqual(u.sections, ["gaze.facing", "gaze.back", "arc.rising", "positions", "closing"])
        XCTAssertTrue(bundle(deck([5: "right"])).compose(a: 3, b: 5, c: 7)!.text.contains("N5 addresses N7, role7."))
        XCTAssertTrue(bundle(deck([5: "front"])).compose(a: 3, b: 5, c: 7)!.text.contains("N5 looks at you."))
    }

    func testFollowNamesTheFollowerAsA() {
        let r = bundle(deck([3: "left", 5: "left", 7: "front"]), drop: ["gaze.center.left", "gaze.center.right"])
        let p = r.compose(a: 3, b: 5, c: 7)!
        XCTAssertTrue(p.text.contains("N5 follows N3."), p.text)
        XCTAssertEqual(p.sections, ["arc.rising", "gaze.follow", "positions", "closing"])
        let q = bundle(deck([3: "right", 5: "right", 7: "front"]), drop: ["gaze.center.left", "gaze.center.right"]).compose(a: 3, b: 5, c: 7)!
        XCTAssertTrue(q.text.contains("N3 follows N5."), q.text)
    }

    func testKinshipSumBeforeSameDegree() {
        let r = bundle(deck([21: "front", 0: "front", 4: "front", 14: "front"]))
        // (A,C) = 0 + 21 = 21, (B,C)… : the sum first in the scan order (A,B), (B,C), (A,C).
        let p = r.compose(a: 0, b: 4, c: 21)!
        XCTAssertTrue(p.text.contains("N0+N21=21."), p.text)
        // Without a sum: same degree in both rows.
        XCTAssertTrue(r.compose(a: 2, b: 4, c: 14)!.text.contains("N4~N14."))
        // Second-row numbers are degree + 10: 3 + 18 = 21.
        XCTAssertTrue(r.compose(a: 3, b: 18, c: 6)!.text.contains("N3+N18=21."))
    }

    func testArcShapesAndDepth() {
        let r = bundle(deck(Dictionary(uniqueKeysWithValues: (0..<22).map { ($0, "front") })))
        func arc(_ a: Int, _ b: Int, _ c: Int) -> String { r.compose(a: a, b: b, c: c)!.sections.first { $0.hasPrefix("arc.") }! }
        XCTAssertEqual(arc(2, 5, 9), "arc.rising")
        XCTAssertEqual(arc(9, 5, 2), "arc.falling")
        XCTAssertEqual(arc(2, 9, 5), "arc.peak")
        XCTAssertEqual(arc(9, 2, 5), "arc.dip")
        XCTAssertEqual(arc(2, 12, 5), "arc.plateau")
        XCTAssertEqual(arc(3, 13, 21), "arc.plateau")
        XCTAssertEqual(arc(10, 21, 5), "arc.peak", "the World counts as 11")
        XCTAssertTrue(r.compose(a: 2, b: 15, c: 9)!.text.contains("Rising (#2, #15, #9): k2, k15 deep, k9."))
    }

    func testEchoTakesTheFirstTagWithAGloss() {
        let r = bundle(deck([:], symbols: [3: "crown", 5: "water,moon", 7: "crown,water"]))
        XCTAssertTrue(r.compose(a: 3, b: 5, c: 7)!.text.contains("Echo: water."))
        XCTAssertFalse(bundle(deck([:], symbols: [3: "moon", 5: "moon"])).compose(a: 3, b: 5, c: 7)!.sections.contains("echo"))
    }

    static let phrases3: [(String, [String])] = phrases + [
        ("couple.0-21", ["Couple {A.name}+{B.name}."]),
        ("couple.3-4", ["Couple {A.name}+{B.name}."]),
        ("qsum.two", ["QS {X.name}+{Y.name}."]),
        ("kin.sum21.3-18", ["KS {A.name}+{B.name}."]),
        ("succ.12-13", ["Succ {A.name}>{B.name}."]),
        ("step.up", ["Up {A.name}>{B.name}."]),
        ("step.down", ["Down {A.name}>{B.name}."]),
        ("step.restart", ["Restart {A.name}>{B.name}."]),
        ("place.wheel.first", ["WheelFirst {X.name}."]), ("place.wheel.later", ["WheelLater {X.name}."]),
        ("place.world.first", ["WorldFirst {X.name}."]), ("place.world.last", ["WorldLast {X.name}."]),
        ("place.fool.before", ["FoolBefore {X.name}."]), ("place.fool.after", ["FoolAfter {X.name}."]),
        ("hsum", ["Hidden {S.name}."]), ("hsum.drawn", ["HiddenDrawn {S.name}."]),
        ("row.open.left", ["OpenLeft."]), ("row.open.right", ["OpenRight."]), ("row.closed", ["Closed."]),
    ]

    func compose3(_ a: Int, _ b: Int, _ c: Int, gazes: [Int: String] = [:]) -> SentenceReader.Paragraph {
        bundle(deck(gazes), phrases: Self.phrases3).compose(a: a, b: b, c: c)!
    }

    func testNoQuestionSumAndTheHiddenSum() {
        XCTAssertEqual(SentenceReader.reduce22(23), 5)
        XCTAssertEqual(SentenceReader.reduce22(22), 22)
        XCTAssertEqual(SentenceReader.reduce22(59), 14)
        XCTAssertFalse(compose3(4, 5, 9).sections.contains { $0.hasPrefix("qsum") }, "§5f.6: no question sum")
        // 3 + 5 + 9 = 17; 10 + 5 + 7 = 22 → Le Mat (the Wheel's placement aside).
        XCTAssertTrue(compose3(3, 5, 9).text.contains("Hidden N17."))
        XCTAssertTrue(compose3(10, 5, 7).text.contains("Hidden N0."))
        // The sum lands on a drawn card: hsum.drawn.
        let rows = (0..<22).flatMap { a in (0..<22).flatMap { b in (0..<22).map { c in (a, b, c) } } }.filter { Set([$0.0, $0.1, $0.2]).count == 3 }
        let drawn = rows.first { r in
            let s = SentenceReader.reduce22([r.0, r.1, r.2].map { $0 == 0 ? 22 : $0 }.reduce(0, +)) % 22
            return [r.0, r.1, r.2].contains(s)
        }!
        XCTAssertTrue(compose3(drawn.0, drawn.1, drawn.2).sections.contains("hsum.drawn"), "\(drawn)")
    }

    func testSpecificKinshipAndTheCouplesPair() {
        let p = compose3(18, 6, 3)
        XCTAssertTrue(p.text.contains("KS N3+N18."), p.text)
        let c = compose3(0, 21, 5)
        XCTAssertTrue(c.sections.contains("couple.0-21"), "\(c.sections)")
        XCTAssertFalse(c.sections.contains { $0.hasPrefix("kin.") })
        XCTAssertFalse(c.sections.contains { $0.hasPrefix("place.fool") })
    }

    func testSuccessionAndDegreeSteps() {
        let p = compose3(12, 13, 4)
        XCTAssertTrue(p.text.contains("Succ N12>N13."), p.text)
        XCTAssertTrue(p.text.contains("Up N13>N4."), p.text)
        XCTAssertEqual(p.sections.filter { $0.hasPrefix("step.") }, ["step.up"])
        XCTAssertTrue(compose3(10, 1, 7).text.contains("Restart N10>N1."))
        XCTAssertTrue(compose3(6, 5, 17).text.contains("Down N6>N5."))
        let c = compose3(3, 4, 15)
        XCTAssertTrue(c.text.contains("Couple N3+N4."))
        XCTAssertTrue(c.text.contains("Up N4>N15."))
        XCTAssertFalse(compose3(20, 21, 5).sections.contains { $0.hasPrefix("step.") })
    }

    func testPlacement() {
        XCTAssertTrue(compose3(10, 3, 5).text.contains("WheelFirst N10."))
        XCTAssertTrue(compose3(3, 5, 10).text.contains("WheelLater N10."))
        XCTAssertTrue(compose3(21, 3, 5).text.contains("WorldFirst N21."))
        XCTAssertTrue(compose3(3, 5, 21).text.contains("WorldLast N21."))
        XCTAssertTrue(compose3(0, 3, 5).text.contains("FoolBefore N3."))
        XCTAssertTrue(compose3(3, 0, 5).text.contains("FoolBefore N5."))
        XCTAssertTrue(compose3(3, 5, 0).text.contains("FoolAfter N5."))
        XCTAssertTrue(compose3(0, 10, 21).text.contains("WheelLater N10."))
    }

    func testOpenOrClosedRow() {
        XCTAssertTrue(compose3(3, 5, 7, gazes: [3: "left", 7: "right"]).text.contains("OpenLeft."), "both open: left wins")
        XCTAssertTrue(compose3(3, 5, 7, gazes: [3: "right", 7: "right"]).text.contains("OpenRight."))
        XCTAssertTrue(compose3(3, 5, 7, gazes: [3: "right", 7: "left"]).text.contains("Closed."))
        XCTAssertFalse(compose3(3, 5, 7, gazes: [3: "front", 7: "front"]).sections.contains { $0.hasPrefix("row.") })
    }

    func testBudgetDropsTheWeakestFirstAndTheNumeralsBeforeTheArc() {
        func padded(_ extra: Int) -> SentenceReader {
            var ph = Self.phrases.filter { $0.0 != "positions" }
            // each line stays under the 512-byte line limit
            ph.append(("positions", ["Centre {B.name}" + String(repeating: " pad", count: 80 + extra) + "."]))
            var cards = deck([3: "left", 5: "left", 7: "front"], symbols: [3: "water", 5: "water"])
            cards[5].closing = "Closing" + String(repeating: " end", count: 100) + "."
            return bundle(cards, phrases: ph, drop: ["gaze.center.left", "gaze.center.right"])
        }
        func compose(_ extra: Int) -> SentenceReader.Paragraph { padded(extra).compose(a: 3, b: 5, c: 7)! }
        let full = compose(0)
        XCTAssertEqual(full.sections, ["arc.rising", "gaze.follow", "echo", "positions", "closing"])
        XCTAssertEqual(full.dropped, [])
        let len = full.bytes.count, max = SentenceReader.textMax
        XCTAssertLessThan(len, max)
        let followEcho = "N5 follows N3. Echo: water. ".utf8.count, numerals = " (#3, #5, #7)".utf8.count
        let p1 = compose((max - len) / 4 + 1)
        XCTAssertEqual(p1.dropped, ["echo"])
        let p2 = compose((max - len + followEcho) / 4 + 1)
        XCTAssertEqual(p2.dropped, ["follow", "echo", "numerals"])
        XCTAssertTrue(p2.text.hasPrefix("Rising: k3, k5, k7. Centre"), p2.text)
        let p3 = compose((max - len + followEcho + numerals) / 4 + 2)
        XCTAssertEqual(p3.dropped, ["arc", "follow", "echo", "numerals"])
        XCTAssertEqual(p3.sections, ["positions", "closing"])
        for p in [p1, p2, p3] { XCTAssertLessThanOrEqual(p.bytes.count, max) }
    }

    func testTooLongEvenWithoutFindingsIsCutBeforeASpace() {
        var cards = deck()
        cards[5].closing = String(repeating: "word ", count: 95) + "end."
        let ph: [(String, [String])] = [("positions", ["P {B.name}" + String(repeating: " pos", count: 120)])]
        let p = bundle(cards, phrases: ph).compose(a: 3, b: 5, c: 7)!
        XCTAssertEqual(p.dropped, ["cut"])
        XCTAssertEqual(p.sections, ["positions", "closing"])
        let joined = Array(("P N5" + String(repeating: " pos", count: 120) + " " + cards[5].closing).utf8)
        let space = (1...(SentenceReader.textMax - 3)).reversed().first { joined[$0] == 0x20 }!
        XCTAssertEqual(p.bytes, Array(joined[0..<space]) + Array("…".utf8))
        XCTAssertEqual(SentenceReader.cutSentence(Array(String(repeating: "é", count: 600).utf8)).count, 960)
        XCTAssertEqual(SentenceReader.cutSentence(Array(("a" + String(repeating: "é", count: 600)).utf8)).count, 959)
    }

    func testStripNumeralsLikeTheRegex() {
        func s(_ x: String) -> String { String(decoding: SentenceReader.stripNumerals(Array(x.utf8)), as: UTF8.self) }
        XCTAssertEqual(s("Rising (I, II, III): a, b."), "Rising: a, b.")
        XCTAssertEqual(s("(I) start and (II)end"), " start andend")
        XCTAssertEqual(s("open ( never closed"), "open ( never closed")
        XCTAssertEqual(s("x  (a)"), "x ")
    }

    func testParsingRules() {
        let long = String(repeating: "x", count: 513)
        let text = [
            "before any header: ignored",
            "[positions]\r",
            "first {B.name}\r",
            "bad {Z.kw}",
            "unclosed {B.name",
            long,
            "ctl \u{1}byte",
            "[positions]",
            "second {B.name} \t tab ok {B.srole}",
            "[card.0.name]", "Zero", "Second line ignored",
            "[card.078.name]", "never",
            "[card.1.colour]", "never",
            "[tag.unicorn]", "never",
            "[card.2.closing]", "Bye.",
            "[card.1.name]", "One", "[card.2.name]", "Two", "[card.2.role]", "role two", "[card.3.name]", "Three",
        ].joined(separator: "\n")
        var bytes = Array(text.utf8)
        bytes += Array("\n[card.0.kw]\n".utf8) + [0xC3, 0x28] + Array("\n".utf8)
        let r = SentenceReader(bytes: bytes)
        XCTAssertEqual(r.cards, 4)
        XCTAssertEqual(r.field(0, .name), "Zero")
        XCTAssertNil(r.field(0, .kw))
        let p = r.compose(a: 1, b: 2, c: 3)!
        let want = Int(Oracle.fnv1a(Array("-1,1,2,3,positions".utf8)) % 2)
        XCTAssertEqual(p.text, (want == 0 ? "first Two" : "second Two \t tab ok role two") + " Bye.", "{B.srole} falls back to the role")
        XCTAssertEqual(p.sections, ["positions", "closing"])
    }

    // MARK: The lean draw (§5f.7)

    static let leanPhrases: [(String, [String])] = phrases + [
        ("couple.3-4", ["Couple {A.name}+{B.name}."]),
        ("short.card", ["{X.num} {X.name}: {X.srole}.", "{X.name} ({X.num}), {X.srole}."]),
        ("short.positions", ["From {A.from}, {B.name} {B.srole}, to {C.to}."]),
    ]

    func testLeanFiveScreens() throws {
        // A 3-4 couple first, then B (4) addresses A (centre gaze, A on its left).
        var cards = deck([3: "front", 4: "left", 9: "front"])
        cards[4].srole = "short four"
        let r = bundle(cards, phrases: Self.leanPhrases)
        let s = try XCTUnwrap(r.composeLean(a: 3, b: 4, c: 9))
        XCTAssertEqual(s.count, SentenceReader.leanScreens)
        // 0: one variant for the row, hashed once as "-1,A,B,C,short.card", applied to each card ({X.srole}, else the role).
        let v = Int(Oracle.fnv1a(Array("-1,3,4,9,short.card".utf8)) % 2)
        let lines = v == 0 ? ["#3 N3: role3.", "#4 N4: short four.", "#9 N9: role9."] : ["N3 (#3), role3.", "N4 (#4), short four.", "N9 (#9), role9."]
        XCTAssertEqual(s[0], lines.joined(separator: " "))
        // 1: by position.
        XCTAssertEqual(s[1], "From from3, N4 short four, to to9.")
        // 2: by the numbers: the arc with its numerals.
        XCTAssertEqual(s[2], "Rising (#3, #4, #9): k3, k4, k9.")
        // 3: together: the strongest finding; 4: and: the second + B's closing.
        XCTAssertEqual(s[3], "Couple N3+N4.")
        XCTAssertEqual(s[4], "N4 addresses N3, role3. Closing 4.")
        // The same texts as the paragraph's sentences.
        let p = try XCTUnwrap(r.compose(a: 3, b: 4, c: 9)).text
        for t in s[2...4] { XCTAssertTrue(p.contains(t.replacingOccurrences(of: " Closing 4.", with: "")), t) }
        // A bundle without [short.card] / [short.positions]: those screens are empty, the rest stays.
        let bare = try XCTUnwrap(bundle(cards).composeLean(a: 3, b: 4, c: 9))
        XCTAssertEqual(Array(bare[0...1]), ["", ""])
        XCTAssertEqual(bare[2], s[2])
    }

    func testLeanTogetherSkipsThinFindings() throws {
        // Only a gaze.front (B looks out) and the arc: no "together", the "and" is B's closing alone.
        let r = bundle(deck([3: "front", 5: "front", 7: "front"]), phrases: Self.leanPhrases)
        XCTAssertTrue(r.compose(a: 3, b: 5, c: 7)!.sections.contains("gaze.front"))
        let s = try XCTUnwrap(r.composeLean(a: 3, b: 5, c: 7))
        XCTAssertEqual(s[2], "Rising (#3, #5, #7): k3, k5, k7.")
        XCTAssertEqual(s[3], "", "never gaze.front nor the arc")
        XCTAssertEqual(s[4], "Closing 5.", "no second finding: the closing alone")
        // follow and echo are skipped too.
        let f = bundle(deck([3: "left", 5: "left", 7: "front"], symbols: [3: "water", 5: "water"]), phrases: Self.leanPhrases,
                       drop: ["gaze.center.left", "gaze.center.right"])
        let fs = try XCTUnwrap(f.composeLean(a: 3, b: 5, c: 7))
        XCTAssertTrue(f.compose(a: 3, b: 5, c: 7)!.sections.contains("gaze.follow"))
        XCTAssertEqual(fs[3], "")
        XCTAssertEqual(fs[4], "Closing 5.")
    }

    func testLeanAndScreenFitsOnePage() throws {
        var cards = deck([3: "front", 4: "left", 9: "front"])
        // 150 code points at most: "N4 addresses N3, role3." (23) + " " + the closing.
        cards[4].closing = "C" + String(repeating: "é", count: 125) + "."   // 23 + 1 + 127 = 151: too long together
        let r = bundle(cards, phrases: Self.leanPhrases)
        XCTAssertEqual(try XCTUnwrap(r.composeLean(a: 3, b: 4, c: 9))[4], "N4 addresses N3, role3.", "the finding alone")
        cards[4].closing = "C" + String(repeating: "é", count: 124) + "."   // 150: fits
        XCTAssertEqual(try XCTUnwrap(bundle(cards, phrases: Self.leanPhrases).composeLean(a: 3, b: 4, c: 9))[4],
                       "N4 addresses N3, role3. " + cards[4].closing)
        // The caller's page test decides (the clip's body font); the finding too long alone: the closing alone.
        let s = try XCTUnwrap(r.composeLean(a: 3, b: 4, c: 9, fits: { $0.count <= 10 }))
        XCTAssertEqual(s[4], "C" + String(repeating: "é", count: 125) + ".")
        XCTAssertEqual(try XCTUnwrap(r.composeLean(a: 3, b: 4, c: 9, fits: { _ in true }))[4],
                       "N4 addresses N3, role3. C" + String(repeating: "é", count: 125) + ".")
        // The other screens never depend on the page test.
        XCTAssertEqual(Array(try XCTUnwrap(r.composeLean(a: 3, b: 4, c: 9, fits: { _ in false }))[0...3]),
                       Array(try XCTUnwrap(r.composeLean(a: 3, b: 4, c: 9))[0...3]))
        XCTAssertTrue(SentenceReader.fitsDefault(Array((String(repeating: "é", count: 150)).utf8)))
        XCTAssertFalse(SentenceReader.fitsDefault(Array((String(repeating: "é", count: 151)).utf8)))
    }

    func testBriefIsACardField() {
        var cards = deck()
        cards[7].brief = "VII The Chariot — degree seven: he drives on. Where to?"
        let r = bundle(cards)
        XCTAssertEqual(r.field(7, .brief), cards[7].brief)
        XCTAssertNil(r.field(6, .brief))
    }

    // MARK: The bundles the app carries

    func testBundledReadersParse() throws {
        for lang in ["fr", "en"] {
            let url = Paths.iosDir.appendingPathComponent("Sources/Resources/Tarot/reader-\(lang).txt")
            let r = SentenceReader(bundle: try Data(contentsOf: url))
            XCTAssertEqual(r.cards, 22, lang)
            let p = try XCTUnwrap(r.compose(a: 6, b: 8, c: 10))
            XCTAssertLessThanOrEqual(p.bytes.count, SentenceReader.textMax)
            let s = try XCTUnwrap(r.composeLean(a: 6, b: 8, c: 10))
            XCTAssertEqual(s.count, SentenceReader.leanScreens)
            XCTAssertTrue(s.allSatisfy { !$0.isEmpty }, lang)
            XCTAssertNotNil(r.text("prompt"))
            XCTAssertNotNil(r.text("prompt.armed"), "§5f.8 \(lang)")
            for c in 0..<22 {
                XCTAssertNotNil(r.field(c, .srole), "\(lang) card \(c) srole")
                let brief = try XCTUnwrap(r.field(c, .brief), "\(lang) card \(c) brief")
                XCTAssertLessThanOrEqual(brief.count, 140, "\(lang) card \(c) brief")
            }
        }
    }

    func testRewritingWithoutEditsIsTheSameFile() throws {
        for lang in TarotLanguage.allCases {
            let text = try String(contentsOf: Paths.iosDir.appendingPathComponent("Sources/Resources/Tarot/reader-\(lang.rawValue).txt"), encoding: .utf8)
            XCTAssertEqual(ReaderBundle.applying(edits: .none, language: lang, to: text), text)
            let r = SentenceReader(text: text)
            XCTAssertEqual(ReaderBundle.rewriting(text, overrides: [3: [.kw: r.field(3, .kw)!]]), text, "byte for byte, srole, brief and all")
            XCTAssertTrue(ReaderBundle.textID(language: lang, data: Data(text.utf8)).count <= 32)
            XCTAssertTrue(ReaderBundle.textID(language: lang, data: Data(text.utf8)).hasPrefix("tarot-reader-\(lang.rawValue)-"))
        }
    }

    func testRewritingAppliesTheEdits() throws {
        let text = try String(contentsOf: Paths.iosDir.appendingPathComponent("Sources/Resources/Tarot/reader-fr.txt"), encoding: .utf8)
        var edits = TarotEdits()
        edits[17, .fr] = TarotCardEdit(keyword: "Partage", reading: "an edited reading", question: "Que donnes-tu ?\nVraiment ?", closing: "Donne.")
        edits[17, .en] = TarotCardEdit(keyword: "English only")
        let out = ReaderBundle.applying(edits: edits, language: .fr, to: text)
        XCTAssertNotEqual(out, text)
        let r = SentenceReader(text: out), orig = SentenceReader(text: text)
        XCTAssertEqual(r.field(17, .kw), "Partage")
        XCTAssertEqual(r.field(17, .question), "Que donnes-tu ? Vraiment ?")
        XCTAssertEqual(r.field(17, .closing), "Donne.")
        XCTAssertEqual(r.field(17, .reading), "an edited reading")
        XCTAssertEqual(r.field(17, .role), orig.field(17, .role))
        XCTAssertEqual(r.field(17, .srole), orig.field(17, .srole))
        XCTAssertTrue(out.contains("[card.13.printed]\n[card.13.srole]"), "XIII keeps its empty printed name")
        var named = TarotEdits()
        named[17, .fr] = TarotCardEdit(name: "L'ÉTOILE")
        XCTAssertEqual(SentenceReader(text: ReaderBundle.applying(edits: named, language: .fr, to: text)).field(17, .printed), "L'ÉTOILE")
        XCTAssertEqual(orig.field(17, .printed), "LE TOILLE")
        XCTAssertNil(orig.field(13, .printed))
        for i in 0..<22 where i != 17 {
            for f in SentenceReader.Field.allCases { XCTAssertEqual(r.field(i, f), orig.field(i, f)) }
        }
        // The same phrases: a row without card 17 reads exactly as before; with 17 in the centre, the edited closing.
        XCTAssertEqual(r.compose(a: 6, b: 8, c: 10)?.bytes, orig.compose(a: 6, b: 8, c: 10)?.bytes)
        XCTAssertEqual(r.compose(a: 6, b: 17, c: 10)?.text.hasSuffix("Donne."), true)
        XCTAssertNotEqual(ReaderBundle.textID(language: .fr, data: Data(out.utf8)), ReaderBundle.textID(language: .fr, data: Data(text.utf8)))
    }
}
