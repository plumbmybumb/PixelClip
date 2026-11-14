import Accelerate
import CoreGraphics
import CoreText
import Foundation

/// Renders the four oracle assets (PROTOCOL §5f "Assets") the clip composes its screens from:
/// - **deck** `D` (108×206, shared by both languages; D, K and N carry the glyph-atlas flag): frame 0 the back, 1+i card i;
/// - **text** `T` (536×240, per language): frame 0 **waits** ("la carte attend"), then per card its face
///   info `F` (numeral, printed name, keyword), its question `Q` ("Le Tarot te demande : …") and `pages`
///   reading pages `R`; every frame leaves the card slot (x 40, y 21, 104×198) black, framed by a 1-px
///   warm border just outside it;
/// - **keys** `K` (160×34, §5f.12): card i's keyword, white, centred;
/// - **notes** `N` (536×72): card i's number note, the numeral first, on one or two lines.
///
/// The card pictures are downscaled from 236×448 to 104×198 with vImage's high-quality (Lanczos)
/// resampling and error-diffusion dithered to RGB565, so the cream paper and the reds don't band;
/// everything else is flat colour and antialiased text rounded to the nearest RGB565 value.
///
/// Text never overflows: every line is measured with its real ink and the sizes shrink until it fits
/// (names, keywords and questions may take more than one line; the reading takes 3–4 lines per page,
/// down to `minBodySize`, below which it is allowed more lines and, only as a last resort, cut with "…").
public enum TarotRenderer {
    // MARK: Geometry (y down)

    /// The card slot of every text frame.
    public static let slotRect = CGRect(x: Oracle.slot.x, y: Oracle.slot.y, width: Oracle.slot.w, height: Oracle.slot.h)
    /// The text column right of the slot (face info, question, waits prompt).
    public static let column = CGRect(x: 166, y: 12, width: 352, height: 216)
    /// The reading's text area (the page marks sit right of it).
    public static let readingArea = CGRect(x: 168, y: 14, width: 338, height: 212)
    /// Reading pages per card in the assets the app makes.
    public static let pages = 2

    // MARK: Look

    public static let accent = RGBAColor(hex: BrandPalette.primary)   // #C6A2FF
    /// The slot's 1-px border and the face's keyword: warm gold.
    public static let warm = RGBAColor(hex: 0xD8B67A)
    public static let ink = RGBAColor(hex: 0xF4F1FA)
    public static let secondary = RGBAColor(hex: 0xA99CC2)
    public static let dim = RGBAColor(hex: 0x6E6287)
    /// Page marks on the reading pages.
    static let markOn = RGBAColor(hex: 0xC6A2FF), markOff = RGBAColor(hex: 0x3A3150)

    static let maxBodySize: CGFloat = 24
    public static let minBodySize: CGFloat = 15
    static let maxLinesPerPage = 4
    static let lineSpacing: CGFloat = 1.27
    /// The note's face relative to the body's (only when a reading page carries a note).
    static let noteScale: CGFloat = 0.74
    static let minNoteSize: CGFloat = 13

    /// The faces: Playfair Display (OFL, bundled), in the weights each part needs.
    public struct Fonts: @unchecked Sendable {
        public var numeral: CTFont
        public var name: CTFont
        public var keyword: CTFont
        public var body: CTFont
        public var note: CTFont
        public var prompt: CTFont

        public init(numeral: CTFont, name: CTFont, keyword: CTFont, body: CTFont, note: CTFont, prompt: CTFont) {
            self.numeral = numeral; self.name = name; self.keyword = keyword; self.body = body; self.note = note; self.prompt = prompt
        }

        public static let familyID = "playfair-display"

        /// Playfair Display Bold numeral, SemiBold name, Medium Italic keyword and prompt, Regular body,
        /// Italic note (the fonts must be registered: UIAppFonts in the app, `CTFontManager` in tests).
        public static func bundled() -> Fonts {
            func f(_ w: Double, italic: Bool = false) -> CTFont {
                FontCatalog.ctFont(for: FontSelection(familyID: familyID, weight: w, italic: italic), size: 40)
            }
            return Fonts(numeral: f(0.4), name: f(0.3), keyword: f(0.23, italic: true), body: f(0.0), note: f(0.0, italic: true),
                         prompt: f(0.23, italic: true))
        }
    }

    public enum Error: Swift.Error, Equatable { case cardCount(Int), noCards }

    // MARK: The four assets

    /// One language's assets, decoded (what the clip composes from) and encoded (what is uploaded).
    public struct Rendered: Sendable {
        public var assets: OracleCompositor.Assets
        public var deck: Data
        public var text: Data
        public var keys: Data
        public var notes: Data
        public var totalBytes: Int { deck.count + text.count + keys.count + notes.count }
    }

    /// The deck `D`: the back, then the faces (`1 + cards` frames of 104×198).
    public static func deckFrames(_ deck: TarotDeck, cards: Int? = nil) -> [RGB565Frame] {
        [cardPixels(deck.back)] + deck.faces.prefix(cards ?? deck.faces.count).map { cardPixels($0) }
    }

    /// The text asset `T`: waits, then per card F, Q and `pages` reading pages (`1 + cards × (2 + pages)`).
    public static func textFrames(_ texts: [TarotCardText], language: TarotLanguage, fonts: Fonts, pages: Int = pages) throws -> [RGB565Frame] {
        guard !texts.isEmpty else { throw Error.noCards }
        guard Oracle.cardsRange.contains(texts.count) else { throw Error.cardCount(texts.count) }
        var out = [waitsFrame(language: language, fonts: fonts)]
        for t in texts {
            out.append(faceFrame(t, fonts: fonts))
            out.append(questionFrame(t, language: language, fonts: fonts))
            let layout = readingLayout(t, fonts: fonts, pages: pages)
            for p in 0..<pages { out.append(readingFrame(layout, page: p, fonts: fonts)) }
        }
        return out
    }

