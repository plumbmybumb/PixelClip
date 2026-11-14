import CoreText
import Foundation

/// The Tarot's text size (PROTOCOL §5f.3): the body atlas and the numeral's atlas scale together.
public enum TarotTextSize: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case small, medium, large

    public var id: String { rawValue }
    public var title: String { ["Small", "Medium", "Large"][Self.allCases.firstIndex(of: self)!] }
    /// Body point size: 18 / 22 / 26 (18 reads small on the panel; Medium is the default).
    public var bodySize: CGFloat { [18, 22, 26][Self.allCases.firstIndex(of: self)!] }
    /// `font_big` point size: 48 / 56 / 64.
    public var bigSize: CGFloat { [48, 56, 64][Self.allCases.firstIndex(of: self)!] }
    /// §5f.11: the body font's large face, 1.3× the body size: 23 / 29 / 34 pt.
    public var largeSize: CGFloat { (bodySize * 1.3).rounded() }

    /// Unknown future sizes read as Medium.
    public init(from decoder: any Decoder) throws {
        self = TarotTextSize(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .medium
    }
}

/// The Oracle's glyph atlases (PROTOCOL §5f.2/§5f.3): the body font the clip writes every text screen and the
/// paragraph pages with, and the big font of the face's numeral. Playfair Display (the Tarot's typeface: the
/// keys, the notes and the app's previews use it too), uploaded like the Reader's fonts.
///
/// **Ids** carry the point size so the sizes coexist on the clip: body `tarot-font<pt>-<hash>-{n,na,c,ca}` with the
/// document `tarot-font<pt>-<hash>` (with accent atlases since §5f.9: the hint words and the lead-in), big `tarot-big<pt>-<hash>-{n,na,c,ca}` with the document
/// `tarot-big<pt>-<hash>` (`<hash>`: 8 hex of the atlases' content, so a re-render gives the same ids).
public enum TarotFonts {
    /// What every Tarot atlas and font id starts with (never sync orphans; cleaned up by `ReaderPusher`).
    public static let bodyPrefix = "tarot-font"
    public static let bigPrefix = "tarot-big"
    /// The compact faces (the text layout's fallback, and the button hints' words, §5f.9): small to keep bytes down.
    public static let compactSize: CGFloat = 12
    public static let bigGlyphs = "0123456789IVXL "
    public static let familyID = TarotRenderer.Fonts.familyID

    public static func bodyPrefix(_ size: TarotTextSize) -> String { "\(bodyPrefix)\(Int(size.bodySize))-" }
    public static func bigPrefix(_ size: TarotTextSize) -> String { "\(bigPrefix)\(Int(size.bigSize))-" }

    /// Playfair Display at `weight` (registered with the app's fonts).
    public static func playfair(_ weight: Double = 0, size: CGFloat) -> CTFont {
        FontCatalog.ctFont(for: FontSelection(familyID: familyID, weight: weight), size: size)
    }

    /// With its accent atlases (§5f.9: the clip draws the button hints' words from the compact accent atlas and
    /// accent lines from the normal one; without them its document aliases accent to white).
    public static func body(_ size: TarotTextSize = .medium, makeFont: (CGFloat) -> CTFont = { playfair(0, size: $0) }) throws -> ReaderFont {
        try ReaderFontRenderer.render(name: "Playfair Display", accentORP: true, normalSize: size.bodySize, compactSize: compactSize,
                                      largeSize: size.largeSize,
                                      prefix: bodyPrefix(size), makeFont: makeFont)
    }

    /// With its accent atlas (the numeral is drawn in the accent), only the numeral's glyphs.
    public static func big(_ size: TarotTextSize = .medium, makeFont: (CGFloat) -> CTFont = { playfair(0.4, size: $0) }) throws -> ReaderFont {
        try ReaderFontRenderer.render(name: "Playfair Display Bold", accentORP: true, normalSize: size.bigSize, compactSize: compactSize,
                                      glyphs: bigGlyphs, prefix: bigPrefix(size), makeFont: makeFont)
    }

