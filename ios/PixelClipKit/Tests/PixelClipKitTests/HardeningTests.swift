import Foundation
import XCTest
@testable import PixelClipKit

// Regression tests for the security audit of the first public release: hostile pages, books, links,
// clip answers and shared items must cost a bounded amount of time and memory, and never twice.
// The time bounds are loose (these run in Debug, on any Mac and in the simulator): before the fixes the
// same inputs took 8 to 70 seconds in a Release build, or overflowed the stack.

private func seconds(_ body: () throws -> Void) rethrows -> Double {
    let t = Date()
    try body()
    return Date().timeIntervalSince(t)
}

/// Blocks the thread: work that can't be cancelled.
private func stall(_ s: Double) { Thread.sleep(forTimeInterval: s) }

// MARK: - HTML (IOS-4)

final class HTMLHardeningTests: XCTestCase {
    static let sentence = "hello world this is a paragraph of text, with commas, and more."

    /// 100,000 nested tags on a 512 KB stack (a background thread on iOS): 1,500 used to overflow it.
    func testDeepNestingOnSmallStack() {
        let html = String(repeating: "<div>", count: 100_000) + Self.sentence
        let done = expectation(description: "parsed")
        nonisolated(unsafe) var text = ""
        nonisolated(unsafe) var took = 0.0
        let thread = Thread {
            took = seconds { text = HTMLText.article(html).text }
            done.fulfill()
        }
        thread.stackSize = 512 << 10
        thread.start()
        wait(for: [done], timeout: 60)
        XCTAssertEqual(text, Self.sentence)
        XCTAssertLessThan(took, 5)
    }

    func testNestingIsCappedAndClosesCleanly() {
        let depth = HTMLText.Limits.maxDepth * 3
        let html = "<body>" + String(repeating: "<div>", count: depth) + "<p>inside</p>" + String(repeating: "</div>", count: depth) + "<p>after</p></body>"
        let doc = HTMLText.parse(html)
        var deepest = 0
        var stack: [(HTMLText.Node, Int)] = [(doc, 0)]
        while let (n, d) = stack.popLast() {
            deepest = max(deepest, d)
            for c in n.children { stack.append((c, d + 1)) }
        }
        XCTAssertLessThanOrEqual(deepest, HTMLText.Limits.maxDepth + 2)
        XCTAssertEqual(HTMLText.text(html), "inside\n\nafter", "the text of the too-deep part is kept, and what follows it")
    }

    /// 4,000 open `<b>` then 400,000 stray `</p>` (1.5 MB): 70.9 s before.
    func testStrayEndTagsAreLinear() {
        let html = String(repeating: "<b>", count: 4_000) + String(repeating: "</p>", count: 400_000) + "tail"
        var doc: HTMLText.Node?
        let took = seconds { doc = HTMLText.parse(html) }
        XCTAssertLessThan(took, 5)
        XCTAssertEqual(doc?.innerText, "tail")
    }

    /// End tags and implied end tags with nothing to close, at full depth: each used to scan the open stack.
    func testUnmatchedTagsAtFullDepthAreLinear() {
        let open = String(repeating: "<b>", count: HTMLText.Limits.maxDepth)
        for tag in ["</a>", "<li>", "<td>", "<tr>", "<dd>"] {
            let html = open + String(repeating: tag, count: 150_000)
            XCTAssertLessThan(seconds { _ = HTMLText.parse(html) }, 5, tag)
        }
    }

    /// 40,000 unlikely siblings under one parent (234 KB): 8.2 s before.
    func testRemovingManySiblingsIsLinear() {
        let html = "<body>" + String(repeating: "<nav/>", count: 40_000) + "<p>" + Self.sentence + "</p></body>"
        var a: HTMLText.Article?
        let took = seconds { a = HTMLText.article(html) }
        XCTAssertLessThan(took, 3)
        XCTAssertEqual(a?.text, Self.sentence)
    }

    /// 2,000 nested candidates (128 KB): 9.8 s before (every level re-read its whole subtree).
    func testNestedCandidatesAreLinear() {
        var html = "<body>"
        for _ in 0..<2_000 { html += "<div><p>some paragraph text that is long enough, with a comma.</p>" }
        html += "</body>"
        var a: HTMLText.Article?
        let took = seconds { a = HTMLText.article(html) }
        XCTAssertLessThan(took, 3)
        XCTAssertTrue(a?.text.hasPrefix("some paragraph text that is long enough, with a comma.") == true)
    }

    /// What Safari's preprocessor lets through: 4,000,000 characters of siblings.
    func testFourMegabytesOfSiblings() {
        let html = "<body>" + String(repeating: "<nav/>", count: 4_000_000 / 6) + "</body>"
        XCTAssertLessThan(seconds { _ = HTMLText.article(html) }, 20)
    }

