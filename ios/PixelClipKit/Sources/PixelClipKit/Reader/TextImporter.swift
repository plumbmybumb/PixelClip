import Foundation

/// A text ready for the reader: a title, the body (paragraphs separated by a blank line) and, for
/// books, where each chapter starts.
public struct ImportedText: Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Hashable { case pasted, text, markdown, epub, web, shared }

    public struct Chapter: Codable, Sendable, Hashable {
        public var title: String
        /// UTF-8 byte offset of the chapter's first character in `body`.
        public var offset: Int
        public init(title: String, offset: Int) { self.title = title; self.offset = offset }
    }

    public var title: String
    public var body: String
    public var chapters: [Chapter]
    public var kind: Kind
    public var sourceURL: URL?
    /// Site name or file name, for the list.
    public var origin: String?

    public init(title: String, body: String, chapters: [Chapter] = [], kind: Kind, sourceURL: URL? = nil, origin: String? = nil) {
        self.title = title; self.body = body; self.chapters = chapters; self.kind = kind; self.sourceURL = sourceURL; self.origin = origin
    }
}

public enum TextImportError: Error, Equatable, LocalizedError {
    case empty
    case unsupported(String)
    case http(Int)
    case unreadable
    /// Over one of `TextImporter.Limits` (a page, a book or a shared item far bigger than any real one).
    case tooLarge
    /// The site didn't finish answering within the deadline.
    case timedOut
    /// Not a web link, or a link that redirects to a private address (or too many times).
    case blockedLink

    public var errorDescription: String? {
        switch self {
        case .empty: "There’s no text to read in it."
        case .unsupported(let what): "PixelClip can’t read \(what) yet. Try a web page, a .txt, .md or .epub file."
        case .http(let code): code == 404 ? "That page doesn’t exist (404)." : "The site answered with an error (\(code))."
        case .unreadable: "That file couldn’t be opened."
        case .tooLarge: "That’s too big for the Reader."
        case .timedOut: "The site took too long to answer."
        case .blockedLink: "PixelClip can’t open that link."
        }
    }
}

/// Turns pasted text, `.txt`, `.md`, `.epub` and web pages into reader text.
public enum TextImporter {

    /// What an import may cost. Each sits far above real use (an article is a few hundred KB of HTML, a
    /// novel a few MB of EPUB, and the clip keeps 1 MB of text): past them the import stops with a
    /// plain message instead of filling memory or holding the Reader up.
    public struct Limits: Sendable, Equatable {
        /// A fetched web page or text (and the HTML of a shared page).
        public var pageBytes = HTMLText.Limits.maxInputBytes
        /// A fetched EPUB.
        public var bookBytes = 64 << 20
        /// The whole download, however slowly the bytes arrive.
        public var deadline: TimeInterval = 60
        /// Silence from the server.
        public var idleTimeout: TimeInterval = 20
        public var maxRedirects = 5

        public init() {}
        public static let standard = Limits()
    }

    /// Reader text past this is never used (`ReaderDocument.make` cuts a text at the clip's 1 MB), so
    /// Markdown and EPUB imports stop producing it.
    static let maxBodyBytes = 2 * ReaderLimits.maxTextBytes
    /// Spine documents of an EPUB that are read, and what they may inflate to in all.
    static let maxSpineItems = 10_000
    static let maxBookInflatedBytes = 128 << 20

    // MARK: Plain text

