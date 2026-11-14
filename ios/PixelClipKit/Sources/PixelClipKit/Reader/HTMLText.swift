import Foundation

/// A forgiving HTML/XHTML parser and the text extraction the reader needs: entity decoding, block
/// structure → paragraphs, and a Readability-style main-content pick (paragraph scoring with link
/// density, unlikely-candidate removal, sibling joining). No WebKit, no third-party code.
public enum HTMLText {

    // MARK: DOM

    final class Node {
        let name: String            // lower-case tag, "" for text
        var attrs: [String: String]
        var text: String
        var children: [Node] = []
        weak var parent: Node?
        var score: Double = 0
        var scored = false

        init(name: String, attrs: [String: String] = [:], text: String = "") {
            self.name = name; self.attrs = attrs; self.text = text
        }

        var isText: Bool { name.isEmpty }

        func append(_ n: Node) { n.parent = self; children.append(n) }

        func remove() {
            parent?.children.removeAll { $0 === self }
            parent = nil
        }

        /// Every element below (pre-order).
        func elements() -> [Node] {
            var out: [Node] = []
            var stack = Array(children.reversed())
            while let n = stack.popLast() {
                guard !n.isText else { continue }
                out.append(n)
                stack.append(contentsOf: n.children.reversed())
            }
            return out
        }

        func first(_ tag: String) -> Node? { elements().first { $0.name == tag } }

        /// Raw text below, whitespace collapsed.
        var innerText: String {
            var s = ""
            collect(&s)
            return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }

        private func collect(_ s: inout String) {
            if isText { s += text; s += " "; return }
            if name == "br" { s += " " }
            for c in children { c.collect(&s) }
        }

        var classAndID: String { ((attrs["class"] ?? "") + " " + (attrs["id"] ?? "")).lowercased() }
    }