    /// The keys `K` (§5f.12): one 160×34 keyword tile per card, all at one size — the largest at which the longest keyword's
    /// ink fits 140 px and the line fits 28 px — so three side by side match.
    public static func keyFrames(_ texts: [TarotCardText], fonts: Fonts) -> [RGB565Frame] {
        let size = keySize(texts.map(\.keyword), fonts: fonts)
        return texts.map { keyTile($0.keyword, fonts: fonts, size: size) }
    }

    /// The notes `N`: one 536×72 number-note tile per card, all at one size (the largest every note fits
    /// in two lines), so the three stacked in the thread match.
    public static func noteFrames(_ texts: [TarotCardText], fonts: Fonts) -> [RGB565Frame] {
        let size = texts.map { noteTileLayout($0.threadNote, fonts: fonts).size }.min() ?? 21
        return texts.map { noteTile($0.threadNote, fonts: fonts, maxSize: size) }
    }

    /// A `.hca` (RLE16, durations 0: the clip times the frames itself). `atlas`: the glyph-atlas flag,
    /// which the deck, keys and notes carry.
    public static func encode(_ frames: [RGB565Frame], atlas: Bool = false) throws -> Data {
        try HCAEncoder.encode(frames: frames.map { HCAEncoder.Frame(pixels: $0, durationMs: 0) }, glyphAtlas: atlas)
    }

    /// Everything for one language. `deckFrames` can be passed in (it's the same for both languages).
    public static func render(deck: TarotDeck, readings: TarotReadings, spec: TarotSpec, fonts: Fonts, pages: Int = pages,
                              deckFrames precomputed: [RGB565Frame]? = nil) throws -> Rendered {
        let texts = readings.texts(spec.language, edits: TarotEdits(edits: spec.edits))
        guard deck.faces.count >= texts.count else { throw Error.cardCount(texts.count) }
        let d = precomputed ?? deckFrames(deck, cards: texts.count)
        let t = try textFrames(texts, language: spec.language, fonts: fonts, pages: pages)
        let k = keyFrames(texts, fonts: fonts)
        let n = noteFrames(texts, fonts: fonts)
        return Rendered(assets: .init(deck: d, text: t, keys: k, notes: n, pages: pages),
                        deck: try encode(d, atlas: true), text: try encode(t), keys: try encode(k, atlas: true),
                        notes: try encode(n, atlas: true))
    }

    // MARK: Card pictures

    /// What the clip gets (§5f.12): the deck at 108×206 and the keys (160×34, the keyword row under the three).
    public struct Parts: Sendable {
        public var deck: Data
        public var keys: Data
        public var deckFrames: [RGB565Frame]
        public var keyFrames: [RGB565Frame]
        public var cards: Int { max(0, deckFrames.count - 1) }
        public var totalBytes: Int { deck.count + keys.count }
    }

    public static func renderParts(deck: TarotDeck, readings: TarotReadings, spec: TarotSpec, fonts: Fonts,
                                   deckFrames precomputed: [RGB565Frame]? = nil) throws -> Parts {
        let texts = readings.texts(spec.language, edits: TarotEdits(edits: spec.edits))
        guard deck.faces.count >= texts.count else { throw Error.cardCount(texts.count) }
        let d = precomputed ?? deckFrames(deck, cards: texts.count)
        let k = keyFrames(texts, fonts: fonts)
        return Parts(deck: try encode(d, atlas: true), keys: try encode(k, atlas: true), deckFrames: d, keyFrames: k)
    }