    /// Line endings to `\n`, no trailing spaces, at most one blank line between paragraphs.
    public static func normalise(_ s: String) -> String {
        let unified = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        var out: [String] = []
        var blank = 0
        for line in unified.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: CharacterSet(charactersIn: " "))
            if t.isEmpty { blank += 1; continue }
            if !out.isEmpty && blank > 0 { out.append("") }
            blank = 0
            out.append(String(line).trimmingCharacters(in: .whitespaces))
        }
        return out.joined(separator: "\n")
    }

    /// A short first line is the title (and leaves the body); otherwise `fallbackTitle` or the first words.
    public static func plain(_ s: String, fallbackTitle: String? = nil, kind: ImportedText.Kind = .pasted) -> ImportedText {
        let text = normalise(s)
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        if lines.count == 2, let first = lines.first, isTitleLike(String(first)) {
            let body = String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { return ImportedText(title: String(first), body: body, kind: kind, origin: fallbackTitle) }
        }
        return ImportedText(title: fallbackTitle.map(cleanFileName) ?? firstWords(text), body: text, kind: kind, origin: fallbackTitle)
    }

    static func isTitleLike(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 100 else { return false }
        let words = t.split(separator: " ").count
        return words <= 14 && !(t.hasSuffix(",") || t.hasSuffix(";"))
    }

    /// "Le petit prince" from "le-petit_prince.epub".
    static func cleanFileName(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// The first six words, with "…" when there are more.
    public static func firstWords(_ s: String, count: Int = 6) -> String {
        let words = s.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return "Untitled" }
        return words.prefix(count).joined(separator: " ") + (words.count > count ? "…" : "")
    }

    // MARK: Markdown

    /// Markdown to reader text: front matter, code blocks, images, link targets, emphasis marks,
    /// HTML, table rules and list markers go; headings become paragraphs (and chapters for # / ##).
    public static func markdown(_ s: String, fallbackTitle: String? = nil) -> ImportedText {
        var text = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var title: String?
        // Front matter.
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            let fm = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
            for line in fm.split(separator: "\n") where line.lowercased().hasPrefix("title:") {
                title = line.dropFirst(6).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
            text = String(text[end.upperBound...]).drop { $0 != "\n" }.description
        }
        var paras: [String] = []
        var cur: [String] = []
        var chapters: [(title: String, para: Int)] = []
        var inFence = false
        var bodyBytes = 0
        func flush() {
            let p = cur.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !p.isEmpty { paras.append(p); bodyBytes += p.utf8.count }
            cur = []
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (i, raw) in lines.enumerated() {
            // Past twice the clip's text limit nothing more is kept.
            if bodyBytes > maxBodyBytes { break }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); flush(); continue }
            if inFence { continue }
            if line.isEmpty { flush(); continue }
            // Setext underline / horizontal rule / table rule.
            if line.allSatisfy({ "=-*_ ".contains($0) }) && line.filter({ $0 != " " }).count >= 3 {
                if line.allSatisfy({ $0 == "=" || $0 == " " }), cur.count == 1, chapters.last?.para != paras.count {
                    chapters.append((inline(cur[0]), paras.count))
                }
                flush(); continue
            }
            if line.hasPrefix("|") && line.allSatisfy({ "|-: ".contains($0) }) { continue }
            if line.range(of: #"^\[[^\]]+\]:\s"#, options: .regularExpression) != nil { continue }   // reference definitions
            if let m = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                let level = line[m].filter { $0 == "#" }.count
                let h = inline(withoutClosingHashes(String(line[m.upperBound...])))
                if level == 1 && paras.isEmpty && (title == nil || title?.caseInsensitiveCompare(h) == .orderedSame) { title = title ?? h; continue }
                if level <= 2 { chapters.append((h, paras.count)) }
                paras.append(h)
                bodyBytes += h.utf8.count
                continue
            }
            var l = line
            while l.hasPrefix(">") { l = String(l.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if let m = l.range(of: #"^([-*+]|\d{1,3}[.)])\s+"#, options: .regularExpression) {
                flush()
                l = String(l[m.upperBound...])
                l = l.replacingOccurrences(of: #"^\[[ xX]\]\s+"#, with: "", options: .regularExpression)
                cur.append(inline(l))
                flush()
                continue
            }
            if l.hasPrefix("|") || l.hasSuffix("|") { l = l.replacingOccurrences(of: "|", with: "  ") }
            _ = i
            cur.append(inline(l))
        }
        flush()
        let body = paras.joined(separator: "\n\n")
        var offsets: [ImportedText.Chapter] = []
        var off = 0
        for (k, p) in paras.enumerated() {
            for c in chapters where c.para == k { offsets.append(.init(title: c.title, offset: off)) }
            off += p.utf8.count + 2
        }
        let t = title ?? fallbackTitle.map(cleanFileName) ?? firstWords(body)
        return ImportedText(title: t, body: body, chapters: offsets, kind: .markdown, origin: fallbackTitle)
    }

    /// Inline Markdown → text: images and footnote marks go, links keep their text, autolinks their
    /// address, inline HTML goes, code / bold / emphasis / strike lose their marks, escapes their backslash.
    ///
    /// One left-to-right pass per rule, in this order, each over the previous one's result. They do what
    /// the regular expressions noted beside them did (`MarkdownInlineTests` checks that on random lines),
    /// in linear time: a mark with nothing to close it is looked up, not searched for, so a line
    /// of ten thousand stray asterisks costs what a line of ten thousand letters does.
    static func inline(_ s: String) -> String {
        var t = Array(s.unicodeScalars)
        var marks = Set<Unicode.Scalar>()
        for u in t where u.isASCII && Self.inlineMarks.contains(u) { marks.insert(u) }
        guard !marks.isEmpty else { return HTMLText.decodeEntities(s) }
        if marks.contains("[") {
            if marks.contains("!") { t = Self.dropImages(t) }                       //  !\[[^\]]*\]\([^)]*\)
            t = Self.dropFootnoteMarks(t)                                           //  \[\^[^\]]+\]
            t = Self.unwrapLinks(t, open: "(", close: ")")                          //  \[([^\]]+)\]\([^)]*\)
            t = Self.unwrapLinks(t, open: "[", close: "]")                          //  \[([^\]]+)\]\[[^\]]*\]
        }
        if marks.contains("<") {
            t = Self.unwrapAutolinks(t)                                             //  <(https?://[^>]+)>
            t = Self.dropTags(t)                                                    //  <[^>]+>
        }
        if marks.contains("`") { t = Self.unwrapCode(t) }                           //  `([^`]+)`
        if marks.contains("*") || marks.contains("_") { t = Self.unwrapBold(t) }    //  (\*\*|__)(.+?)\1
        if marks.contains("*") { t = Self.unwrapEmphasis(t, mark: "*") }            //  (?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])
        if marks.contains("_") { t = Self.unwrapEmphasis(t, mark: "_") }            //  (?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)
        if marks.contains("~") { t = Self.unwrapPairs(t, mark: "~") }               //  ~~(.+?)~~
        if marks.contains("\\") { t = Self.dropEscapes(t) }                         //  \\([\\`*_{}\[\]()#+\-.!>|~])
        var out = String.UnicodeScalarView()
        out.append(contentsOf: t)
        return HTMLText.decodeEntities(String(out))
    }

    private static let inlineMarks: Set<Unicode.Scalar> = ["!", "[", "<", "`", "*", "_", "~", "\\"]
    private static let escapable: Set<Unicode.Scalar> = ["\\", "`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "+", "-", ".", "!", ">", "|", "~"]

    /// The regular-expression classes the rules were written with, as Foundation's engine has them:
    /// `\s` (Unicode White_Space), `\w`, and the line breaks `.` doesn't cross.
    static func isSpace(_ u: Unicode.Scalar) -> Bool { u.properties.isWhitespace }

    static func isWord(_ u: Unicode.Scalar) -> Bool {
        if u.value == 0x200C || u.value == 0x200D || u.properties.isAlphabetic { return true }
        switch u.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .connectorPunctuation: return true
        default: return false
        }
    }

    static func isLineBreak(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// `next[p]`: the first index at or after `p` where `test` holds, else `t.count` (`next` has `t.count + 2` entries).
    private static func nextIndex(_ t: [Unicode.Scalar], where test: (Int) -> Bool) -> [Int] {
        let n = t.count
        var next = [Int](repeating: n, count: n + 2)
        var k = n - 1
        while k >= 0 {
            next[k] = test(k) ? k : next[k + 1]
            k -= 1
        }
        return next
    }

    private static func dropImages(_ t: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let n = t.count
        let rb = nextIndex(t) { t[$0] == "]" }, rp = nextIndex(t) { t[$0] == ")" }
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(n)
        var i = 0
        while i < n {
            if t[i] == "!", i + 1 < n, t[i + 1] == "[" {
                let j = rb[i + 2]
                if j + 1 < n, t[j + 1] == "(" {
                    let k = rp[min(n, j + 2)]
                    if k < n { i = k + 1; continue }
                }
            }
            out.append(t[i]); i += 1
        }
        return out
    }

    private static func dropFootnoteMarks(_ t: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let n = t.count
        let rb = nextIndex(t) { t[$0] == "]" }
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(n)
        var i = 0
        while i < n {
            if t[i] == "[", i + 1 < n, t[i + 1] == "^" {
                let j = rb[i + 2]
                if j < n, j > i + 2 { i = j + 1; continue }
            }
            out.append(t[i]); i += 1
        }
        return out
    }

    /// `[text](target)` (open "(", close ")") or `[text][ref]` (open "[", close "]") → `text`.
    private static func unwrapLinks(_ t: [Unicode.Scalar], open: Unicode.Scalar, close: Unicode.Scalar) -> [Unicode.Scalar] {
        let n = t.count
        let rb = nextIndex(t) { t[$0] == "]" }
        let end = close == "]" ? rb : nextIndex(t) { t[$0] == close }
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(n)
        var i = 0
        while i < n {
            if t[i] == "[" {
                let j = rb[i + 1]
                if j > i + 1, j + 1 < n, t[j + 1] == open {
                    let k = end[min(n, j + 2)]
                    if k < n { out.append(contentsOf: t[(i + 1)..<j]); i = k + 1; continue }
                }
            }
            out.append(t[i]); i += 1
        }
        return out
    }

    private static func unwrapAutolinks(_ t: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let n = t.count
        let gt = nextIndex(t) { t[$0] == ">" }
        let http: [Unicode.Scalar] = ["h", "t", "t", "p"], sep: [Unicode.Scalar] = [":", "/", "/"]
        func has(_ lit: [Unicode.Scalar], at p: Int) -> Bool {
            guard p + lit.count <= n else { return false }
            for (k, u) in lit.enumerated() where t[p + k] != u { return false }
            return true
        }
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(n)
        var i = 0
        while i < n {
            if t[i] == "<", has(http, at: i + 1) {
                var p = i + 5
                if p < n, t[p] == "s" { p += 1 }
                if has(sep, at: p) {
                    let k = gt[min(n, p + 3)]
                    if k < n, k > p + 3 { out.append(contentsOf: t[(i + 1)..<k]); i = k + 1; continue }
                }
            }
            out.append(t[i]); i += 1
        }
        return out
    }

    private static func dropTags(_ t: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let n = t.count
        let gt = nextIndex(t) { t[$0] == ">" }
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(n)
        var i = 0
        while i < n {
            if t[i] == "<" {
                let k = gt[i + 1]
                if k < n, k > i + 1 { i = k + 1; continue }
            }
            out.append(t[i]); i += 1
        }
        return out
    }

    private static func unwrapCode(_ t: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let n = t.count
        let tick = nextIndex(t) { t[$0] == "`" }
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(n)
        var i = 0
        while i < n {
            if t[i] == "`" {
                let k = tick[i + 1]
                if k < n, k > i + 1 { out.append(contentsOf: t[(i + 1)..<k]); i = k + 1; continue }
            }
            out.append(t[i]); i += 1
        }
        return out
    }

    /// `**bold**` and `__bold__` → `bold` (the nearest closing pair at least one character on, same line).
    private static func unwrapBold(_ t: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let n = t.count
        let stars = nextIndex(t) { $0 + 1 < n && t[$0] == "*" && t[$0 + 1] == "*" }
        let unders = nextIndex(t) { $0 + 1 < n && t[$0] == "_" && t[$0 + 1] == "_" }
        let lineBreak = nextIndex(t) { isLineBreak(t[$0]) }
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(n)
        var i = 0
        while i < n {
            if i + 1 < n, t[i] == "*" || t[i] == "_", t[i + 1] == t[i] {
                let j = (t[i] == "*" ? stars : unders)[min(n, i + 3)]
                if j < n, lineBreak[i + 2] >= j { out.append(contentsOf: t[(i + 2)..<j]); i = j + 2; continue }
            }
            out.append(t[i]); i += 1
        }
        return out
    }

    /// `~~struck~~` → `struck`.
    private static func unwrapPairs(_ t: [Unicode.Scalar], mark: Unicode.Scalar) -> [Unicode.Scalar] {
        let n = t.count
        let pairs = nextIndex(t) { $0 + 1 < n && t[$0] == mark && t[$0 + 1] == mark }
        let lineBreak = nextIndex(t) { isLineBreak(t[$0]) }
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(n)
        var i = 0
        while i < n {
            if i + 1 < n, t[i] == mark, t[i + 1] == mark {
                let j = pairs[min(n, i + 3)]
                if j < n, lineBreak[i + 2] >= j { out.append(contentsOf: t[(i + 2)..<j]); i = j + 2; continue }
            }
            out.append(t[i]); i += 1
        }
        return out
    }

    /// `*em*` / `_em_` → `em`. An opening mark has no word character (nor, for `*`, another `*`) before
    /// it and no space after; a closing one no space before and no word character (nor `*`) after.
    private static func unwrapEmphasis(_ t: [Unicode.Scalar], mark: Unicode.Scalar) -> [Unicode.Scalar] {
        let n = t.count
        let star = mark == "*"
        func joins(_ u: Unicode.Scalar) -> Bool { isWord(u) || (star && u == "*") }
        let closer = nextIndex(t) { k in
            t[k] == mark && k > 0 && !isSpace(t[k - 1]) && (k + 1 == n || !joins(t[k + 1]))
        }
        let lineBreak = nextIndex(t) { isLineBreak(t[$0]) }
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(n)
        var i = 0
        while i < n {
            if t[i] == mark, i + 1 < n, !isSpace(t[i + 1]), i == 0 || !joins(t[i - 1]) {
                let j = closer[min(n, i + 2)]
                if j < n, lineBreak[i + 1] >= j { out.append(contentsOf: t[(i + 1)..<j]); i = j + 1; continue }
            }
            out.append(t[i]); i += 1
        }
        return out
    }

    private static func dropEscapes(_ t: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let n = t.count
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(n)
        var i = 0
        while i < n {
            if t[i] == "\\", i + 1 < n, escapable.contains(t[i + 1]) { out.append(t[i + 1]); i += 2; continue }
            out.append(t[i]); i += 1
        }
        return out
    }

    /// A heading without its closing hashes: "Title ##" → "Title" (what `\s+#+\s*$` removed).
    static func withoutClosingHashes(_ s: String) -> String {
        let t = Array(s.unicodeScalars)
        // `$` also matches just before a line break that ends the string.
        for end in [t.count, t.count - 1] where end >= 0 && (end == t.count || isLineBreak(t[end])) {
            var q = end
            while q > 0, isSpace(t[q - 1]) { q -= 1 }
            var p = q
            while p > 0, t[p - 1] == "#" { p -= 1 }
            var m = p
            while m > 0, isSpace(t[m - 1]) { m -= 1 }
            guard p < q, m < p else { continue }
            var out = String.UnicodeScalarView()
            out.append(contentsOf: t[..<m])
            out.append(contentsOf: t[end...])
            return String(out)
        }
        return s
    }

    // MARK: Web pages

    /// A page's article text and title.
    public static func html(_ html: String, url: URL? = nil) -> ImportedText {
        let a = HTMLText.article(html, url: url)
        let body = normalise(a.text)
        let title = a.title.isEmpty ? firstWords(body) : a.title
        return ImportedText(title: title, body: body, kind: .web, sourceURL: url, origin: a.site)
    }

    /// A link the Reader may fetch at all: `http` or `https` with a host. No `file:`, `data:` or any
    /// other scheme (a shared link comes from another app's content, not from the user's typing).
    public static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// Download `url` and import it (HTML through the readability pass; plain text and EPUB as files).
    ///
    /// Web links only, through a throw-away session (no cookies, no cache, nothing kept on disk), with
    /// the whole download under `limits.deadline`, the body cut off at the size limit while it streams,
    /// and every redirect checked again: at most `limits.maxRedirects`, to a web link, and never to this
    /// device, a link-local address or a private network (unless the link itself pointed there).
    /// - Parameter protocolClasses: URL protocols to put first (tests stub the site with one).
    public static func fetch(_ url: URL, limits: Limits = .standard, protocolClasses: [AnyClass] = []) async throws -> ImportedText {
        guard isWebLink(url) else { throw TextImportError.blockedLink }
        var req = URLRequest(url: url, timeoutInterval: limits.idleTimeout)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        req.setValue(Locale.preferredLanguages.prefix(3).joined(separator: ", "), forHTTPHeaderField: "Accept-Language")
        let (data, resp) = try await BoundedDownload.run(req, limits: limits, protocolClasses: protocolClasses)
        let http = resp as? HTTPURLResponse
        if let code = http?.statusCode, !(200..<300).contains(code) { throw TextImportError.http(code) }
        let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let final = http?.url ?? url
        let name = final.lastPathComponent
        if BoundedDownload.isBook(type: type, name: name) { return try epub(data, fallbackTitle: name) }
        if type.contains("pdf") { throw TextImportError.unsupported("PDF files") }
        if type.hasPrefix("text/plain") {
            var t = plain(HTMLText.decode(data, contentType: type), fallbackTitle: name, kind: .web)
            t.sourceURL = final
            t.origin = final.host
            return t
        }
        if type.hasPrefix("text/markdown") {
            var t = markdown(HTMLText.decode(data, contentType: type), fallbackTitle: name)
            t.kind = .web; t.sourceURL = final; t.origin = final.host
            return t
        }
        if !type.isEmpty, !type.contains("html"), !type.contains("xml") { throw TextImportError.unsupported("this kind of link") }
        let result = html(HTMLText.decode(data, contentType: type), url: final)
        guard !result.body.isEmpty else { throw TextImportError.empty }
        return result
    }

    /// Hosts a redirect may not lead to: this device (`localhost`, loopback), link-local and private
    /// networks, names that only resolve on the local network (`.local`, one-label names), and the
    /// multicast and reserved ranges. Only what the URL says is checked: a public name that resolves to
    /// a private address is not caught here.
    static func isPrivateHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return true }
        var v6 = in6_addr()
        if host.contains(":") {
            guard inet_pton(AF_INET6, host, &v6) == 1 else { return true }   // not an address we can judge
            let b = withUnsafeBytes(of: &v6) { Array($0) }
            if b.allSatisfy({ $0 == 0 }) { return true }                                   // ::
            if b[0..<15].allSatisfy({ $0 == 0 }), b[15] == 1 { return true }               // ::1
            if b[0] == 0xFE, b[1] & 0xC0 == 0x80 { return true }                           // fe80::/10 link-local
            if b[0] & 0xFE == 0xFC { return true }                                         // fc00::/7 unique local
            if b[0] == 0xFF { return true }                                                // multicast
            let mapped = b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF          // ::ffff:a.b.c.d
            let compatible = b[0..<12].allSatisfy({ $0 == 0 })                                        // ::a.b.c.d
            let nat64 = b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xFF && b[3] == 0x9B && b[4..<12].allSatisfy({ $0 == 0 })
            if mapped || compatible || nat64 { return isPrivateIPv4(b[12], b[13], b[14], b[15]) }
            return false
        }
        // Every spelling the resolver takes for an IPv4 address ("127.1", "0x7f.0.0.1", "2130706433").
        var v4 = in_addr()
        if inet_aton(host, &v4) != 0 {
            let a = UInt32(bigEndian: v4.s_addr)
            return isPrivateIPv4(UInt8(a >> 24), UInt8(a >> 16 & 0xFF), UInt8(a >> 8 & 0xFF), UInt8(a & 0xFF))
        }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".home.arpa") { return true }
        return !host.contains(".")   // "router", "nas": names of the local network
    }

    static func isPrivateIPv4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Bool {
        switch (a, b) {
        case (0, _), (10, _), (127, _): return true          // this network, private, loopback
        case (100, 64...127): return true                    // carrier-grade NAT
        case (169, 254): return true                         // link-local
        case (172, 16...31): return true                     // private
        case (192, 168): return true                         // private
        case (192, 0) where c == 0: return true              // protocol assignments
        case (198, 18...19): return true                     // benchmarking
        case (224..., _): return true                        // multicast, reserved, broadcast
        default: return false
        }
    }

    // MARK: Files

    /// `.txt`, `.text`, `.md`/`.markdown`, `.epub`, `.html`/`.htm` (anything else is tried as text).
    public static func file(_ data: Data, name: String) throws -> ImportedText {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "epub": return try epub(data, fallbackTitle: name)
        case "md", "markdown", "mdown", "mkd": return markdown(HTMLText.decode(data), fallbackTitle: name)
        case "html", "htm", "xhtml":
            guard data.count <= Limits.standard.pageBytes else { throw TextImportError.tooLarge }
            var t = html(HTMLText.decode(data))
            t.origin = name
            return t
        case "pdf", "doc", "docx", "pages", "rtf": throw TextImportError.unsupported(ext.uppercased() + " files")
        default:
            if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return try epub(data, fallbackTitle: name) }
            let t = plain(HTMLText.decode(data), fallbackTitle: name, kind: .text)
            guard !t.body.isEmpty else { throw TextImportError.empty }
            return t
        }
    }

    // MARK: EPUB

    /// An EPUB 2/3: the spine in reading order, one chapter per spine document (titled from the nav
    /// document or NCX, else its first heading), XHTML → paragraphs.
    public static func epub(_ data: Data, fallbackTitle: String? = nil) throws -> ImportedText {
        let zip: ZipArchive
        do { zip = try ZipArchive(data: data) } catch { throw TextImportError.unreadable }
        guard let container = try? zip.read("META-INF/container.xml"),
              let opfPath = XMLScan(data: container).first("rootfile")?["full-path"] else { throw TextImportError.unreadable }
        guard let opfData = try? zip.read(opfPath) else { throw TextImportError.unreadable }
        let opfDir = (opfPath as NSString).deletingLastPathComponent
        let opf = XMLScan(data: opfData)
        let bookTitle = opf.text(of: "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
        var manifest: [String: (href: String, type: String, props: String)] = [:]
        for item in opf.all("item") {
            guard let id = item["id"], let href = item["href"] else { continue }
            manifest[id] = (resolve(href, in: opfDir), item["media-type"] ?? "", item["properties"] ?? "")
        }
        let spineAttrs = opf.first("spine")
        let spine = opf.all("itemref").filter { ($0["linear"] ?? "yes") != "no" }.compactMap { $0["idref"] }

        // Chapter names from the EPUB 3 nav document, else the NCX.
        var names: [String: String] = [:]
        if let nav = manifest.values.first(where: { $0.props.split(separator: " ").contains("nav") }),
           let navData = try? zip.read(nav.href) {
            let navDir = (nav.href as NSString).deletingLastPathComponent
            let doc = HTMLText.parse(HTMLText.decode(navData))
            let tocNav = doc.elements().first { $0.name == "nav" && ($0.attrs["epub:type"] ?? $0.attrs["type"] ?? "").contains("toc") }
                ?? doc.first("nav")
            for a in tocNav?.elements().filter({ $0.name == "a" }) ?? [] {
                guard let href = a.attrs["href"] else { continue }
                let key = resolve(String(href.split(separator: "#", maxSplits: 1).first ?? ""), in: navDir)
                let label = a.innerText(maxNodes: labelNodes)
                if names[key] == nil, !label.isEmpty { names[key] = label }
            }
        }
        if names.isEmpty, let tocID = spineAttrs?["toc"], let ncx = manifest[tocID], let ncxData = try? zip.read(ncx.href) {
            let ncxDir = (ncx.href as NSString).deletingLastPathComponent
            let doc = HTMLText.parse(HTMLText.decode(ncxData))
            for point in doc.elements() where point.name == "navpoint" {
                guard let src = point.firstElement(maxNodes: labelNodes, where: { $0.name == "content" })?.attrs["src"] else { continue }
                let label = point.firstElement(maxNodes: labelNodes, where: { $0.name == "text" })?.innerText(maxNodes: labelNodes) ?? ""
                let key = resolve(String(src.split(separator: "#", maxSplits: 1).first ?? ""), in: ncxDir)
                if names[key] == nil, !label.isEmpty { names[key] = label }
            }
        }

        var body = ""
        var chapters: [ImportedText.Chapter] = []
        var inflated = 0
        for (n, idref) in spine.prefix(maxSpineItems).enumerated() {
            // Text past the clip's limit is never used, and a book's chapters don't inflate to hundreds of MB.
            if body.utf8.count > maxBodyBytes || inflated > maxBookInflatedBytes { break }
            guard let item = manifest[idref], item.type.contains("html") || item.href.lowercased().hasSuffix("html"),
                  let xhtml = try? zip.read(item.href) else { continue }
            inflated += xhtml.count
            let doc = HTMLText.parse(HTMLText.decode(xhtml))
            let paras = HTMLText.paragraphs(of: doc.first("body") ?? doc)
            guard !paras.isEmpty else { continue }
            let text = normalise(paras.joined(separator: "\n\n"))
            guard !text.isEmpty else { continue }
            if !body.isEmpty { body += "\n\n" }
            let name = names[item.href] ?? HTMLText.firstHeading(in: doc) ?? "Chapter \(n + 1)"
            chapters.append(.init(title: name, offset: body.utf8.count))
            body += text
        }
        guard !body.isEmpty else { throw TextImportError.empty }
        // A one-chapter book doesn't need a chapter list.
        if chapters.count == 1 { chapters = [] }
        let title = (bookTitle?.isEmpty == false ? bookTitle : nil) ?? fallbackTitle.map(cleanFileName) ?? firstWords(body)
        return ImportedText(title: title, body: body, chapters: chapters, kind: .epub, origin: fallbackTitle)
    }

    /// Nodes looked at for one table-of-contents label (a chapter name is a few words).
    private static let labelNodes = 2_000

    /// `href` (percent-encoded, relative) inside `dir`, with `..` resolved.
    static func resolve(_ href: String, in dir: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        var parts = dir.isEmpty ? [] : dir.split(separator: "/").map(String.init)
        for p in decoded.split(separator: "/") {
            if p == ".." { if !parts.isEmpty { parts.removeLast() } } else if p != "." { parts.append(String(p)) }
        }
        return parts.joined(separator: "/")
    }
}