    func testNodeAndInputLimits() {
        // More nodes than the limit: parsing stops there, quietly.
        let many = String(repeating: "<i>x</i>", count: HTMLText.Limits.maxNodes)
        XCTAssertLessThanOrEqual(HTMLText.parse(many).elements().count, HTMLText.Limits.maxNodes)
        // More bytes than the limit: the rest isn't read.
        let filler = String(repeating: "a", count: HTMLText.Limits.maxInputBytes)
        XCTAssertFalse(HTMLText.text("<p>start</p><p>" + filler + "</p><p>the end</p>").contains("the end"))
        XCTAssertTrue(HTMLText.text("<p>start</p><p>the end</p>").contains("the end"))
    }

    /// The one-pass statistics are what the scoring used to compute per candidate from the text itself.
    func testMeasuredLengthsMatchTheText() throws {
        let page = try String(contentsOf: Paths.fixturesDir.appendingPathComponent("reader/article-fr.html"), encoding: .utf8)
        let more = "<div><p>Un, deux,  trois、quatre，cinq <a href=x>lien <b>gras</b></a> et <a href=y>un <a href=z>autre</a></a>.</p><br><pre> a\n b </pre></div>"
        for html in [page, more, "", "<p></p>", "texte nu"] {
            let doc = HTMLText.parse(html)
            HTMLText.measure(doc)
            for n in [doc] + doc.elements() {
                let text = n.innerText
                XCTAssertEqual(n.textLength, text.count, n.name)
                XCTAssertEqual(n.commas, text.filter { $0 == "," || $0 == "，" || $0 == "、" }.count, n.name)
                let links = n.elements().filter { $0.name == "a" }.reduce(0) { $0 + $1.innerText.count }
                XCTAssertEqual(n.linkLength, links, n.name)
            }
        }
    }
}

// MARK: - Markdown (IOS-7)