    /// `"tarot-font22-1a2b3c4d"` for any Tarot atlas or font id of that font (nil for other ids): what the
    /// clean-up compares.
    public static func fontKey(inID id: String) -> String? {
        for p in [bodyPrefix, bigPrefix] where id.hasPrefix(p) {
            let rest = id.dropFirst(p.count)
            let digits = rest.prefix { $0.isNumber }
            guard !digits.isEmpty, rest.dropFirst(digits.count).first == "-" else { return nil }
            let hash = rest.dropFirst(digits.count + 1).prefix { $0 != "-" }
            guard hash.count == 8 else { return nil }
            return "\(p)\(digits)-\(hash)"
        }
        return nil
    }
}

/// The clip's text screens drawn from the phrase bundle with glyph atlases (PROTOCOL §5f.2, §5f.3), the way the
/// firmware draws them (the text layout, `core/include/textlay.h`: entries, greedy wrap, lines centred; `TextWrap`),
/// so the virtual clip and the phone show what the clip shows.
///
/// Layout (536 × 240; the card is pasted in the slot `x 40, y 21`, 104 × 198, as before; §5f.9: the prompts and the
/// lean / detail text are centred in rows 20…220, the hints in the BOOT corner's 20 px band):
/// - the **column** is `x 168…520` (352 px); lines are centred in it (`x = 168 + ⌊(352 − pen) / 2⌋`), and a
///   screen's block of lines is centred vertically (`top = ⌊(240 − height) / 2⌋`);
/// - **waits**: `[prompt]` wrapped in the body face (as many lines as fit);
/// - **reading** page `p`: `card.<i>.reading` paginated at `linesPerPage` lines (≤ 4) and at most `maxPages` (6)
///   pages (the page rule: a page that isn't the last ends after its last sentence end, else after a comma /
///   semicolon / colon; past the cap the last page is cut with "…"); with more than one page a column of
///   `dotSize` px dots at `x 524`, `dotGap` px apart, centred vertically: the current page accent, the others dim;
/// - **paragraph** page `p` (§5f.3) and the **short** screens (§5f.4): full width (`x 20…516`, 496 px), as many
///   lines as fit (240 / cell height), at most 8 pages, the same page rule and dots.
/// (Since §5f.6 there is no face or question screen: the numeral font `font_big` is still sent, unused by these.)
/// Every block's line pitch is its face's cell height. "Accent" body text is drawn with the body font's accent
/// atlas (sent since §5f.9).
public enum OracleScreens {
    public static let columnX = 168, columnWidth = 352
    /// §5f.3: the paragraph's pages use the full width.
    public static let paragraphX = 20, paragraphWidth = 496
    /// Reading pages: ≤ 4 lines, ≤ 6 pages (§5f.3); the paragraph: as many lines as fit, ≤ 8 pages.
    public static let maxLines = 4, maxPages = 6, maxParagraphPages = 8

    /// A horizontal band lines are centred in.
    public struct Band: Sendable, Equatable {
        public var x: Int, width: Int
        public static let column = Band(x: columnX, width: columnWidth)
        public static let full = Band(x: paragraphX, width: paragraphWidth)
    }
    public static let dotX = 524, dotSize = 4, dotGap = 10
    /// §5f.11 the text boxes: 224 rows, from y 16 normally (below the corner's ▶), from y 0 flipped (above it).
    public static let textBoxHeight = 224
    public static func textTop(flipped: Bool) -> Int { flipped ? 0 : 16 }
    /// Full width (lean, a detail without its card): x 8 ..< 528.
    public static let fullBox = Band(x: 8, width: 520)
    /// Beside a card (waits, armed, detail; §5f.12): x 124 ..< 528 normally, x 8 ..< 412 flipped (8 px from the card).
    public static func besideBox(flipped: Bool) -> Band { Band(x: flipped ? 8 : 124, width: 404) }
    /// §5f.11 the hint: one ▶ (8 × 9) in the BOOT corner — normally its right edge 8 px from the right edge and its top
    /// row at y 4, pointing right; flipped its left edge 8 px from the left edge and its bottom row at y 235, pointing
    /// left — inside a 24 × 16 corner reserve where nothing else is drawn (the clip's `ot_arrow_xy` / `ot_reserve_xy`).
    public static let hintWidth = 8, hintHeight = 9, hintMargin = 8
    public static func hintOrigin(flipped: Bool) -> (x: Int, y: Int) {
        flipped ? (hintMargin, 235 - hintHeight + 1) : (ClipCanvas.width - hintMargin - hintWidth, 4)
    }
    public static func cornerReserve(flipped: Bool) -> (x: Int, y: Int, w: Int, h: Int) {
        flipped ? (0, ClipCanvas.height - 16, 24, 16) : (ClipCanvas.width - 24, 0, 24, 16)
    }