/// A tiny XML element scanner over `XMLParser` (namespace prefixes dropped): element attributes in
/// document order and the text of the first element of a name.
struct XMLScan {
    struct Element { var name: String; var attrs: [String: String]; var text: String
        subscript(_ k: String) -> String? { attrs[k] }
    }
    let elements: [Element]

    init(data: Data) {
        let d = Delegate()
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = false
        p.delegate = d
        p.parse()
        elements = d.elements
    }

    func first(_ name: String) -> Element? { elements.first { $0.name == name } }
    func all(_ name: String) -> [Element] { elements.filter { $0.name == name } }
    func text(of name: String) -> String? { first(name)?.text }

    final class Delegate: NSObject, XMLParserDelegate {
        var elements: [Element] = []
        var open: [Int] = []

        static func local(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            var attrs: [String: String] = [:]
            for (k, v) in attributeDict { attrs[Self.local(k)] = v }
            elements.append(Element(name: Self.local(elementName), attrs: attrs, text: ""))
            open.append(elements.count - 1)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = open.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if let i = open.last { elements[i].text += string }
        }
    }
}

/// One bounded download for `TextImporter.fetch`: an ephemeral session of its own (no cookies, no cache),
/// the body collected as it streams and cut off at the size limit, every redirect checked, one deadline
/// over the whole exchange.
final class BoundedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private enum Stop { case tooLarge, blocked, timedOut }

    private let limits: TextImporter.Limits
    /// The host the link itself named: a redirect back to it is always allowed.
    private let origin: String
    private let lock = NSLock()
    private var body = Data()
    private var cap: Int
    private var response: URLResponse?
    private var stop: Stop?
    private var redirects = 0
    private var continuation: CheckedContinuation<(Data, URLResponse), any Error>?

    private init(limits: TextImporter.Limits, origin: String) {
        self.limits = limits
        self.origin = origin
        cap = limits.pageBytes
    }

    static func isBook(type: String, name: String) -> Bool { type.contains("epub") || name.lowercased().hasSuffix(".epub") }

    static func run(_ request: URLRequest, limits: TextImporter.Limits, protocolClasses: [AnyClass]) async throws -> (Data, URLResponse) {
        let cfg = URLSessionConfiguration.ephemeral
        if !protocolClasses.isEmpty { cfg.protocolClasses = protocolClasses + (cfg.protocolClasses ?? []) }
        cfg.timeoutIntervalForRequest = limits.idleTimeout
        cfg.timeoutIntervalForResource = max(limits.deadline * 4, limits.deadline + 60)   // a backstop; the timer below is the deadline
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCredentialStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.waitsForConnectivity = false
        let download = BoundedDownload(limits: limits, origin: (request.url?.host ?? "").lowercased())
        let session = URLSession(configuration: cfg, delegate: download, delegateQueue: nil)
        defer { session.invalidateAndCancel() }   // the session holds its delegate until then
        let task = session.dataTask(with: request)
        let timer = Task {
            // Counted while the app runs: coming back from the background doesn't find the deadline already past.
            if await sleepWhileRunning(seconds: limits.deadline) { download.halt(.timedOut, task) }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.lock.withLock { download.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func halt(_ reason: Stop, _ task: URLSessionTask) {
        lock.withLock { if stop == nil { stop = reason } }
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let count = lock.withLock { redirects += 1; return redirects }
        let host = (request.url?.host ?? "").lowercased()
        let allowed = count <= limits.maxRedirects && (request.url.map(TextImporter.isWebLink) ?? false)
            && (host == origin || !TextImporter.isPrivateHost(host))
        if allowed { completionHandler(request); return }
        completionHandler(nil)
        halt(.blocked, task)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let type = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let limit = Self.isBook(type: type, name: response.url?.lastPathComponent ?? "") ? limits.bookBytes : limits.pageBytes
        lock.withLock { self.response = response; cap = limit }
        if response.expectedContentLength > Int64(limit) {
            completionHandler(.cancel)
            halt(.tooLarge, dataTask)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over = lock.withLock { () -> Bool in
            guard stop == nil else { return false }
            body.append(data)
            return body.count > cap
        }
        if over { halt(.tooLarge, dataTask) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (cont, stop, body, response) = lock.withLock { () -> (CheckedContinuation<(Data, URLResponse), any Error>?, Stop?, Data, URLResponse?) in
            defer { continuation = nil }
            return (continuation, self.stop, self.body, self.response)
        }
        guard let cont else { return }
        switch stop {
        case .tooLarge: cont.resume(throwing: TextImportError.tooLarge)
        case .blocked: cont.resume(throwing: TextImportError.blockedLink)
        case .timedOut: cont.resume(throwing: TextImportError.timedOut)
        case nil:
            if let e = error as? URLError, e.code == .timedOut { cont.resume(throwing: TextImportError.timedOut) }
            else if let e = error as? URLError, e.code == .cancelled { cont.resume(throwing: CancellationError()) }
            else if let error { cont.resume(throwing: error) }
            else if let response { cont.resume(returning: (body, response)) }
            else { cont.resume(throwing: TextImportError.unreadable) }
        }
    }
}
