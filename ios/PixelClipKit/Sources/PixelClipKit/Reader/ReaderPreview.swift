import Foundation

/// A reader font as the clip holds it once bound: each size's document and decoded atlas frames.
public struct ReaderBoundFont: Sendable {
    public struct Face: Sendable {
        public var document: ReaderFontDocument.Face
        public var white: [RGB565Frame]
        public var accent: [RGB565Frame]
        /// Code point → atlas frame and advance (`rsvp_face_t.map`).
        let map: [UInt32: (glyph: Int, advance: Int)]
        let qmark: Int?
        let spaceAdvance: Int

        public init(document: ReaderFontDocument.Face, white: [RGB565Frame], accent: [RGB565Frame]) {
            self.document = document; self.white = white; self.accent = accent
            var m: [UInt32: (glyph: Int, advance: Int)] = [:]
            for (i, cp) in document.codePoints.enumerated() where m[cp] == nil {
                m[cp] = (i, i < document.advance.count ? document.advance[i] : 0)
            }
            map = m
            qmark = m[0x3F]?.glyph
            var sp = m[0x20]?.advance ?? document.cellW / 4
            if sp == 0 { sp = max(1, document.cellW / 4) }
            spaceAdvance = sp
        }

        public init(_ f: ReaderFontFace) { self.init(document: f.document, white: f.white, accent: f.accent) }

        /// Atlas frame (nil = nothing drawn) and advance for a code point (`glyph_of`).
        func glyph(_ cp: UInt32) -> (glyph: Int?, advance: Int, missing: Bool) {
            if RSVPText.drawsAsSpace(cp) { return (nil, spaceAdvance, false) }
            if let g = map[cp] { return (g.glyph, g.advance, false) }
            if let q = qmark, let g = map[0x3F] { return (q, g.advance, true) }
            return (nil, max(1, document.cellW / 2), true)
        }
    }

    public var normal: Face
    public var compact: Face?
    /// §5f.11: the large face, when the font has one (the Tarot's body font).
    public var large: Face?

    public init(normal: Face, compact: Face?, large: Face? = nil) { self.normal = normal; self.compact = compact; self.large = large }

    public init(_ font: ReaderFont) {
        normal = Face(font.normal)
        compact = Face(font.compact)
        large = font.large.map(Face.init)
        if !font.accentORP {
            normal.accent = normal.white
            compact?.accent = font.compact.white
            large?.accent = font.large?.white ?? []
        }
    }
}

/// Composes what the clip shows in Reader mode: a port of `core/src/rsvp_paint.c` (layout around the
/// ORP column, normal → compact → shifted/clipped, shared baseline, tick marks, the pause mark and the
/// "fin" card), drawing from the same glyph atlases. Used by the virtual clip and every preview.
public enum ReaderPreview {
    public static let orpX = ReaderFontRenderer.orpX
    public static let margin = ReaderFontRenderer.margin
    /// `RSVP_TICK_COLOR` (#52416B, the brand dim) and `RSVP_PAUSE_COLOR` (#C6A2FF).
    public static let tickColor: UInt16 = 0x520D
    public static let pauseColor: UInt16 = 0xC51F
    static let tickLength = 12, tickGap = 4
    static let maxPlace = RSVPText.maxWordGlyphs * 2

    // MARK: Geometry (rsvp_painter_init)

    public struct Geometry: Sendable, Equatable {
        public var bandY: Int
        public var bandH: Int
        public var baselineY: Int
        public var pauseBox: (x: Int, y: Int, w: Int, h: Int)
        public static func == (a: Geometry, b: Geometry) -> Bool {
            a.bandY == b.bandY && a.bandH == b.bandH && a.baselineY == b.baselineY && a.pauseBox == b.pauseBox
        }
    }

    public static func geometry(_ f: ReaderBoundFont) -> Geometry {
        var asc = f.normal.document.baseline
        var desc = f.normal.document.cellH - f.normal.document.baseline
        if let c = f.compact {
            asc = max(asc, c.document.baseline)
            desc = max(desc, c.document.cellH - c.document.baseline)
        }
        let h = min(max(asc + desc, 1), ClipCanvas.height)
        let y = (ClipCanvas.height - h) / 2
        return Geometry(bandY: y, bandH: h, baselineY: y + asc, pauseBox: (ClipCanvas.width - 8 - 30, 6, 30, 30))
    }

    // MARK: Layout (rsvp_layout)

    public struct Placed: Sendable, Equatable {
        public var x: Int
        public var glyph: Int?
        public var advance: Int
        public var accent: Bool
    }