    /// One line ready to paint: glyph slots (x absolute), the cell top, which face and atlas.
    public struct Line: Sendable, Equatable {
        public var text: String
        public var glyphs: [Int?]
        public var xs: [Int]
        public var top: Int
        public var big: Bool
        public var accent: Bool
    }

    public struct Screen: Sendable, Equatable {
        public var lines: [Line]
        /// Reading pages: (count, current) when there is more than one.
        public var dots: (count: Int, current: Int)?
        public static func == (a: Screen, b: Screen) -> Bool { a.lines == b.lines && a.dots?.count == b.dots?.count && a.dots?.current == b.dots?.current }
    }

    /// Lines per reading page: 4, fewer if the body cell is taller than a quarter of the screen.
    public static func linesPerPage(_ face: ReaderBoundFont.Face) -> Int { min(maxLines, linesThatFit(face)) }

    /// Lines of `face` that fit the screen's height (the paragraph pages, the question).
    public static func linesThatFit(_ face: ReaderBoundFont.Face) -> Int {
        let h = face.document.cellH
        return max(1, h > 0 ? ClipCanvas.height / h : 1)
    }

    /// `text` wrapped into the column (every line).
    static func wrapped(_ text: String, face: ReaderBoundFont.Face, band: Band = .column) -> (note: TextWrap.Entries, lines: [Range<Int>]) {
        var note = TextWrap.Entries(text)
        note.measure(face)
        let (ls, _) = TextWrap.wrap(note, from: 0, maxw: band.width)
        return (note, ls.map { note.trimmed($0) })
    }

    /// At most `cap` lines; past it the last one is cut with "…".
    static func capped(_ text: String, face: ReaderBoundFont.Face, cap: Int, band: Band = .column) -> (note: TextWrap.Entries, lines: [Range<Int>], extra: [UInt32]) {
        var note = TextWrap.Entries(text)
        note.measure(face)
        let (ls, count) = TextWrap.wrap(note, from: 0, maxw: band.width, stop: cap)
        guard count > cap else { return (note, ls.map { note.trimmed($0) }, []) }
        var lines = ls.prefix(cap - 1).map { note.trimmed($0) }
        let (r, e) = TextWrap.ellipsisLine(note, from: ls[cap - 1].lowerBound, face: face, maxw: band.width)
        lines.append(r)
        return (note, lines, e)
    }

    /// Pages of `maxl` lines in `band`, at most `cap` (the page rule: a page that isn't the last ends after its
    /// last sentence end, else after a comma / semicolon / colon; past `cap` the last page is cut with "…").
    static func paginated(_ text: String, face: ReaderBoundFont.Face, band: Band, maxl: Int, cap: Int)
        -> (note: TextWrap.Entries, pages: [[Range<Int>]], extra: [UInt32]) {
        var note = TextWrap.Entries(text)
        note.measure(face)
        let (needed, pg, last) = TextWrap.paginate(note, maxw: band.width, maxl: maxl, cap: cap)
        if needed <= cap { return (note, pg.map { $0.lines.map { note.trimmed($0) } }, []) }
        var pages = pg.prefix(cap - 1).map { $0.lines.map { note.trimmed($0) } }
        let (ls, _) = TextWrap.wrap(note, from: last, maxw: band.width, stop: maxl)
        var lines = ls.prefix(maxl - 1).map { note.trimmed($0) }
        let (cut, ell) = TextWrap.ellipsisLine(note, from: ls[maxl - 1].lowerBound, face: face, maxw: band.width)
        lines.append(cut)
        pages.append(lines)
        return (note, pages, ell)
    }

