import Foundation

/// A forgiving HTML/XHTML parser and the text extraction the reader needs: entity decoding, block
/// structure → paragraphs, and a Readability-style main-content pick (paragraph scoring with link
/// density, unlikely-candidate removal, sibling joining). No WebKit, no third-party code.
public enum HTMLText {

    // MARK: DOM

    /// Limits that keep a hostile page from costing more than a slow import (a browser's own parser
    /// stops nesting at 512 levels too; real articles are a few hundred KB and tens of thousands of nodes).
    public enum Limits {
        /// Bytes of HTML read; the rest of a longer document is ignored.
        public static let maxInputBytes = 12 << 20
        /// Open elements. Deeper ones become children of the deepest kept element.
        public static let maxDepth = 512
        /// Elements and text nodes created; parsing stops there.
        public static let maxNodes = 400_000
    }

    final class Node {
        let name: String            // lower-case tag, "" for text
        var attrs: [String: String]
        var text: String
        var children: [Node] = []
        weak var parent: Node?
        var score: Double = 0
        var scored = false
        /// Taken out by `detach()`; `sweep()` drops it from its former parent's children.
        var removed = false
        var needsSweep = false
        /// Text statistics of the subtree, filled by `HTMLText.measure`: non-blank characters, words,
        /// commas, and the summed `textLength` of every `<a>` below.
        var textChars = 0, textTokens = 0, commas = 0, linkLength = 0

        init(name: String, attrs: [String: String] = [:], text: String = "") {
            self.name = name; self.attrs = attrs; self.text = text
        }

        var isText: Bool { name.isEmpty }

        func append(_ n: Node) { n.parent = self; children.append(n) }

        /// Takes this node out of the tree. The parent's child list is cleaned once, by `sweep()`
        /// (removing each node from the array as it goes was quadratic in the number of siblings).
        func detach(_ dirty: inout [Node]) {
            guard let p = parent else { return }
            removed = true
            parent = nil
            if !p.needsSweep { p.needsSweep = true; dirty.append(p) }
        }

        func sweep() {
            children.removeAll { $0.removed }
            needsSweep = false
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

        /// The first element below (pre-order) that satisfies `match`, looking at no more than `maxNodes` nodes.
        func firstElement(maxNodes: Int = .max, where match: (Node) -> Bool) -> Node? {
            var stack = Array(children.reversed())
            var seen = 0
            while let n = stack.popLast() {
                seen += 1
                if seen > maxNodes { return nil }
                guard !n.isText else { continue }
                if match(n) { return n }
                stack.append(contentsOf: n.children.reversed())
            }
            return nil
        }

        func first(_ tag: String) -> Node? { firstElement { $0.name == tag } }

        /// Raw text below, whitespace collapsed. `maxNodes` bounds the walk (labels only need the start).
        func innerText(maxNodes: Int) -> String {
            var s = ""
            var stack: [Node] = [self]
            var seen = 0
            while let n = stack.popLast() {
                seen += 1
                if seen > maxNodes { break }
                if n.isText { s += n.text; s += " "; continue }
                if n.name == "br" { s += " " }
                stack.append(contentsOf: n.children.reversed())
            }
            return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }

        var innerText: String { innerText(maxNodes: .max) }

        /// `innerText.count` without building the text (after `HTMLText.measure`).
        var textLength: Int { textChars + max(0, textTokens - 1) }

        var classAndID: String { ((attrs["class"] ?? "") + " " + (attrs["id"] ?? "")).lowercased() }
    }