    public struct Layout: Sendable, Equatable {
        public var glyphs: [Placed]
        public var orp: Int
        /// The normal size didn't fit.
        public var compact: Bool
        /// Moved to fit (the ORP left its column).
        public var shifted: Bool
        /// Wider than the screen even in the smaller size.
        public var clipped: Bool
        /// Pen extent.
        public var textX0: Int
        public var textX1: Int
    }

    static func codePoints(_ word: String) -> [UInt32] { Array(word.unicodeScalars.prefix(maxPlace).map(\.value)) }

    /// ORP from the code points with the tokeniser's lead/core rule (`orp_of`).
    static func orp(_ cps: [UInt32]) -> Int {
        var first = -1, last = -1
        for (i, cp) in cps.enumerated() where RSVPText.charClass(cp) == .letter {
            if first < 0 { first = i }
            last = i
        }
        guard !cps.isEmpty else { return 0 }
        let o = first >= 0 ? first + ORP.index(forLength: last - first + 1) : ORP.index(forLength: cps.count)
        return min(o, cps.count - 1)
    }

    public static func layout(_ word: String, font: ReaderBoundFont) -> (Layout, ReaderBoundFont.Face)? {
        let cps = codePoints(word)
        guard !cps.isEmpty else { return nil }
        let orp = orp(cps)
        let faces = [font.normal] + (font.compact.map { [$0] } ?? [])
        var chosen = font.normal
        var placed: [Placed] = []
        var left = 0, total = 0
        var compact = false, shifted = false, clipped = false
        for (k, face) in faces.enumerated() {
            var pen = 0
            placed = cps.map { cp in
                let g = face.glyph(cp)
                defer { pen += g.advance }
                return Placed(x: pen, glyph: g.glyph, advance: g.advance, accent: false)
            }
            total = pen
            left = orpX - placed[orp].x - placed[orp].advance / 2
            chosen = face
            compact = k == 1
            if left >= margin && left + total <= ClipCanvas.width - margin { break }
            if k == faces.count - 1 {
                if total <= ClipCanvas.width - 2 * margin {
                    var l2 = max(left, margin)
                    if l2 + total > ClipCanvas.width - margin { l2 = ClipCanvas.width - margin - total }
                    left = l2
                    shifted = true
                } else {
                    clipped = true
                }
                break
            }
        }
        for i in placed.indices {
            placed[i].x += left
            placed[i].accent = i == orp
        }
        return (Layout(glyphs: placed, orp: orp, compact: compact, shifted: shifted, clipped: clipped,
                       textX0: left, textX1: left + total), chosen)
    }

    // MARK: Painting

    /// The screen showing `word` (nil: the blank band of a paragraph pause), as `rsvp_paint` after a
    /// full repaint, plus the pause mark when `paused`.
    public static func frame(word: String?, font: ReaderBoundFont, paused: Bool = false) -> RGB565Frame {
        let g = geometry(font)
        var fb = [UInt16](repeating: 0, count: ClipCanvas.width * ClipCanvas.height)
        drawTicks(&fb, g)
        if let word, let (lay, face) = layout(word, font: font) {
            let y = g.baselineY - face.document.baseline
            for p in lay.glyphs {
                guard let gi = p.glyph else { continue }
                let atlas = p.accent ? face.accent : face.white
                guard gi < atlas.count else { continue }
                blit(atlas[gi], x: p.x, y: y, div: 1, into: &fb, clip: (0, g.bandY, ClipCanvas.width, g.bandY + g.bandH))
            }
        }
        if paused { drawPause(&fb, g) }
        return RGB565Frame(width: ClipCanvas.width, height: ClipCanvas.height, pixels: fb)
    }