    /// A reading's pages: ≤ 4 lines in the column, ≤ 6 pages.
    static func pages(_ text: String, face: ReaderBoundFont.Face) -> (note: TextWrap.Entries, pages: [[Range<Int>]], extra: [UInt32]) {
        paginated(text, face: face, band: .column, maxl: linesPerPage(face), cap: maxPages)
    }

    /// The paragraph's pages (§5f.3): full width, as many lines as fit, ≤ 8 pages.
    static func paragraphPages(_ text: String, face: ReaderBoundFont.Face) -> (note: TextWrap.Entries, pages: [[Range<Int>]], extra: [UInt32]) {
        paginated(text, face: face, band: .full, maxl: linesThatFit(face), cap: maxParagraphPages)
    }

    /// How many pages a reading takes (1…`maxPages`; an empty reading still has one page).
    public static func pageCount(_ text: String, face: ReaderBoundFont.Face) -> Int { max(1, pages(text, face: face).pages.count) }

    /// The reading needs more than `maxPages` pages (its last page is cut).
    public static func overflows(_ text: String, face: ReaderBoundFont.Face) -> Bool { !pages(text, face: face).extra.isEmpty }

    /// How many pages the paragraph takes (1…8), and whether it is cut.
    public static func paragraphPageCount(_ text: String, face: ReaderBoundFont.Face) -> Int { max(1, paragraphPages(text, face: face).pages.count) }
    public static func paragraphOverflows(_ text: String, face: ReaderBoundFont.Face) -> Bool { !paragraphPages(text, face: face).extra.isEmpty }

    /// The text of each paragraph page as the clip shows it (Home highlights the one on screen).
    public static func paragraphPageTexts(_ text: String, face: ReaderBoundFont.Face) -> [String] {
        let p = paragraphPages(text, face: face)
        return p.pages.enumerated().map { i, lines in
            lines.enumerated().map { k, r in
                line(r, note: p.note, extra: i == p.pages.count - 1 && k == lines.count - 1 ? p.extra : [], face: face, top: 0, big: false,
                     accent: false, band: .full).text
            }.joined(separator: " ")
        }
    }

    /// One placed line (centred in the column; `extra` code points appended, the "…" of a cut).
    static func line(_ r: Range<Int>, note: TextWrap.Entries, extra: [UInt32] = [], face: ReaderBoundFont.Face, top: Int, big: Bool,
                     accent: Bool, band: Band = .column) -> Line {
        var items: [(glyph: Int?, advance: Int, cp: UInt32)] = r.map { i in
            if note.kind[i] == .glyph { let g = face.glyph(note.cp[i]); return (g.glyph, g.advance, note.cp[i]) }
            return (nil, face.spaceAdvance, 0x20)
        }
        items += extra.map { let g = face.glyph($0); return (g.glyph, g.advance, $0) }
        let pen = items.reduce(0) { $0 + $1.advance }
        let room = band.width - pen
        var x = band.x + (room >= 0 ? room / 2 : -((-room + 1) / 2))
        var xs: [Int] = []
        for it in items { xs.append(x); x += it.advance }
        let text = String(String.UnicodeScalarView(items.compactMap { Unicode.Scalar($0.cp) }))
        return Line(text: text, glyphs: items.map(\.glyph), xs: xs, top: top, big: big, accent: accent)
    }

    /// Blocks of lines (each with its face's pitch, a gap before it) centred vertically.
    struct Block {
        var note: TextWrap.Entries
        var lines: [Range<Int>]
        var extra: [UInt32] = []
        var face: ReaderBoundFont.Face
        var big = false
        var accent = false
        var gapBefore = 0
        var band = Band.column
    }