    /// A card picture at the deck's size (108×206, §5f.12), or at `size` (the old 104×198 slot of the app's previews).
    public static func cardPixels(_ image: CGImage, size: (w: Int, h: Int) = (Oracle.cardWidth, Oracle.cardHeight)) -> RGB565Frame {
        let sw = Int(TarotDeck.sourceSize.width), sh = Int(TarotDeck.sourceSize.height)
        // Normalise any source (size, colour space, alpha) to a 236×448 opaque sRGB buffer.
        let src = Raster.draw(width: sw, height: sh, background: .black) { ctx in
            let s = max(CGFloat(sw) / CGFloat(image.width), CGFloat(sh) / CGFloat(image.height))
            let w = CGFloat(image.width) * s, h = CGFloat(image.height) * s
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: (CGFloat(sw) - w) / 2, y: (CGFloat(sh) - h) / 2, width: w, height: h))
        }
        let dw = size.w, dh = size.h
        var dst = [UInt8](repeating: 0, count: dw * dh * 4)
        src.bytes.withUnsafeBytes { s in
            dst.withUnsafeMutableBytes { d in
                var inBuf = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s.baseAddress!), height: vImagePixelCount(sh),
                                          width: vImagePixelCount(sw), rowBytes: sw * 4)
                var outBuf = vImage_Buffer(data: d.baseAddress!, height: vImagePixelCount(dh), width: vImagePixelCount(dw), rowBytes: dw * 4)
                _ = vImageScale_ARGB8888(&inBuf, &outBuf, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        for i in stride(from: 3, to: dst.count, by: 4) { dst[i] = 255 }
        return ClipRenderer.quantize(RGBA8Image(width: dw, height: dh, bytes: dst), mode: .errorDiffusion)
    }

    /// A text frame: black, the slot left black inside a 1-px warm border.
    static func base(_ body: (CGContext) -> Void) -> RGB565Frame {
        let img = Raster.draw(width: ClipCanvas.width, height: ClipCanvas.height, background: .black) { ctx in
            let H = CGFloat(ClipCanvas.height)
            let b = slotRect.insetBy(dx: -1, dy: -1)
            ctx.setFillColor(warm.cgColor)
            ctx.fill(CGRect(x: b.minX, y: H - b.maxY, width: b.width, height: b.height))
            ctx.setFillColor(RGBAColor.black.cgColor)
            ctx.fill(CGRect(x: slotRect.minX, y: H - slotRect.maxY, width: slotRect.width, height: slotRect.height))
            body(ctx)
            // Nothing drawn may reach into the slot.
            ctx.setFillColor(RGBAColor.black.cgColor)
            ctx.fill(CGRect(x: slotRect.minX, y: H - slotRect.maxY, width: slotRect.width, height: slotRect.height))
        }
        return ClipRenderer.quantize(img, mode: .none)
    }

    // MARK: Waits

    public static func waitsFrame(language: TarotLanguage, fonts: Fonts) -> RGB565Frame {
        base { ctx in
            let col = column
            let prompt = fit(language.prompt, font: fonts.prompt, max: 42, min: 16, width: col.width - 8, lines: 2)
            let hint = fit(language.hint, font: fonts.note, max: 18, min: 12, width: col.width - 8, lines: 1)
            let gap: CGFloat = 14
            let total = prompt.height + gap + hint.height
            var top = col.midY - total / 2
            prompt.draw(in: ctx, centerX: col.midX, top: top, color: accent)
            top += prompt.height + gap
            hint.draw(in: ctx, centerX: col.midX, top: top, color: dim)
        }
    }

    // MARK: Question

    /// The question frame's text, laid out (tests check it stays inside the column).
    public struct QuestionLayout: Sendable {
        public var lead: Block
        public var question: Block
        public var tops: [CGFloat]
        public var inks: [CGRect] {
            zip([lead, question], tops).flatMap { b, top in b.inks(centerX: column.midX, top: top) }
        }
    }

    public static func questionLayout(_ t: TarotCardText, language: TarotLanguage, fonts: Fonts) -> QuestionLayout {
        let col = column
        let lead = fit(language.asks, font: fonts.prompt, max: 20, min: 13, width: col.width - 8, lines: 1)
        let gap: CGFloat = 16
        let room = col.height - lead.height - gap
        let q = fitParagraph(t.question, font: fonts.body, max: 28, min: 14, width: col.width - 8, height: room, maxLines: 5)
        let total = lead.height + gap + q.height
        let top = col.midY - total / 2
        return QuestionLayout(lead: lead, question: q, tops: [top, top + lead.height + gap])
    }

    public static func questionFrame(_ t: TarotCardText, language: TarotLanguage, fonts: Fonts) -> RGB565Frame {
        let l = questionLayout(t, language: language, fonts: fonts)
        return base { ctx in
            l.lead.draw(in: ctx, centerX: column.midX, top: l.tops[0], color: accent)
            l.question.draw(in: ctx, centerX: column.midX, top: l.tops[1], color: ink)
        }
    }

    // MARK: Tiles

    // §5f.12 keyword tiles: 160×34, Playfair Medium Italic, white on black, one line in the 140×28 ink box at (10, 2).

    static func keyLine(_ keyword: String, fonts: Fonts, size: CGFloat) -> CTLine {
        let font = CTFontCreateCopyWithAttributes(fonts.keyword, size, nil, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): RGBAColor.white.cgColor,
        ]
        let clean = keyword.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return CTLineCreateWithAttributedString(NSAttributedString(string: clean, attributes: attrs))
    }

    /// The keyword's ink width at `size`.
    public static func keyInkWidth(_ keyword: String, fonts: Fonts, size: CGFloat) -> CGFloat {
        let b = CTLineGetBoundsWithOptions(keyLine(keyword, fonts: fonts, size: size), .useGlyphPathBounds)
        return b.isNull ? 0 : b.width
    }

    /// The line's height (ascent + descent) at `size`.
    public static func keyLineHeight(fonts: Fonts, size: CGFloat) -> CGFloat {
        let f = CTFontCreateCopyWithAttributes(fonts.keyword, size, nil, nil)
        return CTFontGetAscent(f) + CTFontGetDescent(f)
    }

    /// §5f.12: the one size of a language's keys — the largest (half-points) at which the longest keyword's ink fits 140 px
    /// and the line fits 28 px; every tile is then checked to keep its ink in the box (a half-point less if not).
    public static func keySize(_ keywords: [String], fonts: Fonts, start: CGFloat = 32) -> CGFloat {
        var size = start
        while size > 8 {
            if keyLineHeight(fonts: fonts, size: size) <= CGFloat(Oracle.keyInkHeight),
               keywords.allSatisfy({ keyInkWidth($0, fonts: fonts, size: size) <= CGFloat(Oracle.keyInkWidth) }),
               keywords.allSatisfy({ keyInkFits(keyTile($0, fonts: fonts, size: size)) }) {
                return size
            }
            size -= 0.5
        }
        return 8
    }

    /// A keyword tile at `size` (nil: the largest size this keyword alone fits): the ink centred across the box, the
    /// line box (ascent + descent) centred in its 28 rows, so every keyword shares one baseline.
    public static func keyTile(_ keyword: String, fonts: Fonts, size: CGFloat? = nil) -> RGB565Frame {
        let size = size ?? keySize([keyword], fonts: fonts)
        let l = keyLine(keyword, fonts: fonts, size: size)
        let ink = CTLineGetBoundsWithOptions(l, .useGlyphPathBounds)
        let f = CTFontCreateCopyWithAttributes(fonts.keyword, size, nil, nil)
        let a = CTFontGetAscent(f), d = CTFontGetDescent(f)
        let box = Oracle.keyInkBox
        let H = CGFloat(Oracle.keyHeight)
        let baseline = CGFloat(box.y) + (CGFloat(box.h) - (a + d)) / 2 + a          // y down
        let x = ink.isNull ? 0 : CGFloat(box.x) + CGFloat(box.w) / 2 - (ink.minX + ink.width / 2)
        let img = Raster.draw(width: Oracle.keyWidth, height: Oracle.keyHeight, background: .black) { ctx in
            ctx.textPosition = CGPoint(x: x.rounded(), y: (H - baseline).rounded())
            CTLineDraw(l, ctx)
        }
        return ClipRenderer.quantize(img, mode: .none)
    }

    /// The tile's ink lies in the §5f.12 ink box (140×28 at (10, 2)).
    public static func keyInkFits(_ f: RGB565Frame) -> Bool {
        let box = Oracle.keyInkBox
        for y in 0..<f.height {
            for x in 0..<f.width where f.pixels[y * f.width + x] != 0 {
                if x < box.x || x >= box.x + box.w || y < box.y || y >= box.y + box.h { return false }
            }
        }
        return true
    }

    /// A number-note tile: 536×72, the note centred on one line or two.
    public static func noteTileLayout(_ note: String, fonts: Fonts, maxSize: CGFloat = 21) -> Block {
        fitParagraph(note, font: fonts.body, max: maxSize, min: 12, width: CGFloat(Oracle.noteWidth) - 32,
                     height: CGFloat(Oracle.noteHeight) - 6, maxLines: 2)
    }

    public static func noteTile(_ note: String, fonts: Fonts, maxSize: CGFloat = 21) -> RGB565Frame {
        let b = noteTileLayout(note, fonts: fonts, maxSize: maxSize)
        let W = CGFloat(Oracle.noteWidth), H = CGFloat(Oracle.noteHeight)
        // The numeral (up to the first "·") in the accent, the rest in white.
        let lead = b.lines.first.flatMap { l in l.range(of: "·").map { (l[..<$0.upperBound] as Substring).utf16.count } } ?? 0
        let img = Raster.draw(width: Oracle.noteWidth, height: Oracle.noteHeight, background: .black) { ctx in
            let top = ((H - b.height) / 2).rounded()
            b.draw(in: ctx, centerX: W / 2, top: top, color: accent, canvasHeight: H) { _, g in g.stringIndex < lead }
            b.draw(in: ctx, centerX: W / 2, top: top, color: ink, canvasHeight: H) { _, g in g.stringIndex >= lead }
        }
        return ClipRenderer.quantize(img, mode: .none)
    }

    // MARK: Face

    /// The face's text, laid out (tests check it stays inside the column).
    public struct FaceLayout: Sendable {
        public var numeral: Block
        public var name: Block
        public var keyword: Block
        /// Each block's top (y down) inside the frame.
        public var tops: [CGFloat]
        /// The thin rule between name and keyword (y down), nil without a keyword.
        public var rule: CGRect?

        /// Every line's ink in frame coordinates (y down).
        public var inks: [CGRect] {
            zip([numeral, name, keyword], tops).flatMap { b, top in b.inks(centerX: column.midX, top: top) }
        }
    }

    public static func faceLayout(_ t: TarotCardText, fonts: Fonts) -> FaceLayout {
        let col = column
        let w = col.width - 8
        // Le Mat has no number on the Dodal deck: no numeral then.
        let numeral = fit(t.numeral, font: fonts.numeral, max: 74, min: 24, width: w, lines: 1)
        let name = fit(t.name.uppercased(with: Locale(identifier: "fr")), font: fonts.name, max: 28, min: 15, width: w, lines: 2, tracking: 0.08)
        let keyword = fit(t.keyword, font: fonts.keyword, max: 26, min: 14, width: w, lines: 2)
        let g1: CGFloat = 14, g2: CGFloat = 22
        var heights = [numeral.height, name.height, keyword.height]
        var gaps = [name.isEmpty || numeral.isEmpty ? 0 : g1, keyword.isEmpty ? 0 : g2]
        var total = heights.reduce(0, +) + gaps.reduce(0, +)
        // Too tall (two-line name and keyword at their largest): tighten the gaps, then shrink the numeral.
        var numeralFit = numeral
        if total > col.height {
            gaps = gaps.map { $0 * 0.6 }
            total = heights.reduce(0, +) + gaps.reduce(0, +)
            if total > col.height {
                numeralFit = fit(t.numeral, font: fonts.numeral, max: max(24, numeral.size - (total - col.height) * numeral.size / max(1, numeral.height)),
                                 min: 20, width: w, lines: 1)
                heights[0] = numeralFit.height
                total = heights.reduce(0, +) + gaps.reduce(0, +)
            }
        }
        var top = col.midY - total / 2
        var tops: [CGFloat] = []
        tops.append(top); top += heights[0] + gaps[0]
        tops.append(top); top += heights[1]
        let rule: CGRect? = keyword.isEmpty ? nil : CGRect(x: col.midX - 22, y: (top + gaps[1] / 2).rounded(), width: 44, height: 1)
        top += gaps[1]
        tops.append(top)
        return FaceLayout(numeral: numeralFit, name: name, keyword: keyword, tops: tops, rule: rule)
    }

    public static func faceFrame(_ t: TarotCardText, fonts: Fonts) -> RGB565Frame {
        let l = faceLayout(t, fonts: fonts)
        return base { ctx in
            let H = CGFloat(ClipCanvas.height)
            l.numeral.draw(in: ctx, centerX: column.midX, top: l.tops[0], color: accent)
            l.name.draw(in: ctx, centerX: column.midX, top: l.tops[1], color: ink)
            if let r = l.rule {
                ctx.setFillColor(warm.withAlpha(0.7).cgColor)
                ctx.fill(CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height))
            }
            l.keyword.draw(in: ctx, centerX: column.midX, top: l.tops[2], color: warm)
        }
    }

    // MARK: Reading

    /// A card's reading split into pages.
    public struct ReadingLayout: Sendable {
        public struct Page: Sendable {
            public var lines: [String]
            /// Baselines (y down) of `lines`.
            public var baselines: [CGFloat]
            public var noteLines: [String]
            public var noteBaselines: [CGFloat]
            /// Every line's ink (body and note) in frame coordinates (y down).
            public var inks: [CGRect]
        }
        public var pages: [Page]
        public var bodySize: CGFloat
        public var noteSize: CGFloat
        /// The text had to be cut with "…" (never for texts of normal length).
        public var truncated: Bool
        /// Most body lines on a page.
        public var maxLines: Int { pages.map(\.lines.count).max() ?? 0 }
    }

    /// Splits the reading into `pages` pages of at most 4 lines at the largest size that fits (24 px
    /// down to 15 px), an optional note in a smaller italic at the bottom of the last page (the clip's
    /// assets carry the number notes in `N` instead, so `withNote` is off for them). Pages break at a
    /// sentence end when that costs at most 3 px of size, else at a clause (2 px), else between words.
    public static func readingLayout(_ t: TarotCardText, fonts: Fonts, pages: Int = pages, withNote: Bool = false) -> ReadingLayout {
        let words = tokens(t.reading)
        let noteWords = withNote ? tokens(t.note) : []
        let area = readingArea
        let bodyM = WordMeasure(words, font: fonts.body)
        let noteM = WordMeasure(noteWords, font: fonts.note)

        struct Plan { var size: CGFloat; var noteSize: CGFloat; var pageLines: [[String]]; var noteLines: [String] }

        /// The note at a body size: its size and lines (≤ 2, or 3 at the smallest note size).
        func notePlan(_ bodySize: CGFloat) -> (CGFloat, [String])? {
            guard !noteWords.isEmpty else { return (0, []) }
            var ns = max(minNoteSize, (bodySize * noteScale).rounded())
            while ns >= 12 {
                let lines = noteM.wrap(0..<noteWords.count, size: ns, width: area.width)
                if lines.count <= 2 || (ns <= 12 && lines.count <= 3) { return (ns, lines.map { noteM.text($0) }) }
                ns -= 1
            }
            return nil
        }

        func pitch(_ s: CGFloat) -> CGFloat { (s * lineSpacing).rounded() }

        /// Height of a page's text block (body lines, gap, note lines).
        func height(body lines: Int, size: CGFloat, note: Int, noteSize: CGFloat) -> CGFloat {
            let b = CGFloat(lines) * pitch(size)
            let n = CGFloat(note) * pitch(noteSize)
            return b + n + (lines > 0 && note > 0 ? (size * 0.55).rounded() : 0)
        }

        /// Pages for split points `cuts` (word indices where pages 2… start) at `size`, or nil.
        func tryPlan(size: CGFloat, cuts: [Int], maxLines: Int) -> Plan? {
            guard let (ns, note) = notePlan(size) else { return nil }
            var bounds = [0] + cuts + [words.count]
            bounds = bounds.enumerated().map { $0.offset == 0 ? 0 : max($0.element, bounds[$0.offset - 1]) }
            var pagesOut: [[String]] = []
            for p in 0..<pages {
                let r = bounds[p]..<bounds[p + 1]
                let lines = r.isEmpty ? [] : bodyM.wrap(r, size: size, width: area.width)
                guard lines.count <= maxLines else { return nil }
                let isLast = p == pages - 1
                guard height(body: lines.count, size: size, note: isLast ? note.count : 0, noteSize: ns) <= area.height else { return nil }
                pagesOut.append(lines.map { bodyM.text($0) })
            }
            return Plan(size: size, noteSize: ns, pageLines: pagesOut, noteLines: note)
        }

        // Candidate page breaks, by class: sentence ends, clause ends, any word.
        let sentence = Set(words.indices.dropLast().filter { endsSentence(words[$0]) }.map { $0 + 1 })
        let clause = Set(words.indices.dropLast().filter { endsClause(words[$0]) }.map { $0 + 1 })
        let any = Set(words.indices.dropFirst())

        /// All ways of cutting into `pages` pages from `breaks` (pages > 2: evenly spread choices).
        func cutSets(_ breaks: Set<Int>) -> [[Int]] {
            let sorted = breaks.sorted()
            guard pages > 1 else { return [[]] }
            if pages == 2 { return sorted.map { [$0] } }
            var out: [[Int]] = []
            for a in sorted { for b in sorted where b > a { out.append([a, b]) } }
            return out
        }

        /// The largest size (half-pixel steps) at which some cut from `breaks` fits, with the most
        /// balanced pages.
        func best(_ breaks: Set<Int>, maxLines: Int = maxLinesPerPage, from: CGFloat = maxBodySize, to: CGFloat = minBodySize) -> Plan? {
            let sets = words.isEmpty ? [Array(repeating: 0, count: max(0, pages - 1))] : cutSets(breaks)
            guard !sets.isEmpty else { return nil }
            var size = from
            while size >= to - 0.01 {
                var found: [(Plan, CGFloat)] = []
                for cuts in sets {
                    guard let p = tryPlan(size: size, cuts: cuts, maxLines: maxLines) else { continue }
                    // Balance: the last page also carries the note (counted as lines of body pitch).
                    let notePart = height(body: 0, size: size, note: p.noteLines.count, noteSize: p.noteSize) / pitch(size)
                    let loads = p.pageLines.enumerated().map { CGFloat($0.element.count) + ($0.offset == pages - 1 ? notePart : 0) }
                    let empty = p.pageLines.contains { $0.isEmpty } && words.count >= pages
                    found.append((p, (loads.max()! - loads.min()!) + (empty ? 100 : 0)))
                }
                if let pick = found.min(by: { $0.1 < $1.1 }) { return pick.0 }
                size -= 0.5
            }
            return nil
        }

        var plan: Plan?
        let bySentence = best(sentence)
        let byClause = best(clause)
        let byWord = best(any)
        if let w = byWord {
            if let s = bySentence, s.size >= w.size - 3 { plan = s } else if let c = byClause, c.size >= w.size - 2 { plan = c } else { plan = w }
        } else {
            plan = bySentence ?? byClause
        }
        var truncated = false
        if plan == nil {
            // Very long: as many lines as the height allows at the smallest size.
            let lines = Int(area.height / pitch(minBodySize))
            plan = best(any, maxLines: lines, from: minBodySize, to: minBodySize)
            if plan == nil {
                // Last resort: fill the pages and cut the end with "…".
                truncated = true
                let (ns, note) = notePlan(minBodySize) ?? (minNoteSize, [])
                let all = bodyM.wrap(0..<words.count, size: minBodySize, width: area.width).map { bodyM.text($0) }
                var out: [[String]] = []
                var i = 0
                for p in 0..<pages {
                    let isLast = p == pages - 1
                    var n = lines
                    while n > 0 && height(body: n, size: minBodySize, note: isLast ? note.count : 0, noteSize: ns) > area.height { n -= 1 }
                    out.append(Array(all[min(i, all.count)..<min(i + n, all.count)]))
                    i += n
                }
                if var last = out.last?.last {
                    last = ellipsized(last, font: fonts.body, size: minBodySize, width: area.width)
                    out[out.count - 1][out[out.count - 1].count - 1] = last
                }
                plan = Plan(size: minBodySize, noteSize: ns, pageLines: out, noteLines: note)
            }
        }
        return place(plan!.pageLines, size: plan!.size, note: plan!.noteLines, noteSize: plan!.noteSize, fonts: fonts, truncated: truncated)
    }

    /// Baselines: one block height for every page (the tallest), centred; bodies start at its top, the
    /// note sits at its bottom. Verified with the real layout (a line that measures too wide is refit).
    private static func place(_ pageLines: [[String]], size: CGFloat, note: [String], noteSize: CGFloat, fonts: Fonts,
                              truncated: Bool) -> ReadingLayout {
        let area = readingArea
        let bodyRef = TextLayoutEngine.layout("Hxg", font: fonts.body, size: size)
        let ascent = CTFontGetAscent(CTFontCreateCopyWithAttributes(fonts.body, size, nil, nil))
        let pitch = (size * lineSpacing).rounded()
        let notePitch = (noteSize * lineSpacing).rounded()
        let gap = (size * 0.55).rounded()
        _ = bodyRef
        func blockHeight(_ lines: Int, _ notes: Int) -> CGFloat {
            CGFloat(lines) * pitch + CGFloat(notes) * notePitch + (lines > 0 && notes > 0 ? gap : 0)
        }
        let heights = pageLines.enumerated().map { blockHeight($0.element.count, $0.offset == pageLines.count - 1 ? note.count : 0) }
        let block = heights.max() ?? 0
        let top = (area.midY - block / 2).rounded()
        var pages: [ReadingLayout.Page] = []
        for (p, lines) in pageLines.enumerated() {
            let isLast = p == pageLines.count - 1
            // First baseline: the line box's ascent below the top (pitch-centred).
            let b0 = top + ascent + (pitch - size * 1.2) / 2
            let baselines = lines.indices.map { (b0 + CGFloat($0) * pitch).rounded() }
            var noteBaselines: [CGFloat] = []
            var noteLines: [String] = []
            if isLast && !note.isEmpty {
                let nAscent = CTFontGetAscent(CTFontCreateCopyWithAttributes(fonts.note, noteSize, nil, nil))
                let noteTop = top + block - CGFloat(note.count) * notePitch
                noteBaselines = note.indices.map { (noteTop + nAscent + (notePitch - noteSize * 1.2) / 2 + CGFloat($0) * notePitch).rounded() }
                noteLines = note
            }
            var inks: [CGRect] = []
            func measure(_ s: String, font: CTFont, sz: CGFloat, baseline: CGFloat) {
                let l = TextLayoutEngine.layout(s, font: font, size: sz).lines[0]
                guard !l.ink.isNull else { return }
                inks.append(CGRect(x: area.minX + l.ink.minX, y: baseline - l.ink.maxY, width: l.ink.width, height: l.ink.height))
            }
            for (s, b) in zip(lines, baselines) { measure(s, font: fonts.body, sz: size, baseline: b) }
            for (s, b) in zip(noteLines, noteBaselines) { measure(s, font: fonts.note, sz: noteSize, baseline: b) }
            pages.append(.init(lines: lines, baselines: baselines, noteLines: noteLines, noteBaselines: noteBaselines, inks: inks))
        }
        return ReadingLayout(pages: pages, bodySize: size, noteSize: noteSize, truncated: truncated)
    }

    public static func readingFrame(_ layout: ReadingLayout, page p: Int, fonts: Fonts) -> RGB565Frame {
        base { ctx in
            let H = CGFloat(ClipCanvas.height)
            guard layout.pages.indices.contains(p) else { return }
            let page = layout.pages[p]
            func draw(_ lines: [String], _ baselines: [CGFloat], font: CTFont, size: CGFloat, color: RGBAColor) {
                guard !lines.isEmpty else { return }
                let l = TextLayoutEngine.layout(lines.joined(separator: "\n"), font: font, size: size)
                TextPainter.draw(l, in: ctx, origins: baselines.map { CGPoint(x: readingArea.minX, y: H - $0) }, style: TextStyle(fill: .solid(color)))
            }
            draw(page.lines, page.baselines, font: fonts.body, size: layout.bodySize, color: ink)
            draw(page.noteLines, page.noteBaselines, font: fonts.note, size: layout.noteSize, color: secondary)
            // Page marks: small dots down the right edge, the current one lit.
            let n = layout.pages.count
            guard n > 1 else { return }
            for i in 0..<n {
                let y = 120 - CGFloat(n - 1) * 7 + CGFloat(i) * 14
                ctx.setFillColor((i == p ? markOn : markOff).cgColor)
                ctx.fillEllipse(in: CGRect(x: 520, y: H - y - 2.5, width: 5, height: 5))
            }
        }
    }

    // MARK: One card (previews)

    /// One card's composed screens as the clip shows them: face (day mode), question, reading pages,
    /// and its keyword and note tiles (the editor's preview and the screenshots).
    public struct CardPreview: Sendable {
        public var face: RGB565Frame
        public var question: RGB565Frame
        public var readings: [RGB565Frame]
        public var key: RGB565Frame
        public var note: RGB565Frame
    }

    public static func cardPreview(deck: TarotDeck, text t: TarotCardText, language: TarotLanguage, fonts: Fonts, pages: Int = pages) -> CardPreview? {
        guard deck.faces.indices.contains(t.index) else { return nil }
        let card = cardPixels(deck.faces[t.index], size: (Oracle.slot.w, Oracle.slot.h))   // the old slot of these previews
        func slotted(_ f: RGB565Frame) -> RGB565Frame {
            var out = f
            OracleCompositor.paste(card, into: &out, x: Oracle.slot.x, y: Oracle.slot.y)
            return out
        }
        let layout = readingLayout(t, fonts: fonts, pages: pages)
        return CardPreview(face: slotted(faceFrame(t, fonts: fonts)), question: slotted(questionFrame(t, language: language, fonts: fonts)),
                           readings: (0..<pages).map { slotted(readingFrame(layout, page: $0, fonts: fonts)) },
                           key: keyTile(t.keyword, fonts: fonts), note: noteTile(t.threadNote, fonts: fonts))
    }

    // MARK: Text helpers

    /// Words split on plain spaces and newlines only (no-break spaces keep "vrai ?" together).
    static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).map(String.init)
    }

    static func endsSentence(_ w: String) -> Bool {
        let trimmed = w.trimmingCharacters(in: CharacterSet(charactersIn: "»”\"')’"))
        guard let last = trimmed.last else { return false }
        return ".!?…".contains(last)
    }

    static func endsClause(_ w: String) -> Bool {
        guard let last = w.last else { return false }
        return ",;:—–".contains(last) || endsSentence(w)
    }

    static func ellipsized(_ s: String, font: CTFont, size: CGFloat, width: CGFloat) -> String {
        var t = s
        while !t.isEmpty {
            let candidate = t.trimmingCharacters(in: .whitespaces) + "…"
            let l = TextLayoutEngine.layout(candidate, font: font, size: size).lines[0]
            if l.ink.isNull || l.ink.maxX <= width { return candidate }
            t.removeLast()
        }
        return "…"
    }

    /// Word widths measured once at 100 px (CoreText scales linearly); wrapping uses them with a small
    /// margin and each wrapped line is then checked against its real ink.
    final class WordMeasure {
        let words: [String]
        let font: CTFont
        let widths: [CGFloat]
        let space: CGFloat

        init(_ words: [String], font: CTFont) {
            self.words = words
            self.font = font
            widths = words.map { CGFloat(TextLayoutEngine.layout($0, font: font, size: 100).lines[0].width) }
            space = TextLayoutEngine.layout("a a", font: font, size: 100).lines[0].width - TextLayoutEngine.layout("aa", font: font, size: 100).lines[0].width
        }

        func text(_ r: Range<Int>) -> String { words[r].joined(separator: " ") }

        /// Greedy wrap of words `r` into lines no wider than `width` at `size`.
        func wrap(_ r: Range<Int>, size: CGFloat, width: CGFloat) -> [Range<Int>] {
            let k = size / 100
            let limit = width * 0.985
            var lines: [Range<Int>] = []
            var start = r.lowerBound
            var w: CGFloat = 0
            for i in r {
                let add = (i == start ? 0 : space) + widths[i]
                if i > start && (w + add) * k > limit {
                    lines.append(start..<i)
                    start = i
                    w = widths[i]
                } else {
                    w += add
                }
            }
            if start < r.upperBound { lines.append(start..<r.upperBound) }
            // Check each line's real ink; a line that is still too wide pushes its last word down.
            var out: [Range<Int>] = []
            var queue = lines
            while !queue.isEmpty {
                var line = queue.removeFirst()
                while line.count > 1 {
                    let l = TextLayoutEngine.layout(text(line), font: font, size: size).lines[0]
                    if l.ink.isNull || l.ink.maxX <= width { break }
                    let moved = line.upperBound - 1
                    line = line.lowerBound..<moved
                    if let next = queue.first { queue[0] = moved..<next.upperBound } else { queue.append(moved..<(moved + 1)) }
                }
                out.append(line)
            }
            return out
        }
    }

    /// A short text fitted to a width: one line at the largest size from `max` down to `min`, else up to
    /// `lines` lines (split at the most balanced space), else the smallest size, cut with "…".
    public struct Block: @unchecked Sendable {
        public var lines: [String]
        public var size: CGFloat
        public var tracking: Double
        let font: CTFont
        let layout: TextLayout

        public var isEmpty: Bool { lines.isEmpty }
        /// From the first line's ink top to the last line's ink bottom.
        public var height: CGFloat {
            let ink = layout.blockInk
            return ink.isNull ? 0 : ink.height
        }

        /// Line inks (y down) when drawn centred on `centerX` with the block's ink top at `top`.
        func inks(centerX: CGFloat, top: CGFloat) -> [CGRect] {
            let ink = layout.blockInk
            guard !ink.isNull else { return [] }
            let b0 = top + ink.maxY
            return layout.lines.enumerated().compactMap { i, l in
                guard !l.ink.isNull else { return nil }
                let x = (centerX - (l.ink.minX + l.ink.width / 2)).rounded()
                let b = (b0 + CGFloat(i) * layout.lineHeight).rounded()
                return CGRect(x: x + l.ink.minX, y: b - l.ink.maxY, width: l.ink.width, height: l.ink.height)
            }
        }

        func draw(in ctx: CGContext, centerX: CGFloat, top: CGFloat, color: RGBAColor, canvasHeight H: CGFloat = CGFloat(ClipCanvas.height),
                  include: ((Int, LaidGlyph) -> Bool)? = nil) {
            let ink = layout.blockInk
            guard !ink.isNull else { return }
            let b0 = top + ink.maxY
            let origins = layout.lines.enumerated().map { i, l -> CGPoint in
                let x = l.ink.isNull ? centerX : (centerX - (l.ink.minX + l.ink.width / 2)).rounded()
                return CGPoint(x: x, y: H - (b0 + CGFloat(i) * layout.lineHeight).rounded())
            }
            TextPainter.draw(layout, in: ctx, origins: origins, style: TextStyle(fill: .solid(color)), include: include)
        }
    }

    static func fit(_ text: String, font: CTFont, max: CGFloat, min: CGFloat, width: CGFloat, lines maxLines: Int, tracking: Double = 0) -> Block {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        func block(_ lines: [String], _ size: CGFloat) -> Block {
            Block(lines: lines, size: size, tracking: tracking, font: font,
                  layout: TextLayoutEngine.layout(lines.joined(separator: "\n"), font: font, size: size, tracking: tracking))
        }
        guard !clean.isEmpty else { return block([], max) }
        func fits(_ lines: [String], _ size: CGFloat) -> Bool {
            let l = TextLayoutEngine.layout(lines.joined(separator: "\n"), font: font, size: size, tracking: tracking)
            return l.lines.allSatisfy { $0.ink.isNull || $0.ink.width <= width }
        }
        // One line, measured at 100 px and scaled, then verified.
        let ref = TextLayoutEngine.layout(clean, font: font, size: 100, tracking: tracking).lines[0].ink.width
        var size = Swift.min(max, ref > 0 ? (width / ref * 100 * 2).rounded(.down) / 2 : max)
        while size >= min {
            if fits([clean], size) { return block([clean], size) }
            size -= 0.5
        }
        if maxLines >= 2 {
            let words = tokens(clean)
            if words.count >= 2 {
                // The most balanced split into two lines.
                var splits: [[String]] = []
                for k in 1..<words.count {
                    let first: String = words[..<k].joined(separator: " ")
                    let second: String = words[k...].joined(separator: " ")
                    splits.append([first, second])
                }
                splits.sort { (a: [String], b: [String]) -> Bool in
                    let da: Int = abs(a[0].count - a[1].count)
                    let db: Int = abs(b[0].count - b[1].count)
                    return da < db
                }
                size = max
                while size >= min {
                    if let s = splits.first(where: { fits($0, size) }) { return block(s, size) }
                    size -= 0.5
                }
            }
        }
        var t = clean
        while t.count > 1 && !fits([t + "…"], min) { t.removeLast() }
        return block([t == clean ? t : t.trimmingCharacters(in: .whitespaces) + "…"], min)
    }

    /// A paragraph wrapped into at most `maxLines` lines no wider than `width` and no taller than
    /// `height`, at the largest size from `max` down to `min` (then cut with "…" if it must).
    static func fitParagraph(_ text: String, font: CTFont, max: CGFloat, min: CGFloat, width: CGFloat, height: CGFloat, maxLines: Int) -> Block {
        let words = tokens(text)
        func block(_ lines: [String], _ size: CGFloat) -> Block {
            Block(lines: lines, size: size, tracking: 0, font: font, layout: TextLayoutEngine.layout(lines.joined(separator: "\n"), font: font, size: size))
        }
        guard !words.isEmpty else { return block([], max) }
        let m = WordMeasure(words, font: font)
        var size = max
        while size >= min - 0.01 {
            let lines = m.wrap(0..<words.count, size: size, width: width).map { m.text($0) }
            if lines.count <= maxLines {
                let b = block(lines, size)
                if b.height <= height && b.layout.lines.allSatisfy({ $0.ink.isNull || $0.ink.width <= width }) { return b }
            }
            size -= 0.5
        }
        var lines = m.wrap(0..<words.count, size: min, width: width).map { m.text($0) }
        var b = block(Array(lines.prefix(maxLines)), min)
        while b.lines.count > 1 && b.height > height { lines = Array(b.lines.dropLast()); b = block(lines, min) }
        if b.lines.count < lines.count || b.lines.joined(separator: " ") != words.joined(separator: " ") {
            var l = b.lines
            l[l.count - 1] = ellipsized(l[l.count - 1], font: font, size: min, width: width)
            b = block(l, min)
        }
        return b
    }
}
