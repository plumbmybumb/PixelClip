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

    public var errorDescription: String? {
        switch self {
        case .empty: "There’s no text to read in it."
        case .unsupported(let what): "PixelClip can’t read \(what) yet. Try a web page, a .txt, .md or .epub file."
        case .http(let code): code == 404 ? "That page doesn’t exist (404)." : "The site answered with an error (\(code))."
        case .unreadable: "That file couldn’t be opened."
        }
    }
}

/// Turns pasted text, `.txt`, `.md`, `.epub` and web pages into reader text.
public enum TextImporter {

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
        func flush() {
            let p = cur.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !p.isEmpty { paras.append(p) }
            cur = []
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (i, raw) in lines.enumerated() {
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
                let h = inline(String(line[m.upperBound...]).replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression))
                if level == 1 && paras.isEmpty && (title == nil || title?.caseInsensitiveCompare(h) == .orderedSame) { title = title ?? h; continue }
                if level <= 2 { chapters.append((h, paras.count)) }
                paras.append(h)
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

    /// Inline Markdown → text.
    static func inline(_ s: String) -> String {
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

    // MARK: Web pages

    /// A page's article text and title.
    public static func html(_ html: String, url: URL? = nil) -> ImportedText {
        let a = HTMLText.article(html, url: url)
        let body = normalise(a.text)
        let title = a.title.isEmpty ? firstWords(body) : a.title
        return ImportedText(title: title, body: body, kind: .web, sourceURL: url, origin: a.site)
    }

    /// Download `url` and import it (HTML through the readability pass; plain text and EPUB as files).
    public static func fetch(_ url: URL, session: URLSession = .shared) async throws -> ImportedText {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        req.setValue(Locale.preferredLanguages.prefix(3).joined(separator: ", "), forHTTPHeaderField: "Accept-Language")
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        if let code = http?.statusCode, !(200..<300).contains(code) { throw TextImportError.http(code) }
        let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let final = http?.url ?? url
        let name = final.lastPathComponent
        if type.contains("epub") || name.lowercased().hasSuffix(".epub") { return try epub(data, fallbackTitle: name) }
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

    // MARK: Files

    /// `.txt`, `.text`, `.md`/`.markdown`, `.epub`, `.html`/`.htm` (anything else is tried as text).
    public static func file(_ data: Data, name: String) throws -> ImportedText {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "epub": return try epub(data, fallbackTitle: name)
        case "md", "markdown", "mdown", "mkd": return markdown(HTMLText.decode(data), fallbackTitle: name)
        case "html", "htm", "xhtml":
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
                let label = a.innerText
                if names[key] == nil, !label.isEmpty { names[key] = label }
            }
        }
        if names.isEmpty, let tocID = spineAttrs?["toc"], let ncx = manifest[tocID], let ncxData = try? zip.read(ncx.href) {
            let ncxDir = (ncx.href as NSString).deletingLastPathComponent
            let doc = HTMLText.parse(HTMLText.decode(ncxData))
            for point in doc.elements() where point.name == "navpoint" {
                guard let src = point.elements().first(where: { $0.name == "content" })?.attrs["src"] else { continue }
                let label = point.elements().first(where: { $0.name == "text" })?.innerText ?? ""
                let key = resolve(String(src.split(separator: "#", maxSplits: 1).first ?? ""), in: ncxDir)
                if names[key] == nil, !label.isEmpty { names[key] = label }
            }
        }

        var body = ""
        var chapters: [ImportedText.Chapter] = []
        for (n, idref) in spine.enumerated() {
            guard let item = manifest[idref], item.type.contains("html") || item.href.lowercased().hasSuffix("html"),
                  let xhtml = try? zip.read(item.href) else { continue }
            let html = HTMLText.decode(xhtml)
            let doc = HTMLText.parse(html)
            let paras = HTMLText.paragraphs(of: doc.first("body") ?? doc)
            guard !paras.isEmpty else { continue }
            let text = normalise(paras.joined(separator: "\n\n"))
            guard !text.isEmpty else { continue }
            if !body.isEmpty { body += "\n\n" }
            let name = names[item.href] ?? HTMLText.firstHeading(html) ?? "Chapter \(n + 1)"
            chapters.append(.init(title: name, offset: body.utf8.count))
            body += text
        }
        guard !body.isEmpty else { throw TextImportError.empty }
        // A one-chapter book doesn't need a chapter list.
        if chapters.count == 1 { chapters = [] }
        let title = (bookTitle?.isEmpty == false ? bookTitle : nil) ?? fallbackTitle.map(cleanFileName) ?? firstWords(body)
        return ImportedText(title: title, body: body, chapters: chapters, kind: .epub, origin: fallbackTitle)
    }

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