    /// Fills the text statistics of `root` and everything below it, bottom-up in one pass, so the
    /// scoring never re-reads a subtree per candidate.
    static func measure(_ root: Node) {
        var work: [(node: Node, done: Bool)] = [(root, false)]
        while let (n, done) = work.popLast() {
            if n.isText {
                var tokens = 0, chars = 0, commas = 0, inToken = false
                for ch in n.text {
                    if ch.isWhitespace { inToken = false; continue }
                    if !inToken { tokens += 1; inToken = true }
                    chars += 1
                    if ch == "," || ch == "，" || ch == "、" { commas += 1 }
                }
                n.textChars = chars; n.textTokens = tokens; n.commas = commas; n.linkLength = 0
            } else if !done {
                work.append((n, true))
                for c in n.children { work.append((c, false)) }
            } else {
                var chars = 0, tokens = 0, commas = 0, links = 0
                for c in n.children {
                    chars += c.textChars; tokens += c.textTokens; commas += c.commas
                    links += c.linkLength + (c.name == "a" ? c.textLength : 0)
                }
                n.textChars = chars; n.textTokens = tokens; n.commas = commas; n.linkLength = links
            }
        }
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

    /// Parses into a tree rooted at a synthetic `#document` node. Linear in the input: the open
    /// elements are indexed by tag, so no end tag or implied end tag scans the stack; nesting, node count
    /// and input size are bounded by `Limits`.
    static func parse(_ html: String) -> Node {
        let root = Node(name: "#document")
        var stack: [Node] = [root]
        /// Tag → the positions in `stack` of its open elements, ascending.
        var openAt: [String: [Int]] = [:]
        /// Elements opened past `Limits.maxDepth`: not on the stack, so their end tags are swallowed here.
        var overflow = 0
        var nodes = 0
        let b = Array(html.utf8.prefix(Limits.maxInputBytes))
        let n = b.count
        var i = 0
        var textStart = 0

        func str(_ a: Int, _ z: Int) -> String { String(decoding: b[a..<z], as: UTF8.self) }
        func flushText(_ upTo: Int) {
            if upTo > textStart {
                let t = str(textStart, upTo)
                if !t.isEmpty { stack.last!.append(Node(name: "", text: decodeEntities(t))); nodes += 1 }
            }
        }
        func lower(_ c: UInt8) -> UInt8 { (c >= 65 && c <= 90) ? c + 32 : c }
        func isNameChar(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45 || c == 58 || c == 95 }
        func startsWith(_ u: [UInt8], at k: Int) -> Bool {
            guard k + u.count <= n else { return false }
            for (j, c) in u.enumerated() where lower(b[k + j]) != c { return false }
            return true
        }
        func find(_ s: String, from k: Int) -> Int? {
            let u = Array(s.utf8)
            var j = k
            let first = u[0]
            while j < n {
                if lower(b[j]) == first, startsWith(u, at: j) { return j }
                j += 1
            }
            return nil
        }
        func push(_ node: Node) {
            openAt[node.name, default: []].append(stack.count)
            stack.append(node)
        }
        /// Closes every open element from position `idx` up.
        func pop(to idx: Int) {
            while stack.count > idx {
                let top = stack.removeLast()
                openAt[top.name]?.removeLast()
            }
        }
        /// The innermost open element with one of these tags.
        func lastOpen(_ names: [String]) -> Int? { names.compactMap { openAt[$0]?.last }.max() }
        func closeTo(_ tag: String) {
            guard let idx = openAt[tag]?.last, idx > 0 else { return }
            pop(to: idx)
        }
        let comment = Array("<!--".utf8), cdata = Array("<![cdata[".utf8)

        while i < n, nodes < Limits.maxNodes {
            guard b[i] == 0x3C, i + 1 < n else { i += 1; continue }   // '<'
            let c = b[i + 1]
            if c == 0x21 {   // <!
                flushText(i)
                if startsWith(comment, at: i) {
                    i = (find("-->", from: i + 4).map { $0 + 3 }) ?? n
                } else if startsWith(cdata, at: i) {
                    let end = find("]]>", from: i + 9) ?? n
                    stack.last!.append(Node(name: "", text: str(i + 9, end)))
                    nodes += 1
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
                if overflow > 0 { overflow -= 1; continue }
                closeTo(name)   // an end tag with nothing open to match (a stray </p>) does nothing
                continue
            }
            // Implied end tags.
            if closesP.contains(name), stack.last?.name == "p" { pop(to: stack.count - 1) }
            if name == "li", let k = lastOpen(["li", "ul", "ol"]), stack[k].name == "li" { pop(to: k) }
            if name == "dt" || name == "dd", let k = lastOpen(["dt", "dd", "dl"]), stack[k].name != "dl" { pop(to: k) }
            if name == "td" || name == "th", let k = lastOpen(["td", "th", "tr", "table"]),
               stack[k].name == "td" || stack[k].name == "th" { pop(to: k) }
            if name == "tr", let k = lastOpen(["tr", "table"]), stack[k].name == "tr" { pop(to: k) }
            if name == "option", stack.last?.name == "option" { pop(to: stack.count - 1) }
            let node = Node(name: name, attrs: attrs)
            stack.last!.append(node)
            nodes += 1
            if voidTags.contains(name) || selfClosing { continue }
            if rawTextTags.contains(name) {
                let end = find("</\(name)", from: i) ?? n
                if end > i {
                    let raw = str(i, end)
                    node.append(Node(name: "", text: name == "title" || name == "textarea" ? decodeEntities(raw) : raw))
                    nodes += 1
                }
                i = (find(">", from: end).map { $0 + 1 }) ?? n
                textStart = i
                continue
            }
            // Too deep to nest further: it stays a child of the deepest element, and so does what it holds.
            if stack.count >= Limits.maxDepth { overflow += 1; continue }
            push(node)
        }
        if nodes < Limits.maxNodes { flushText(n) }
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
        // An explicit stack instead of recursion: the depth of a page never reaches the call stack.
        var work: [(node: Node, pre: Bool, closesBlock: Bool)] = [(node, false, false)]
        while let (n, pre, closesBlock) = work.popLast() {
            if closesBlock { flush(); continue }
            if n.isText {
                if pre { cur += n.text; continue }
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
                continue
            }
            switch n.name {
            case "script", "style", "noscript", "template", "head", "title", "svg", "math", "iframe", "button", "select",
                 "textarea", "input", "img", "video", "audio", "canvas", "object", "embed", "rt", "rp":
                continue
            case "br":
                cur += "\n"
                continue
            case "hr":
                flush()
                continue
            default: break
            }
            if skipHeadings, ["h1", "h2", "h3", "h4", "h5", "h6"].contains(n.name) { continue }
            let block = blockTags.contains(n.name)
            if block { flush(); work.append((n, pre, true)) }
            let inPre = pre || n.name == "pre"
            for c in n.children.reversed() { work.append((c, inPre, false)) }
        }
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
    public static func firstHeading(_ html: String) -> String? { firstHeading(in: parse(html)) }

    static func firstHeading(in doc: Node) -> String? {
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

    /// The share of a node's text that sits in links (after `measure`).
    static func linkDensity(_ n: Node) -> Double {
        let total = n.textLength
        guard total > 0 else { return 0 }
        return min(1, Double(n.linkLength) / Double(total))
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
        var dirty: [Node] = []
        for e in body.elements() {
            guard e.parent != nil else { continue }
            if unlikelyTags.contains(e.name) { e.detach(&dirty); continue }
            if ["body", "html", "article", "main"].contains(e.name) { continue }
            let role = (e.attrs["role"] ?? "").lowercased()
            if ["navigation", "banner", "contentinfo", "complementary", "dialog", "alert", "menu"].contains(role) { e.detach(&dirty); continue }
            // `hidden="until-found"` (collapsed sections, e.g. mobile Wikipedia) is findable, readable text.
            if e.attrs["aria-hidden"] == "true" || (e.attrs["hidden"] != nil && e.attrs["hidden"] != "until-found") { e.detach(&dirty); continue }
            let s = e.classAndID
            if isNegative(s) && !positiveHints.contains(where: { s.contains($0) }) { e.detach(&dirty) }
        }
        for parent in dirty { parent.sweep() }
        // Text lengths, commas and link text of every subtree, once.
        measure(doc)

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
            let length = e.textLength
            guard length >= 25, let parent = e.parent else { continue }
            let s = 1 + Double(e.commas) + min(3, Double(length) / 100)
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
                    let length = sib.textLength, ld = linkDensity(sib)
                    if length > 80 && ld < 0.25 { return true }
                    if length > 0 && length <= 80 && ld == 0 && sib.innerText.contains(". ") { return true }
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