final class MarkdownInlineTests: XCTestCase {
    /// The inline rules as they were: twelve regular expressions, in order. Quadratic on lines of
    /// unclosed marks, so only used here, on short lines, to say what the result must be.
    static func regexInline(_ s: String) -> String {
        var t = s
        let rules: [(String, String)] = [
            (#"!\[[^\]]*\]\([^)]*\)"#, ""),                         // images
            (#"\[\^[^\]]+\]"#, ""),                                  // footnote refs
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),                       // links
            (#"\[([^\]]+)\]\[[^\]]*\]"#, "$1"),                      // reference links
            (#"<(https?://[^>]+)>"#, "$1"),                          // autolinks
            (#"<[^>]+>"#, ""),                                       // inline HTML
            (#"`([^`]+)`"#, "$1"),                                   // code
            (#"(\*\*|__)(.+?)\1"#, "$2"),                            // bold
            (#"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, "$1"),   // *em*
            (#"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)"#, "$1"),           // _em_
            (#"~~(.+?)~~"#, "$1"),                                   // strike
            (#"\\([\\`*_{}\[\]()#+\-.!>|~])"#, "$1"),                // escapes
        ]
        for (p, r) in rules { t = t.replacingOccurrences(of: p, with: r, options: .regularExpression) }
        return HTMLText.decodeEntities(t)
    }

    func testOrdinaryLines() {
        let cases = [
            "Un **très** bon [lien](https://example.com/a) et du `code`, _voilà_.": "Un très bon lien et du code, voilà.",
            "![alt](img.png) texte[^1] <span class=\"x\">dedans</span> <https://example.com>": " texte dedans https://example.com",
            "a*b*c 2 * 3 * 4 snake_case_name __gras__ ~~barré~~ 1 \\+ 1 \\# [ref][1]": "a*b*c 2 * 3 * 4 snake_case_name gras barré 1 + 1 # ref",
            "*tout un passage en italique, assez long pour tenir sur la ligne*": "tout un passage en italique, assez long pour tenir sur la ligne",
            "AT&amp;T &eacute;t&eacute;": "AT&T été",
        ]
        for (md, want) in cases {
            XCTAssertEqual(TextImporter.inline(md), want)
            XCTAssertEqual(Self.regexInline(md), want, "the reference agrees")
        }
    }

    /// Random lines dense in marks: the scanners give exactly what the expressions gave.
    func testMatchesTheRegularExpressionsOnRandomLines() {
        let alphabet: [String] = ["*", "*", "_", "_", "[", "]", "(", ")", "<", ">", "`", "~", "~", "\\", "!", "^", " ", " ", "a", "b", "é", "1",
                                  ".", "\t", "\u{0B}", "\u{0C}", "\u{85}", "\u{A0}", "\u{2028}", "h", "t", "t", "p", "s", ":", "/", "/", "&", "#",
                                  ";", "\u{301}", "😀", "\u{200D}", "-"]
        var rng = SeededRNG(0x5EC0_2026)
        var checked = 0
        for round in 0..<40_000 {
            let n = Int.random(in: 0...(round % 50 == 0 ? 120 : 24), using: &rng)
            var line = ""
            for _ in 0..<n { line += alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] }
            if round % 7 == 0 { line = "<https://" + line }
            let got = TextImporter.inline(line), want = Self.regexInline(line)
            if got != want {
                XCTFail("inline(\(line.debugDescription)) = \(got.debugDescription), the expressions gave \(want.debugDescription)")
                return
            }
            checked += 1
        }
        XCTAssertEqual(checked, 40_000)
    }

    func testClosingHashesMatchTheRegularExpression() {
        let alphabet = ["#", "#", " ", " ", "\t", "a", "\u{0B}", "\u{85}", "\u{2028}", "\u{A0}", "é"]
        var rng = SeededRNG(0xC105E)
        for _ in 0..<40_000 {
            let n = Int.random(in: 0...14, using: &rng)
            var s = ""
            for _ in 0..<n { s += alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] }
            let want = s.replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
            XCTAssertEqual(TextImporter.withoutClosingHashes(s), want, s.debugDescription)
        }
        XCTAssertEqual(TextImporter.withoutClosingHashes("Deuxième partie ##"), "Deuxième partie")
        XCTAssertEqual(TextImporter.withoutClosingHashes("C# et F#"), "C# et F#")
    }

    /// One 24 KB line of `*a ` took 12.1 s; `[a` 2.3 s.
    func testUnclosedMarksAreLinear() {
        for piece in ["*a ", "_a ", "[a", "**a", "![a", "<a", "`", "~~a", "[^a", "<https://a"] {
            let line = String(repeating: piece, count: 8_000)
            XCTAssertLessThan(seconds { _ = TextImporter.markdown(line) }, 1, piece)
        }
        // A megabyte of it, as one line and as many.
        let big = String(repeating: "*a _b [c **d ", count: 80_000)
        XCTAssertLessThan(seconds { _ = TextImporter.markdown(big) }, 10)
        XCTAssertLessThan(seconds { _ = TextImporter.markdown(big.replacingOccurrences(of: "**d ", with: "**d\n")) }, 10)
        // A heading of spaces (the closing-hashes rule rescanned each run of blanks).
        let heading = "# a" + String(repeating: " ", count: 50_000) + "b # #"
        XCTAssertLessThan(seconds { _ = TextImporter.markdown(heading) }, 2)
    }

    func testLongMarkdownStopsAtTwiceTheClipLimit() {
        let para = String(repeating: "mot ", count: 250) + "\n\n"
        let md = String(repeating: para, count: 6_000)   // 6 MB
        let t = TextImporter.markdown(md)
        XCTAssertGreaterThan(t.body.utf8.count, ReaderLimits.maxTextBytes)
        XCTAssertLessThan(t.body.utf8.count, 3 * ReaderLimits.maxTextBytes)
        XCTAssertTrue(ReaderDocument.make(t).0.truncated)
    }
}

// MARK: - ZIP and EPUB (IOS-6)

final class ZipHardeningTests: XCTestCase {
    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    static func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }

    /// An archive of deflated entries; `declared` is the uncompressed size written in the headers (nil: the true one).
    static func zip(_ files: [(name: String, payload: Data, declared: Int?)]) -> Data {
        var out = Data()
        var directory: [UInt8] = []
        for f in files {
            let comp = f.payload.isEmpty ? Data() : try! (f.payload as NSData).compressed(using: .zlib) as Data
            let n = Array(f.name.utf8), size = f.declared ?? f.payload.count, offset = out.count
            var local: [UInt8] = [0x50, 0x4B, 0x03, 0x04] + le16(20) + le16(0) + le16(8) + le16(0) + le16(0)
            local += le32(0) + le32(comp.count) + le32(size) + le16(n.count) + le16(0) + n
            out.append(contentsOf: local)
            out.append(comp)
            directory += [0x50, 0x4B, 0x01, 0x02] + le16(20) + le16(20) + le16(0) + le16(8) + le16(0) + le16(0)
            directory += le32(0) + le32(comp.count) + le32(size) + le16(n.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + n
        }
        let cdOffset = out.count
        out.append(contentsOf: directory)
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06] + le16(0) + le16(0) + le16(files.count) + le16(files.count)
                   + le32(directory.count) + le32(cdOffset) + le16(0))
        return out
    }

    /// A 298 KB archive whose entry says "10 bytes" and holds 300 MB: it used to come back whole.
    func testDeclaredSizeIsEnforced() throws {
        let archive = Self.zip([("bomb.xhtml", Data(count: 300 << 20), 10)])
        XCTAssertLessThan(archive.count, 400 << 10)
        let z = try ZipArchive(data: archive)
        XCTAssertThrowsError(try z.read("bomb.xhtml")) { XCTAssertEqual($0 as? ZipArchive.ZipError, .tooLarge) }
        // Declaring the real size doesn't help: it is over the entry limit.
        let honest = try ZipArchive(data: Self.zip([("bomb.xhtml", Data(count: ZipArchive.maxEntryBytes + 1), nil)]))
        XCTAssertThrowsError(try honest.read("bomb.xhtml")) { XCTAssertEqual($0 as? ZipArchive.ZipError, .tooLarge) }
    }

    func testEntriesInflateToExactlyTheirDeclaredSize() throws {
        let text = Data(String(repeating: "Il était une fois. ", count: 20_000).utf8)   // several 64 KB pieces
        XCTAssertEqual(try ZipArchive(data: Self.zip([("a.txt", text, nil)])).read("a.txt"), text)
        XCTAssertEqual(try ZipArchive(data: Self.zip([("empty", Data(), nil)])).read("empty"), Data())
        let short = try ZipArchive(data: Self.zip([("a.txt", text, text.count + 1)]))
        XCTAssertThrowsError(try short.read("a.txt")) { XCTAssertEqual($0 as? ZipArchive.ZipError, .corrupt) }
        let long = try ZipArchive(data: Self.zip([("a.txt", text, text.count - 1)]))
        XCTAssertThrowsError(try long.read("a.txt")) { XCTAssertEqual($0 as? ZipArchive.ZipError, .tooLarge) }
    }

    func testMutatedArchivesDoNotTrap() {
        let base = Self.zip([("META-INF/container.xml", Data("<a/>".utf8), nil)])
        var rng = SeededRNG(0x21B)
        for _ in 0..<20_000 {
            var b = [UInt8](base)
            for _ in 0..<Int.random(in: 1...6, using: &rng) { b[Int.random(in: 0..<b.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            if Bool.random(using: &rng) { b.removeLast(Int.random(in: 0..<min(30, b.count), using: &rng)) }
            if let z = try? ZipArchive(data: Data(b)) {
                for e in z.entries { _ = try? z.read(e) }
                _ = try? TextImporter.epub(Data(b))
            }
        }
    }

    /// A book of chapters that each inflate to megabytes of blanks: reading stops, in bounded time.
    func testBookOfBombsIsBounded() throws {
        let chapter = Data(("<html><body><p>mot</p>" + String(repeating: " ", count: 20 << 20) + "</body></html>").utf8)
        var files: [(name: String, payload: Data, declared: Int?)] = [
            ("META-INF/container.xml", Data(#"<container><rootfiles><rootfile full-path="c.opf"/></rootfiles></container>"#.utf8), nil),
        ]
        var manifest = "", spine = ""
        for i in 0..<40 {
            manifest += #"<item id="c\#(i)" href="c\#(i).xhtml" media-type="application/xhtml+xml"/>"#
            spine += #"<itemref idref="c\#(i)"/>"#
            files.append(("c\(i).xhtml", chapter, nil))
        }
        files.insert(("c.opf", Data("<package><metadata><title>B</title></metadata><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>".utf8), nil), at: 1)
        let book = Self.zip(files)
        XCTAssertLessThan(book.count, 4 << 20)
        var imported: ImportedText?
        let took = try seconds { imported = try TextImporter.epub(book) }
        XCTAssertLessThan(took, 60)
        let chapters = imported?.body.components(separatedBy: "\n\n").count ?? 0
        XCTAssertLessThan(chapters, 12, "stopped at the inflate budget, not at chapter 40")
        XCTAssertGreaterThan(chapters, 0)
    }
}

// MARK: - Shared links (IOS-5)

/// A scripted web site for `TextImporter.fetch`: answers by host and path, streams bodies in pieces,
/// redirects, and records every URL that was asked for.
final class ScriptedSite: URLProtocol, @unchecked Sendable {
    enum Answer: Sendable {
        /// `declared`: a Content-Length header to send (nil: none). `pause`: seconds between pieces.
        case body(status: Int = 200, type: String = "text/html; charset=utf-8", pieces: [Data], declared: Int? = nil, pause: Double = 0)
        case redirect(String)
    }

    nonisolated(unsafe) private static var answers: [String: Answer] = [:]
    nonisolated(unsafe) private static var asked: [String] = []
    private static let lock = NSLock()
    static var requests: [String] { lock.withLock { asked } }
    static func script(_ a: [String: Answer]) { lock.withLock { answers = a; asked = [] } }

    private let stopped = NSLock()
    private var isStopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let answer = Self.lock.withLock { () -> Answer? in
            Self.asked.append(url.absoluteString)
            return Self.answers[url.absoluteString]
        }
        guard let answer else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch answer {
        case .redirect(let to):
            let resp = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": to])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: to)!), redirectResponse: resp)
        case .body(let status, let type, let pieces, let declared, let pause):
            var headers = ["Content-Type": type]
            if let declared { headers["Content-Length"] = String(declared) }
            let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            DispatchQueue.global().async { [self] in
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                for piece in pieces {
                    if stopped.withLock({ isStopped }) { return }
                    client?.urlProtocol(self, didLoad: piece)
                    if pause > 0 { Thread.sleep(forTimeInterval: pause) }
                }
                if stopped.withLock({ isStopped }) { return }
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() { stopped.withLock { isStopped = true } }
}

final class LinkFetchTests: XCTestCase {
    static let article = "<html><head><title>Un article</title></head><body><article><p>"
        + String(repeating: "Voici une phrase de l’article, assez longue pour compter. ", count: 12) + "</p></article></body></html>"

    func fetch(_ url: String, _ limits: TextImporter.Limits = .standard) async throws -> ImportedText {
        try await TextImporter.fetch(URL(string: url)!, limits: limits, protocolClasses: [ScriptedSite.self])
    }

    func assertThrows(_ want: TextImportError, _ url: String, _ limits: TextImporter.Limits = .standard,
                      file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let t = try await fetch(url, limits)
            XCTFail("imported “\(t.body.prefix(40))”", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? TextImportError, want, "\(error)", file: file, line: line)
        }
    }

    func testAnOrdinaryPageIsImported() async throws {
        ScriptedSite.script(["https://example.com/a": .body(pieces: [Data(Self.article.utf8)])])
        let t = try await fetch("https://example.com/a")
        XCTAssertEqual(t.title, "Un article")
        XCTAssertTrue(t.body.hasPrefix("Voici une phrase de l’article"))
        XCTAssertEqual(t.sourceURL?.absoluteString, "https://example.com/a")
    }

    /// `file:` and `data:` used to be read (a local file came back as a Reader text).
    func testOnlyWebLinksAreFetched() async throws {
        let secret = FileManager.default.temporaryDirectory.appendingPathComponent("hardening-\(UUID().uuidString).txt")
        try Data("hotspotPassword = my-private-password and some more words to read here".utf8).write(to: secret)
        defer { try? FileManager.default.removeItem(at: secret) }
        ScriptedSite.script([:])
        for url in [secret.absoluteString, "data:text/plain,hello%20from%20a%20data%20url%20with%20several%20words", "ftp://example.com/a.txt",
                    "about:blank", "javascript:alert(1)", "https:///nohost", "pixelclip://x"] {
            await assertThrows(.blockedLink, url)
        }
        XCTAssertEqual(ScriptedSite.requests, [], "nothing was asked for")
        XCTAssertTrue(TextImporter.isWebLink(URL(string: "HTTPS://Example.com/a")!))
        XCTAssertTrue(TextImporter.isWebLink(URL(string: "http://192.168.1.20/notes.html")!), "a link the user shares may be on their own network")
    }

    func testBodyIsCutOffAtTheLimit() async {
        var limits = TextImporter.Limits()
        limits.pageBytes = 100_000
        limits.bookBytes = 300_000
        let piece = Data(repeating: 0x61, count: 50_000)
        ScriptedSite.script([
            "https://example.com/endless": .body(pieces: Array(repeating: piece, count: 400)),                    // 20 MB, undeclared
            "https://example.com/declared": .body(pieces: [piece], declared: 5_000_000),
            "https://example.com/book.epub": .body(type: "application/epub+zip", pieces: Array(repeating: piece, count: 400)),
            "https://example.com/fits": .body(type: "text/plain", pieces: [piece]),
        ])
        await assertThrows(.tooLarge, "https://example.com/endless", limits)
        await assertThrows(.tooLarge, "https://example.com/declared", limits)
        await assertThrows(.tooLarge, "https://example.com/book.epub", limits)
        do { _ = try await fetch("https://example.com/fits", limits) } catch { XCTFail("\(error)") }
    }

    /// A site that sends a little, for ever: the idle timeout never fires, the deadline does.
    func testSlowBodyMeetsTheDeadline() async {
        var limits = TextImporter.Limits()
        limits.deadline = 0.6
        ScriptedSite.script(["https://example.com/drip": .body(pieces: Array(repeating: Data("a".utf8), count: 600), pause: 0.05)])
        let start = Date()
        await assertThrows(.timedOut, "https://example.com/drip", limits)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testRedirectsAreCheckedAgain() async throws {
        let page = ScriptedSite.Answer.body(pieces: [Data(Self.article.utf8)])
        ScriptedSite.script([
            "https://example.com/go": .redirect("https://www.example.org/there"),
            "https://www.example.org/there": page,
            "https://example.com/clip": .redirect("http://192.168.4.1/status"),
            "http://192.168.4.1/status": page,
            "https://example.com/loop": .redirect("http://localhost:8080/admin"),
            "http://localhost:8080/admin": page,
            "https://example.com/file": .redirect("file:///etc/hosts"),
            "https://example.com/v6": .redirect("http://[::1]/"),
            "http://[::1]/": page,
            "https://example.com/1": .redirect("https://example.com/2"), "https://example.com/2": .redirect("https://example.com/3"),
            "https://example.com/3": .redirect("https://example.com/4"), "https://example.com/4": .redirect("https://example.com/5"),
            "https://example.com/5": .redirect("https://example.com/6"), "https://example.com/6": .redirect("https://example.com/7"),
            "https://example.com/7": page,
            "http://nas.local/a": .redirect("http://nas.local/b"), "http://nas.local/b": page,
        ])
        let t = try await fetch("https://example.com/go")
        XCTAssertEqual(t.sourceURL?.absoluteString, "https://www.example.org/there")
        for start in ["https://example.com/clip", "https://example.com/loop", "https://example.com/file", "https://example.com/v6"] {
            await assertThrows(.blockedLink, start)
        }
        let asked = ScriptedSite.requests
        for never in ["http://192.168.4.1/status", "http://localhost:8080/admin", "http://[::1]/", "file:///etc/hosts"] {
            XCTAssertFalse(asked.contains(never), "\(never) was asked for")
        }
        // Five redirects are followed, a sixth is not.
        _ = try await fetch("https://example.com/2")
        await assertThrows(.blockedLink, "https://example.com/1")
        // A page on the user's own network may redirect within its own host.
        _ = try await fetch("http://nas.local/a")
    }

    func testPrivateHosts() {
        for host in ["localhost", "LOCALHOST.", "printer.local", "a.localhost", "router", "127.0.0.1", "127.1", "2130706433", "0x7f.0.0.1",
                     "10.0.0.5", "172.16.0.1", "172.31.255.255", "192.168.4.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "224.0.0.251",
                     "255.255.255.255", "::1", "[::1]", "::", "fe80::1", "fe80::1%en0", "fd00::1", "ff02::fb", "::ffff:192.168.4.1",
                     "64:ff9b::a00:1", "x.home.arpa", ""] {
            XCTAssertTrue(TextImporter.isPrivateHost(host), host)
        }
        for host in ["example.com", "www.example.org.", "8.8.8.8", "172.32.0.1", "192.169.1.1", "100.128.0.1", "2001:4860:4860::8888",
                     "::ffff:8.8.8.8", "local.example.com", "xn--bcher-kva.example"] {
            XCTAssertFalse(TextImporter.isPrivateHost(host), host)
        }
    }

    func testErrorsFromTheSiteAreNotImported() async {
        ScriptedSite.script([
            "https://example.com/404": .body(status: 404, pieces: [Data(Self.article.utf8)]),
            "https://example.com/pdf": .body(type: "application/pdf", pieces: [Data("%PDF".utf8)]),
            "https://example.com/blank": .body(pieces: [Data("<html><body></body></html>".utf8)]),
        ])
        await assertThrows(.http(404), "https://example.com/404")
        await assertThrows(.unsupported("PDF files"), "https://example.com/pdf")
        await assertThrows(.empty, "https://example.com/blank")
    }

    func testRetryPolicy() {
        typealias D = LinkRetry.Decision
        // Final answers: never asked again.
        for e: TextImportError in [.empty, .unsupported("x"), .unreadable, .tooLarge, .blockedLink, .http(404), .http(403), .http(410)] {
            XCTAssertEqual(LinkRetry.decide(after: e, attempts: 0, age: 0), D.drop, "\(e)")
        }
        // The site's trouble: three tries in all.
        for e: any Error in [TextImportError.http(503), TextImportError.http(429), TextImportError.timedOut, URLError(.cannotFindHost),
                             URLError(.secureConnectionFailed)] {
            XCTAssertEqual(LinkRetry.decide(after: e, attempts: 0, age: 0), D.keep(attempts: 1), "\(e)")
            XCTAssertEqual(LinkRetry.decide(after: e, attempts: 1, age: 0), D.keep(attempts: 2), "\(e)")
            XCTAssertEqual(LinkRetry.decide(after: e, attempts: 2, age: 0), D.drop, "\(e)")
        }
        // Offline: not a try, however often; but not kept for ever.
        for code: URLError.Code in [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed] {
            XCTAssertEqual(LinkRetry.decide(after: URLError(code), attempts: 2, age: 3_600), D.keep(attempts: 2))
            XCTAssertEqual(LinkRetry.decide(after: URLError(code), attempts: 0, age: LinkRetry.maxAge + 1), D.drop)
        }
        XCTAssertEqual(LinkRetry.decide(after: CancellationError(), attempts: 1, age: 0), D.keep(attempts: 1))
    }
}

// MARK: - Clip HTTP client (IOS-10)

/// A fake clip that answers whatever it is told to, at `hostile.test` and `elsewhere.test`.
final class HostileClip: URLProtocol, @unchecked Sendable {
    enum Answer: Sendable { case body(Data, declared: Bool), redirect(String, status: Int) }
    nonisolated(unsafe) private static var answer: Answer = .body(Data(), declared: false)
    nonisolated(unsafe) private static var asked: [String] = []
    private static let lock = NSLock()
    static var requests: [String] { lock.withLock { asked } }
    static func script(_ a: Answer) { lock.withLock { answer = a; asked = [] } }

    override class func canInit(with request: URLRequest) -> Bool { ["hostile.test", "elsewhere.test"].contains(request.url?.host ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let answer = Self.lock.withLock { () -> Answer in
            Self.asked.append("\(request.httpMethod ?? "") \(url.absoluteString)")
            return Self.answer
        }
        switch answer {
        case .redirect(let to, let status):
            let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": to])!
            var next = URLRequest(url: URL(string: to)!)
            next.httpMethod = request.httpMethod
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: resp)
        case .body(let data, let declared):
            var headers = ["Content-Type": "application/json"]
            if declared { headers["Content-Length"] = String(data.count) }
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            var rest = data[...]
            while !rest.isEmpty {
                client?.urlProtocol(self, didLoad: Data(rest.prefix(64 << 10)))
                rest = rest.dropFirst(64 << 10)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

final class ClipClientHardeningTests: XCTestCase {
    func client() -> HTTPClipClient {
        HTTPClipClient(baseURL: URL(string: "http://hostile.test")!, protocolClasses: [HostileClip.self])
    }

    func assertBadResponse(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("accepted", file: file, line: line)
        } catch let e as ClipError {
            guard case .badResponse = e else { return XCTFail("\(e)", file: file, line: line) }
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    func testOversizedAnswersAreRefused() async {
        let c = client()
        let padding = String(repeating: " ", count: HTTPClipClient.ResponseLimit.json)
        for declared in [true, false] {
            HostileClip.script(.body(Data((#"{"ok":true}"# + padding).utf8), declared: declared))
            await assertBadResponse { _ = try await c.playlist() }
            await assertBadResponse { try await c.putPlaylist(Playlist(items: [])) }
            await assertBadResponse { _ = try await c.putAsset(id: "a", data: Data([1, 2, 3]), progress: nil) }
            HostileClip.script(.body(Data(count: HTTPClipClient.ResponseLimit.screenshot + 1), declared: declared))
            await assertBadResponse { _ = try await c.screenshot() }
            HostileClip.script(.body(Data(count: HTTPClipClient.ResponseLimit.batteryLog + 1), declared: declared))
            await assertBadResponse { _ = try await c.batteryLog() }
            HostileClip.script(.body(Data(count: HTTPClipClient.ResponseLimit.asset + 1), declared: declared))
            await assertBadResponse { _ = try await c.getAsset(id: "a") }
        }
    }

    func testAnswersOfTheExpectedSizeStillWork() async throws {
        let c = client()
        HostileClip.script(.body(Data(count: RGB565Frame.clipFrameBytes), declared: true))
        let shot = try await c.screenshot()
        XCTAssertEqual(shot.pixels.count, ClipCanvas.width * ClipCanvas.height)
        XCTAssertEqual(HTTPClipClient.ResponseLimit.screenshot, 257_280)
        HostileClip.script(.body(Data(count: 2 << 20), declared: false))
        let asset = try await c.getAsset(id: "a")
        XCTAssertEqual(asset.count, 2 << 20)
        HostileClip.script(.body(Data(#"{"ok":true}"#.utf8), declared: false))
        try await c.next()
    }

    /// A 307 from the "clip" used to re-send the upload to wherever it pointed.
    func testRedirectsAreRefused() async {
        let c = client()
        for status in [301, 302, 307, 308] {
            HostileClip.script(.redirect("http://elsewhere.test/collect", status: status))
            await assertBadResponse { _ = try await c.putText(id: "text-1", data: Data("a private text".utf8)) }
            await assertBadResponse { _ = try await c.status() }
            XCTAssertFalse(HostileClip.requests.contains { $0.contains("elsewhere.test") }, "\(status): \(HostileClip.requests)")
        }
    }
}

// MARK: - Shared items (IOS-3)

final class InboxClaimsTests: XCTestCase {
    var inbox: URL!

    override func setUpWithError() throws {
        inbox = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: inbox) }

    @discardableResult
    func drop(_ name: String, _ text: String = "x") throws -> URL {
        let url = inbox.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// One launch of the app: drop what an earlier launch died on, then claim and read each waiting item.
    /// `read` returns false to "crash" (the launch ends there, nothing is cleaned up).
    func launch(_ read: (String) -> Bool) -> (read: [String], dropped: [String]) {
        let claims = InboxClaims(inbox: inbox)   // a new process: nothing claimed in memory
        let dropped = claims.dropAbandoned()
        var seen: [String] = []
        for file in claims.pending() {
            guard let claimed = claims.claim(file) else { continue }
            let text = (try? String(contentsOf: claimed, encoding: .utf8)) ?? ""
            seen.append(text)
            guard read(text) else { return (seen, dropped) }
            claims.finish(claimed)
        }
        return (seen, dropped)
    }

    /// The crash loop of IOS-3: the item that kills the app is read once, ever.
    func testAPoisonedItemIsNeverReadTwice() throws {
        try drop("001-good.json", "good")
        try drop("002-poison.json", "poison")
        try drop("003-later.json", "later")
        let first = launch { $0 != "poison" }
        XCTAssertEqual(first.read, ["good", "poison"])
        XCTAssertEqual(first.dropped, [])
        var reads = first.read
        for _ in 0..<3 {
            let next = launch { $0 != "poison" }
            reads += next.read
            if next.read.isEmpty { XCTAssertEqual(next.dropped, []) }
        }
        XCTAssertEqual(reads.filter { $0 == "poison" }.count, 1, "read once, at the launch it killed")
        XCTAssertEqual(reads, ["good", "poison", "later"], "the item behind it still arrives; nothing is read twice")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path).filter { $0 != "Processing" }, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.appendingPathComponent("Processing").path), [])
    }

    func testTheSecondLaunchReportsWhatItDropped() throws {
        try drop("a.json", "poison")
        _ = launch { _ in false }
        let second = launch { _ in true }
        XCTAssertEqual(second.dropped, ["a.json"])
        XCTAssertEqual(second.read, [])
    }

    func testThisRunsOwnClaimsAreNotAbandoned() throws {
        let claims = InboxClaims(inbox: inbox)
        let a = try drop("a.json"), b = try drop("b.json")
        let claimed = try XCTUnwrap(claims.claim(a))
        XCTAssertEqual(claimed.deletingLastPathComponent().lastPathComponent, "Processing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path), "out of the inbox before it is read")
        // The app comes forward again while the first item is still being read.
        XCTAssertEqual(claims.dropAbandoned(), [])
        XCTAssertEqual(claims.pending().map(\.lastPathComponent), ["b.json"], "the claimed item and the Processing folder aren't pending")
        XCTAssertNil(claims.claim(a), "claimed once")
        XCTAssertTrue(FileManager.default.fileExists(atPath: claimed.path))
        claims.finish(claimed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claimed.path))
        // A link that couldn't be fetched goes back for a later launch.
        let again = try XCTUnwrap(claims.claim(b))
        claims.release(again)
        XCTAssertEqual(claims.pending().map(\.lastPathComponent), ["b.json"])
        XCTAssertEqual(InboxClaims(inbox: inbox).dropAbandoned(), [], "handed back, not abandoned")
        XCTAssertEqual(InboxClaims.size(of: b), 1)
    }

    func testPendingIsOldestFirstByName() throws {
        for name in ["000001700000002000-b.json", "000001700000001000-a.json", ".hidden", "000001700000003000-c.jpg"] { try drop(name) }
        XCTAssertEqual(InboxClaims(inbox: inbox).pending().map(\.lastPathComponent),
                       ["000001700000001000-a.json", "000001700000002000-b.json", "000001700000003000-c.jpg"])
        XCTAssertEqual(InboxClaims(inbox: inbox.appendingPathComponent("missing")).pending(), [])
    }

    func testDeadline() async throws {
        let quick = try await withDeadline(seconds: 5) { 6 * 7 }
        XCTAssertEqual(quick, 42)
        do {
            _ = try await withDeadline(seconds: 5) { () -> Int in throw TextImportError.empty }
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error as? TextImportError, .empty)
        }
        // Work that never looks at cancellation (a parser in a loop) doesn't hold the caller up.
        let start = Date()
        do {
            _ = try await withDeadline(seconds: 0.2) { () -> Int in
                stall(2)
                return 1
            }
            XCTFail("no deadline")
        } catch {
            XCTAssertTrue(error is DeadlineExceeded, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }
}