    static func stack(_ blocks: [Block], top: Int = 0, area: Int = ClipCanvas.height) -> [Line] {
        let blocks = blocks.filter { !$0.lines.isEmpty }
        var height = 0
        for (i, b) in blocks.enumerated() { height += (i == 0 ? 0 : b.gapBefore) + b.lines.count * b.face.document.cellH }
        var y = top + max(0, (area - height) / 2)
        var out: [Line] = []
        for (i, b) in blocks.enumerated() {
            if i > 0 { y += b.gapBefore }
            for (k, r) in b.lines.enumerated() {
                out.append(line(r, note: b.note, extra: k == b.lines.count - 1 ? b.extra : [], face: b.face, top: y, big: b.big, accent: b.accent,
                                band: b.band))
                y += b.face.document.cellH
            }
        }
        return out
    }

    // MARK: Screens (§5f.11: the largest face that fits its box on one page)

    /// Which face a screen was laid out in.
    public enum FaceKind: String, Sendable, Equatable, CaseIterable { case large, normal, compact }

    /// The body font's faces, largest first (a font without `large` starts at normal).
    public static func faces(_ font: ReaderBoundFont) -> [(FaceKind, ReaderBoundFont.Face)] {
        [font.large.map { (FaceKind.large, $0) }, (.normal, font.normal), font.compact.map { (FaceKind.compact, $0) }].compactMap { $0 }
    }

    /// Lines of `face` in a text box (224 rows).
    public static func boxLines(_ face: ReaderBoundFont.Face) -> Int {
        let h = face.document.cellH
        return max(1, h > 0 ? textBoxHeight / h : 1)
    }

    /// Does `text` fit one page of `box` at `face`?
    public static func fits(_ text: String, face: ReaderBoundFont.Face, band: Band) -> Bool {
        capped(text, face: face, cap: boxLines(face), band: band).extra.isEmpty
    }

    /// A screen laid out, and in which face.
    public struct Laid: Sendable {
        public var screen: Screen
        public var face: ReaderBoundFont.Face
        public var kind: FaceKind
    }

    /// The largest face whose page holds `text` in `box` (nil: none does).
    public static func largestFitting(_ text: String, font: ReaderBoundFont, box: Band) -> (FaceKind, ReaderBoundFont.Face)? {
        faces(font).first { fits(text, face: $0.1, band: box) }
    }

    static func laid(_ text: String, kind: FaceKind, face: ReaderBoundFont.Face, box: Band, flipped: Bool) -> Laid {
        let l = capped(text, face: face, cap: boxLines(face), band: box)
        let lines = stack([Block(note: l.note, lines: l.lines, extra: l.extra, face: face, band: box)],
                          top: textTop(flipped: flipped), area: textBoxHeight)
        return Laid(screen: Screen(lines: lines), face: face, kind: kind)
    }

    /// `text` in `box` in the largest face that fits (the smallest face, cut with "…", when none does).
    public static func layout(_ text: String, font: ReaderBoundFont, box: Band, flipped: Bool) -> Laid {
        let (kind, face) = largestFitting(text, font: font, box: box) ?? faces(font).last!
        return laid(text, kind: kind, face: face, box: box, flipped: flipped)
    }

    /// waits / armed: the prompt beside the back.
    public static func waits(_ bundle: SentenceReader, font: ReaderBoundFont, flipped: Bool = false) -> Laid {
        layout(bundle.text("prompt") ?? "", font: font, box: besideBox(flipped: flipped), flipped: flipped)
    }

    /// §5f.8: the armed screen: `[prompt.armed]` (else the plain prompt), the back beside it.
    public static func armed(_ bundle: SentenceReader, font: ReaderBoundFont, flipped: Bool = false) -> Laid {
        layout(bundle.text("prompt.armed") ?? bundle.text("prompt") ?? "", font: font, box: besideBox(flipped: flipped), flipped: flipped)
    }

    /// A lean screen: full width.
    public static func lean(_ text: String, font: ReaderBoundFont, flipped: Bool = false) -> Laid {
        layout(text, font: font, box: fullBox, flipped: flipped)
    }