    /// The "fin" card (`rsvp_paint_end_card`): "fin" in the accent atlas above "1 234 words · 4 min",
    /// each in the largest size (normal, compact, then 1/2, 1/3, 1/4 subsampled) that fits.
    public static func endCard(words: Int, minutes: Int, font: ReaderBoundFont) -> RGB565Frame {
        var fb = [UInt16](repeating: 0, count: ClipCanvas.width * ClipCanvas.height)
        let l1: [UInt32] = [0x66, 0x69, 0x6E]
        let l2 = codePoints(RSVPTiming.endCardText(words: words, minutes: minutes))
        var cand: [(face: ReaderBoundFont.Face, div: Int)] = []
        for div in 1...4 {
            cand.append((font.normal, div))
            if let c = font.compact { cand.append((c, div)) }
        }
        // Stable insertion sort by output height, descending (as the C code does).
        var sorted: [(face: ReaderBoundFont.Face, div: Int)] = []
        for c in cand {
            let h = c.face.document.cellH / c.div
            let i = sorted.firstIndex { $0.face.document.cellH / $0.div < h } ?? sorted.count
            sorted.insert(c, at: i)
        }
        let avail = ClipCanvas.width - 2 * margin
        func width(_ face: ReaderBoundFont.Face, _ cps: [UInt32], _ div: Int) -> Int { cps.reduce(0) { $0 + face.glyph($1).advance / div } }
        var s1 = sorted.last!, s2 = sorted.last!
        for c in sorted.reversed() {
            if width(c.face, l1, c.div) <= avail { s1 = c }
            if width(c.face, l2, c.div) <= avail { s2 = c }
        }
        let h1 = s1.face.document.cellH / s1.div, h2 = s2.face.document.cellH / s2.div, gap = 10
        let y1 = (ClipCanvas.height - (h1 + gap + h2)) / 2, y2 = y1 + h1 + gap
        func draw(_ s: (face: ReaderBoundFont.Face, div: Int), _ cps: [UInt32], accent: Bool, y: Int) {
            var x = (ClipCanvas.width - width(s.face, cps, s.div)) / 2
            for cp in cps {
                let g = s.face.glyph(cp)
                let atlas = accent ? s.face.accent : s.face.white
                if let gi = g.glyph, gi < atlas.count {
                    blit(atlas[gi], x: x, y: y, div: s.div, into: &fb, clip: (0, 0, ClipCanvas.width, ClipCanvas.height))
                }
                x += g.advance / s.div
            }
        }
        draw(s1, l1, accent: true, y: y1)
        draw(s2, l2, accent: false, y: y2)
        return RGB565Frame(width: ClipCanvas.width, height: ClipCanvas.height, pixels: fb)
    }

    static func drawTicks(_ fb: inout [UInt16], _ g: Geometry) {
        let H = ClipCanvas.height
        let x0 = max(0, orpX - 1), x1 = min(ClipCanvas.width, orpX + 1)
        let a0 = min(max(g.bandY - tickGap - tickLength, 0), H), a1 = min(max(g.bandY - tickGap, 0), H)
        let b0 = min(max(g.bandY + g.bandH + tickGap, 0), H), b1 = min(max(b0 + tickLength, 0), H)
        fill(&fb, x0, a0, x1, a1, tickColor)
        fill(&fb, x0, b0, x1, b1, tickColor)
    }

    /// The 5×7 two-bar mark ×3 in the accent, right-aligned in the corner box (`rsvp_paint_pause`;
    /// our fonts carry no U+23F8 glyph).
    static func drawPause(_ fb: inout [UInt16], _ g: Geometry) {
        let b = g.pauseBox
        let cols: [UInt8] = [0x7F, 0x7F, 0x00, 0x7F, 0x7F]
        let s = 3
        let x0 = b.x + b.w - 5 * s, y0 = b.y + (b.h - 7 * s) / 2
        for (col, bits) in cols.enumerated() {
            for row in 0..<7 where bits & (1 << row) != 0 {
                fill(&fb, x0 + col * s, y0 + row * s, x0 + col * s + s, y0 + row * s + s, pauseColor)
            }
        }
    }

    static func fill(_ fb: inout [UInt16], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ px: UInt16) {
        let W = ClipCanvas.width
        guard x1 > x0, y1 > y0 else { return }
        for y in max(0, y0)..<min(ClipCanvas.height, y1) {
            for x in max(0, x0)..<min(W, x1) { fb[y * W + x] = px }
        }
    }

    /// Copies the cell's non-black pixels (subsampled by `div`) with its top-left at (x, y).
    static func blit(_ cell: RGB565Frame, x: Int, y: Int, div: Int, into fb: inout [UInt16], clip: (Int, Int, Int, Int)) {
        let W = ClipCanvas.width
        let ow = cell.width / div, oh = cell.height / div
        let ox0 = max(0, clip.0 - x), ox1 = min(ow, clip.2 - x)
        let oy0 = max(0, clip.1 - y), oy1 = min(oh, clip.3 - y)
        guard ox0 < ox1, oy0 < oy1 else { return }
        cell.pixels.withUnsafeBufferPointer { src in
            fb.withUnsafeMutableBufferPointer { dst in
                for oy in oy0..<oy1 {
                    let row = oy * div * cell.width
                    let d = (y + oy) * W + x
                    for ox in ox0..<ox1 {
                        let px = src[row + ox * div]
                        if px != 0 { dst[d + ox] = px }
                    }
                }
            }
        }
    }
}