    static let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param",
                                        "source", "track", "wbr", "keygen", "command"]
    static let rawTextTags: Set<String> = ["script", "style", "textarea", "title", "noscript", "template", "xmp", "iframe"]
    static let blockTags: Set<String> = ["p", "div", "section", "article", "header", "footer", "main", "aside", "nav", "h1", "h2", "h3",
                                         "h4", "h5", "h6", "ul", "ol", "li", "dl", "dt", "dd", "blockquote", "pre", "figure",
                                         "figcaption", "table", "thead", "tbody", "tfoot", "tr", "td", "th", "address", "hr", "form",
                                         "fieldset", "details", "summary", "center", "body", "html", "caption", "hgroup", "picture"]
    /// Opening one of these closes an open `<p>`.
    static let closesP: Set<String> = ["p", "div", "section", "article", "header", "footer", "main", "aside", "nav", "h1", "h2", "h3",
                                       "h4", "h5", "h6", "ul", "ol", "dl", "blockquote", "pre", "figure", "table", "address", "hr",
                                       "form", "fieldset", "details", "center", "hgroup"]

    /// Parses into a tree rooted at a synthetic `#document` node.
    static func parse(_ html: String) -> Node {
        let root = Node(name: "#document")
        var stack: [Node] = [root]
        let b = Array(html.utf8)
        let n = b.count
        var i = 0
        var textStart = 0

        func str(_ a: Int, _ z: Int) -> String { String(decoding: b[a..<z], as: UTF8.self) }
        func flushText(_ upTo: Int) {
            if upTo > textStart {
                let t = str(textStart, upTo)
                if !t.isEmpty { stack.last!.append(Node(name: "", text: decodeEntities(t))) }
            }
        }
        func lower(_ c: UInt8) -> UInt8 { (c >= 65 && c <= 90) ? c + 32 : c }
        func isNameChar(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45 || c == 58 || c == 95 }
        func startsWith(_ s: String, at k: Int) -> Bool {
            let u = Array(s.utf8)
            guard k + u.count <= n else { return false }
            for (j, c) in u.enumerated() where lower(b[k + j]) != c { return false }
            return true
        }
        func find(_ s: String, from k: Int) -> Int? {
            var j = k
            let first = s.utf8.first!
            while j < n {
                if lower(b[j]) == first, startsWith(s, at: j) { return j }
                j += 1
            }
            return nil
        }
        func closeTo(_ tag: String) {
            guard let idx = stack.lastIndex(where: { $0.name == tag }), idx > 0 else { return }
            stack.removeSubrange(idx...)
        }

        while i < n {
            guard b[i] == 0x3C, i + 1 < n else { i += 1; continue }   // '<'
            let c = b[i + 1]
            if c == 0x21 {   // <!
                flushText(i)
                if startsWith("<!--", at: i) {
                    i = (find("-->", from: i + 4).map { $0 + 3 }) ?? n
                } else if startsWith("<![cdata[", at: i) {
                    let end = find("]]>", from: i + 9) ?? n
                    stack.last!.append(Node(name: "", text: str(i + 9, end)))
                    i = min(n, end + 3)
                } else {
                    i = (find(">", from: i).map { $0 + 1 }) ?? n
                }
                textStart = i
                continue
            }
            if c == 0x3F {   // <?
                flushText(i)
                i = (find(">", from: i).map { $0 + 1 }) ?? n
                textStart = i
                continue
            }
            let closing = c == 0x2F
            var j = i + (closing ? 2 : 1)
            guard j < n, (b[j] >= 65 && b[j] <= 90) || (b[j] >= 97 && b[j] <= 122) else { i += 1; continue }
            flushText(i)
            let nameStart = j
            while j < n, isNameChar(b[j]) { j += 1 }
            var name = str(nameStart, j).lowercased()
            if let colon = name.lastIndex(of: ":") { name = String(name[name.index(after: colon)...]) }   // xhtml:p, epub:…
            // Attributes.
            var attrs: [String: String] = [:]
            var selfClosing = false
            while j < n, b[j] != 0x3E {
                if b[j] == 0x2F { selfClosing = true; j += 1; continue }
                if b[j] <= 0x20 { j += 1; continue }
                let a0 = j
                while j < n, b[j] > 0x20, b[j] != 0x3D, b[j] != 0x3E, b[j] != 0x2F { j += 1 }
                let key = str(a0, j).lowercased()
                while j < n, b[j] <= 0x20 { j += 1 }
                var value = ""
                if j < n, b[j] == 0x3D {
                    j += 1
                    while j < n, b[j] <= 0x20 { j += 1 }
                    if j < n, b[j] == 0x22 || b[j] == 0x27 {
                        let q = b[j]
                        let v0 = j + 1
                        j = v0
                        while j < n, b[j] != q { j += 1 }
                        value = str(v0, min(j, n))
                        j += 1
                    } else {
                        let v0 = j
                        while j < n, b[j] > 0x20, b[j] != 0x3E { j += 1 }
                        value = str(v0, j)
                    }
                    selfClosing = false
                }
                if !key.isEmpty, attrs[key] == nil { attrs[key] = decodeEntities(value) }
            }
            i = min(n, j + 1)
            textStart = i
            if closing {
                if name == "p", !stack.contains(where: { $0.name == "p" }) { continue }
                closeTo(name)
                continue
            }
            // Implied end tags.
            if closesP.contains(name), stack.last?.name == "p" { stack.removeLast() }
            if name == "li", let k = stack.lastIndex(where: { ["li", "ul", "ol"].contains($0.name) }), stack[k].name == "li" { stack.removeSubrange(k...) }
            if ["dt", "dd"].contains(name), let k = stack.lastIndex(where: { ["dt", "dd", "dl"].contains($0.name) }), stack[k].name != "dl" { stack.removeSubrange(k...) }
            if ["td", "th"].contains(name), let k = stack.lastIndex(where: { ["td", "th", "tr", "table"].contains($0.name) }),
               ["td", "th"].contains(stack[k].name) { stack.removeSubrange(k...) }
            if name == "tr", let k = stack.lastIndex(where: { ["tr", "table"].contains($0.name) }), stack[k].name == "tr" { stack.removeSubrange(k...) }
            if name == "option", stack.last?.name == "option" { stack.removeLast() }
            let node = Node(name: name, attrs: attrs)
            stack.last!.append(node)
            if voidTags.contains(name) || selfClosing { continue }
            if rawTextTags.contains(name) {
                let end = find("</\(name)", from: i) ?? n
                if end > i {
                    let raw = str(i, end)
                    node.append(Node(name: "", text: name == "title" || name == "textarea" ? decodeEntities(raw) : raw))
                }
                i = (find(">", from: end).map { $0 + 1 }) ?? n
                textStart = i
                continue
            }
            stack.append(node)
        }
        flushText(n)
        return root
    }

    // MARK: Entities

    /// Latin-1 named entities, U+00A0…U+00FF in order.
    static let latin1Names = ["nbsp", "iexcl", "cent", "pound", "curren", "yen", "brvbar", "sect", "uml", "copy", "ordf", "laquo",
                              "not", "shy", "reg", "macr", "deg", "plusmn", "sup2", "sup3", "acute", "micro", "para", "middot",
                              "cedil", "sup1", "ordm", "raquo", "frac14", "frac12", "frac34", "iquest", "Agrave", "Aacute",
                              "Acirc", "Atilde", "Auml", "Aring", "AElig", "Ccedil", "Egrave", "Eacute", "Ecirc", "Euml", "Igrave",
                              "Iacute", "Icirc", "Iuml", "ETH", "Ntilde", "Ograve", "Oacute", "Ocirc", "Otilde", "Ouml", "times",
                              "Oslash", "Ugrave", "Uacute", "Ucirc", "Uuml", "Yacute", "THORN", "szlig", "agrave", "aacute",
                              "acirc", "atilde", "auml", "aring", "aelig", "ccedil", "egrave", "eacute", "ecirc", "euml", "igrave",
                              "iacute", "icirc", "iuml", "eth", "ntilde", "ograve", "oacute", "ocirc", "otilde", "ouml", "divide",
                              "oslash", "ugrave", "uacute", "ucirc", "uuml", "yacute", "thorn", "yuml"]

    static let entities: [String: String] = {
        var m: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
                                   "OElig": "Œ", "oelig": "œ", "Yuml": "Ÿ", "Scaron": "Š", "scaron": "š", "fnof": "ƒ",
                                   "circ": "ˆ", "tilde": "˜", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
                                   "zwnj": "\u{200C}", "zwj": "\u{200D}", "lrm": "", "rlm": "", "ndash": "–", "mdash": "—",
                                   "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
                                   "dagger": "†", "Dagger": "‡", "bull": "•", "hellip": "…", "permil": "‰", "prime": "′",
                                   "Prime": "″", "lsaquo": "‹", "rsaquo": "›", "euro": "€", "trade": "™", "larr": "←",
                                   "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔", "minus": "−", "nnbsp": "\u{202F}",
                                   "NonBreakingSpace": "\u{00A0}", "hyphen": "‐", "dash": "‐"]
        for (k, name) in latin1Names.enumerated() { m[name] = String(Character(Unicode.Scalar(0xA0 + k)!)) }
        return m
    }()

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c == "&" else { out.append(c); i = s.index(after: i); continue }
            // Up to 32 characters to the ';'.
            var j = s.index(after: i)
            var name = ""
            var found = false
            while j < s.endIndex, name.count <= 32 {
                let d = s[j]
                if d == ";" { found = true; break }
                if !(d.isLetter || d.isNumber || d == "#") { break }
                name.append(d)
                j = s.index(after: j)
            }
            var replacement: String?
            if name.hasPrefix("#") {
                let digits = name.dropFirst()
                let v = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                if let v, let u = Unicode.Scalar(v == 0 ? 0xFFFD : Self.windows1252(v)) { replacement = String(Character(u)) }
            } else if !name.isEmpty {
                replacement = entities[name]
            }
            if let r = replacement {
                out += r
                i = found ? s.index(after: j) : j
            } else {
                out.append(c)
                i = s.index(after: i)
            }
        }
        return out
    }

    /// `&#150;` and friends mean Windows-1252 in the wild.
    static func windows1252(_ v: UInt32) -> UInt32 {
        let map: [UInt32: UInt32] = [0x80: 0x20AC, 0x82: 0x201A, 0x84: 0x201E, 0x85: 0x2026, 0x8C: 0x0152, 0x91: 0x2018,
                                     0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
                                     0x99: 0x2122, 0x9C: 0x0153, 0x9F: 0x0178]
        return map[v] ?? v
    }

    // MARK: Text

    /// Paragraph text of a node: blocks become paragraphs (joined by a blank line), `<br>` a line break,
    /// runs of whitespace one space (except in `<pre>`).
    static func paragraphs(of node: Node, skipHeadings: Bool = false) -> [String] {
        var paras: [String] = []
        var cur = ""
        func flush() {
            let lines = cur.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let t = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { paras.append(t) }
            cur = ""
        }
        func walk(_ n: Node, pre: Bool) {
            if n.isText {
                if pre { cur += n.text; return }
                var collapsed = ""
                var lastSpace = cur.last.map { $0 == " " || $0 == "\n" } ?? true
                for ch in n.text {
                    if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == "\u{0C}" {
                        if !lastSpace { collapsed.append(" "); lastSpace = true }
                    } else {
                        collapsed.append(ch); lastSpace = false
                    }
                }
                cur += collapsed
                return
            }
            switch n.name {
            case "script", "style", "noscript", "template", "head", "title", "svg", "math", "iframe", "button", "select",
                 "textarea", "input", "img", "video", "audio", "canvas", "object", "embed", "rt", "rp":
                return
            case "br":
                cur += "\n"
                return
            case "hr":
                flush()
                return
            default: break
            }
            if skipHeadings, ["h1", "h2", "h3", "h4", "h5", "h6"].contains(n.name) { return }
            let block = blockTags.contains(n.name)
            if block { flush() }
            for c in n.children { walk(c, pre: pre || n.name == "pre") }
            if block { flush() }
        }
        walk(node, pre: false)
        flush()
        return paras
    }

    /// All the readable text of an HTML document (or fragment), paragraphs separated by a blank line.
    public static func text(_ html: String) -> String {
        let doc = parse(html)
        let body = doc.first("body") ?? doc
        return paragraphs(of: body).joined(separator: "\n\n")
    }

    /// The first heading's text (EPUB chapter names).
    public static func firstHeading(_ html: String) -> String? {
        let doc = parse(html)
        for tag in ["h1", "h2", "h3"] {
            if let h = doc.first(tag)?.innerText, !h.isEmpty { return h }
        }
        return nil
    }

    // MARK: Readability

    public struct Article: Sendable, Equatable {
        public var title: String
        public var text: String
        /// Site name from `og:site_name` (or the host), when known.
        public var site: String?
    }

    static let unlikelyTags: Set<String> = ["script", "style", "noscript", "iframe", "nav", "header", "footer", "aside", "form",
                                            "button", "input", "select", "textarea", "svg", "canvas", "video", "audio", "figure",
                                            "picture", "template", "dialog", "menu", "object", "embed", "head"]
    static let negativeHints = ["comment", "footer", "footnote", "sidebar", "sponsor", "advert", "promo", "related", "share",
                                "social", "navbar", "nav-", "menu", "breadcrumb", "cookie", "consent", "banner", "popup",
                                "modal", "newsletter", "subscribe", "signup", "widget", "masthead", "toolbar", "outbrain",
                                "taboola", "recommend", "paywall", "skip-link", "meta-", "byline", "tags",
                                "author-bio", "pagination", "pager", "advertisement", "hatnote", "navbox", "infobox", "mw-editsection",
                                "noprint", "reflist", "reference", "printfooter", "catlinks"]
    /// Whole class/id tokens that mark ads ("ad-" as a substring would also hit "head-line").
    static let negativeTokens: Set<String> = ["ad", "ads", "adv", "sponsored", "dfp", "gpt"]

    static func isNegative(_ s: String) -> Bool {
        if negativeHints.contains(where: { s.contains($0) }) { return true }
        return s.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).contains { negativeTokens.contains(String($0)) }
    }
    static let positiveHints = ["article", "body", "content", "entry", "main", "post", "text", "blog", "story", "prose", "chapter",
                                "page"]

    static func classWeight(_ n: Node) -> Double {
        let s = n.classAndID
        guard !s.trimmingCharacters(in: .whitespaces).isEmpty else { return 0 }
        var w = 0.0
        if isNegative(s) { w -= 25 }
        if positiveHints.contains(where: { s.contains($0) }) { w += 25 }
        return w
    }

    static func linkDensity(_ n: Node) -> Double {
        let total = n.innerText.count
        guard total > 0 else { return 0 }
        let links = n.elements().filter { $0.name == "a" }.reduce(0) { $0 + $1.innerText.count }
        return min(1, Double(links) / Double(total))
    }

    static func meta(_ doc: Node, _ keys: [String]) -> String? {
        for m in doc.elements() where m.name == "meta" {
            let k = (m.attrs["property"] ?? m.attrs["name"] ?? "").lowercased()
            if keys.contains(k), let v = m.attrs["content"]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        }
        return nil
    }

    /// The page's title: `og:title`, else the first `<h1>`, else `<title>` minus a " | Site" suffix.
    static func title(_ doc: Node) -> String {
        let h1 = doc.first("h1")?.innerText ?? ""
        if let og = meta(doc, ["og:title", "twitter:title"]) {
            // "Train de nuit — Wikipédia": the page's own heading without the site's name.
            if h1.count >= 3, og.count > h1.count, og.hasPrefix(h1) { return h1 }
            return og
        }
        let titleTag = doc.first("title")?.innerText ?? ""
        if !h1.isEmpty, h1.count < 200 { return h1 }
        for sep in [" | ", " – ", " — ", " - ", " · ", " :: "] {
            if let r = titleTag.range(of: sep, options: .backwards) {
                let head = String(titleTag[..<r.lowerBound])
                if head.split(separator: " ").count >= 2 { return head }
            }
        }
        return titleTag
    }

    /// The main content of a web page, as reader text.
    public static func article(_ html: String, url: URL? = nil) -> Article {
        let doc = parse(html)
        let pageTitle = title(doc).trimmingCharacters(in: .whitespacesAndNewlines)
        let site = meta(doc, ["og:site_name", "application-name"]) ?? url?.host
        let body = doc.first("body") ?? doc

        // 1. Unlikely candidates out.
        for e in body.elements() {
            guard e.parent != nil else { continue }
            if unlikelyTags.contains(e.name) { e.remove(); continue }
            if ["body", "html", "article", "main"].contains(e.name) { continue }
            let role = (e.attrs["role"] ?? "").lowercased()
            if ["navigation", "banner", "contentinfo", "complementary", "dialog", "alert", "menu"].contains(role) { e.remove(); continue }
            // `hidden="until-found"` (collapsed sections, e.g. mobile Wikipedia) is findable, readable text.
            if e.attrs["aria-hidden"] == "true" || (e.attrs["hidden"] != nil && e.attrs["hidden"] != "until-found") { e.remove(); continue }
            let s = e.classAndID
            if isNegative(s) && !positiveHints.contains(where: { s.contains($0) }) { e.remove() }
        }

        // 2. Score paragraphs into their parents and grandparents.
        var candidates: [Node] = []
        func initialize(_ n: Node) {
            guard !n.scored else { return }
            n.scored = true
            switch n.name {
            case "article": n.score = 25
            case "main": n.score = 15
            case "div": n.score = 5
            case "pre", "td", "blockquote": n.score = 3
            case "address", "ol", "ul", "dl", "dd", "dt", "li", "form": n.score = -3
            case "h1", "h2", "h3", "h4", "h5", "h6", "th": n.score = -5
            default: n.score = 0
            }
            n.score += classWeight(n)
            if n.attrs["itemprop"]?.lowercased().contains("articlebody") == true { n.score += 25 }
            candidates.append(n)
        }
        for e in body.elements() {
            let isParagraphLike: Bool
            switch e.name {
            case "p", "pre", "td", "blockquote": isParagraphLike = true
            case "div": isParagraphLike = !e.children.contains { !$0.isText && blockTags.contains($0.name) }
            default: isParagraphLike = false
            }
            guard isParagraphLike else { continue }
            let t = e.innerText
            guard t.count >= 25, let parent = e.parent else { continue }
            let commas = t.filter { $0 == "," || $0 == "，" || $0 == "、" }.count
            let s = 1 + Double(commas) + min(3, Double(t.count) / 100)
            initialize(parent)
            parent.score += s
            if let gp = parent.parent, gp !== doc {
                initialize(gp)
                gp.score += s / 2
            }
        }
        for c in candidates { c.score *= 1 - linkDensity(c) }
        guard let top = candidates.max(by: { $0.score < $1.score }), top.score > 0 else {
            return Article(title: pageTitle, text: tidy(paragraphs(of: body), title: pageTitle), site: site)
        }

        // 3. Join siblings that look like part of the same article.
        var picked: [Node] = [top]
        if let parent = top.parent {
            let threshold = max(10, top.score * 0.2)
            picked = parent.children.filter { sib in
                if sib === top { return true }
                guard !sib.isText else { return false }
                if sib.scored && sib.score >= threshold { return true }
                if sib.name == "p" {
                    let t = sib.innerText, ld = linkDensity(sib)
                    if t.count > 80 && ld < 0.25 { return true }
                    if t.count > 0 && t.count <= 80 && ld == 0 && t.contains(". ") { return true }
                }
                return false
            }
        }
        var paras = picked.flatMap { paragraphs(of: $0) }
        // Too little? Fall back to the whole body.
        if paras.joined().count < 200 { paras = paragraphs(of: body) }
        return Article(title: pageTitle, text: tidy(paras, title: pageTitle), site: site)
    }

    /// Drops a leading paragraph that repeats the title and one-word crumbs.
    static func tidy(_ paras: [String], title: String) -> String {
        var p = paras
        if let first = p.first, first.caseInsensitiveCompare(title) == .orderedSame { p.removeFirst() }
        return p.joined(separator: "\n\n")
    }

    // MARK: Charset

    /// Decodes HTML bytes: the HTTP charset, else a `<meta charset>` in the first 2 KB, else UTF-8,
    /// else Windows-1252.
    public static func decode(_ data: Data, contentType: String? = nil) -> String {
        func charset(in s: String) -> String? {
            guard let r = s.range(of: "charset=", options: .caseInsensitive) else { return nil }
            let rest = s[r.upperBound...].drop { $0 == "\"" || $0 == "'" || $0 == " " }
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            return name.isEmpty ? nil : name.lowercased()
        }
        let head = String(decoding: data.prefix(2048), as: UTF8.self)
        let name = contentType.flatMap(charset(in:)) ?? charset(in: head)
        if let name, name != "utf-8", name != "utf8" {
            let enc: String.Encoding? = switch name {
            case "iso-8859-1", "latin1", "latin-1": .isoLatin1
            case "windows-1252", "cp1252": .windowsCP1252
            case "iso-8859-15": .isoLatin1
            case "macintosh", "mac-roman": .macOSRoman
            case "utf-16": .utf16
            default: nil
            }
            if let enc, let s = String(data: data, encoding: enc) { return s }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }
}