    /// A detail: beside its card in the largest face that fits there; when even compact doesn't, no card, full width.
    public static func detail(_ text: String, font: ReaderBoundFont, flipped: Bool = false) -> (laid: Laid, card: Bool) {
        if let (kind, face) = largestFitting(text, font: font, box: besideBox(flipped: flipped)) {
            return (laid(text, kind: kind, face: face, box: besideBox(flipped: flipped), flipped: flipped), true)
        }
        return (lean(text, font: font, flipped: flipped), false)
    }

    /// The "and" screen's one-page test (§5f.7): the body font's normal face, full width.
    public static func fitsLeanPage(_ text: String, face: ReaderBoundFont.Face) -> Bool { fits(text, face: face, band: fullBox) }

    public static func reading(_ card: Int, page: Int, _ bundle: SentenceReader, body: ReaderBoundFont.Face) -> Screen {
        let p = pages(bundle.field(card, .reading) ?? "", face: body)
        guard p.pages.indices.contains(page) else { return Screen(lines: []) }
        let last = page == p.pages.count - 1
        let lines = stack([Block(note: p.note, lines: p.pages[page], extra: last ? p.extra : [], face: body)])
        return Screen(lines: lines, dots: p.pages.count > 1 ? (p.pages.count, page) : nil)
    }

    /// §5f.3: paragraph page `page`, full width, with the dots when there are several.
    public static func paragraph(_ text: String, page: Int, body: ReaderBoundFont.Face) -> Screen {
        let p = paragraphPages(text, face: body)
        guard p.pages.indices.contains(page) else { return Screen(lines: []) }
        let last = page == p.pages.count - 1
        let lines = stack([Block(note: p.note, lines: p.pages[page], extra: last ? p.extra : [], face: body, band: .full)])
        return Screen(lines: lines, dots: p.pages.count > 1 ? (p.pages.count, page) : nil)
    }

    // MARK: The hint (§5f.11)

    /// Every oracle screen carries the corner ▶ but the shuffle.
    public static func hasHint(_ view: OracleView) -> Bool {
        switch view {
        case .shuffleThree, .shuffleOne: false
        default: true
        }
    }

    /// The one ▶ in the BOOT corner, pointing at the button (the clip's `ot_draw_arrow`): rows 1, 3, 5, 7, 9, 7, 5, 3, 1
    /// px wide (clipped to 8), the wide side away from the button.
    public static func paintHint(flipped: Bool, into fb: inout [UInt16]) {
        let o = hintOrigin(flipped: flipped)
        for r in 0..<hintHeight {
            let w = min(9 - 2 * abs(r - 4), hintWidth)
            for k in 0..<w {
                let x = flipped ? o.x + hintWidth - 1 - k : o.x + k
                fb[(o.y + r) * ClipCanvas.width + x] = BrandPalette.accentPixel
            }
        }
    }

    // MARK: Painting

    /// `screen` drawn onto `frame` (white / accent atlases; the dots as filled squares).
    public static func paint(_ screen: Screen, body: ReaderBoundFont.Face, big: ReaderBoundFont.Face?, onto frame: RGB565Frame) -> RGB565Frame {
        var fb = frame.pixels
        let clip = (0, 0, ClipCanvas.width, ClipCanvas.height)
        for l in screen.lines {
            let face = l.big ? (big ?? body) : body
            let atlas = l.accent ? face.accent : face.white
            for (g, x) in zip(l.glyphs, l.xs) {
                guard let g, g < atlas.count else { continue }
                ReaderPreview.blit(atlas[g], x: x, y: l.top, div: 1, into: &fb, clip: clip)
            }
        }
        if let d = screen.dots {
            let total = d.count * dotSize + (d.count - 1) * (dotGap - dotSize)
            var y = (ClipCanvas.height - total) / 2
            for i in 0..<d.count {
                ReaderPreview.fill(&fb, dotX, y, dotX + dotSize, y + dotSize, i == d.current ? BrandPalette.accentPixel : BrandPalette.dimPixel)
                y += dotGap
            }
        }
        return RGB565Frame(width: frame.width, height: frame.height, pixels: fb)
    }
}
