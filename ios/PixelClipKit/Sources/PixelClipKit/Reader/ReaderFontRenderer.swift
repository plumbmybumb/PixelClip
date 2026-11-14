import CoreGraphics
import CoreText
import Foundation

/// One size of a rendered reader font: the §5c face document plus its decoded glyph frames.
public struct ReaderFontFace: Sendable {
    public var document: ReaderFontDocument.Face
    public var white: [RGB565Frame]
    public var accent: [RGB565Frame]
    /// Point size it was rendered at and the typeface's cap height there (for the report and tests).
    public var pointSize: Double
    public var capHeight: Double

    public init(document: ReaderFontDocument.Face, white: [RGB565Frame], accent: [RGB565Frame], pointSize: Double, capHeight: Double) {
        self.document = document; self.white = white; self.accent = accent; self.pointSize = pointSize; self.capHeight = capHeight
    }
}

/// A reader font ready to upload: four glyph atlases (normal/compact × white/accent) with
/// content-hashed ids `reader-font-<hash>-{n,na,c,ca}` and the font document that ties them together.
public struct ReaderFont: Sendable {
    /// The `PUT /fonts/{id}` id: `reader-font-<hash>`, or `reader-font-<hash>-w` when the ORP is drawn
    /// in white (its document then points both atlas keys at the white atlases).
    public var id: String
    /// Shared by the atlases of this typeface and size pair (independent of the ORP toggle).
    public var hash: String
    public var name: String
    public var accentORP: Bool
    /// `reader-font-` (Reader), `tarot-font…` / `tarot-big…` (the Tarot): the start of every id.
    public var prefix: String
    public var document: ReaderFontDocument
    public var normal: ReaderFontFace
    public var compact: ReaderFontFace
    /// §5f.11: the optional third face (the Tarot's body font), after compact in `allAtlases`.
    public var large: ReaderFontFace?
    /// All atlases: normal white, normal accent, compact white, compact accent (and large white, large accent).
    public var allAtlases: [LocalAsset]

    /// What the clip needs, in upload order (white before accent, normal before compact before large). Without the
    /// accent ORP only the white atlases.
    public var atlases: [LocalAsset] { accentORP ? allAtlases : allAtlases.enumerated().filter { $0.offset % 2 == 0 }.map(\.element) }

    public var atlasBytes: Int { atlases.reduce(0) { $0 + $1.data.count } }

    public init(hash: String, name: String, accentORP: Bool, normal: ReaderFontFace, compact: ReaderFontFace, large: ReaderFontFace? = nil,
                allAtlases: [LocalAsset], prefix: String = ReaderFontRenderer.assetPrefix) {
        self.hash = hash; self.name = name; self.accentORP = accentORP; self.normal = normal; self.compact = compact; self.large = large
        self.allAtlases = allAtlases
        self.prefix = prefix
        id = ReaderFontRenderer.fontID(hash: hash, accentORP: accentORP, prefix: prefix)
        document = ReaderFontRenderer.document(normal: normal.document, compact: compact.document, large: large?.document, hash: hash,
                                               accentORP: accentORP, prefix: prefix)
    }

    /// Rebuilds a font from its four stored atlases (normal white/accent, compact white/accent) and
    /// the two face documents.
    public static func restore(hash: String, name: String, accentORP: Bool, normal: ReaderFontDocument.Face, compact: ReaderFontDocument.Face,
                               normalSize: Double, compactSize: Double, normalCap: Double, compactCap: Double,
                               atlases: [Data], prefix: String = ReaderFontRenderer.assetPrefix) throws -> ReaderFont {
        guard atlases.count == 4 else { throw ReaderFontRenderer.RenderError.encoding }
        let frames = try atlases.map { try HCAFile(data: $0).decodeAllFrames() }
        let ids = ReaderFontRenderer.atlasIDs(hash: hash, prefix: prefix)
        let assets = zip([ids.n, ids.na, ids.c, ids.ca], atlases).map { LocalAsset(id: $0, data: $1, name: name) }
        return ReaderFont(hash: hash, name: name, accentORP: accentORP,
                          normal: ReaderFontFace(document: normal, white: frames[0], accent: frames[1], pointSize: normalSize, capHeight: normalCap),
                          compact: ReaderFontFace(document: compact, white: frames[2], accent: frames[3], pointSize: compactSize, capHeight: compactCap),
                          allAtlases: assets, prefix: prefix)
    }

    /// The same atlases with the ORP in white (or back in the accent).
    public func withAccentORP(_ on: Bool) -> ReaderFont {
        guard on != accentORP else { return self }
        var f = self
        f.accentORP = on
        f.id = ReaderFontRenderer.fontID(hash: hash, accentORP: on, prefix: prefix)
        f.document = ReaderFontRenderer.document(normal: normal.document, compact: compact.document, large: large?.document, hash: hash,
                                                 accentORP: on, prefix: prefix)
        return f
    }
}

/// Renders a reader font from any catalogue typeface with Core Text at scale 1 (no smoothing, no
/// subpixel positioning, integer baselines), quantised to RGB565 without dithering and encoded with
/// the HCA encoder.
///
/// Layout contract (PROTOCOL §5c, `core/include/rsvp.h`): glyph `i` of every atlas is the i-th code
/// point of `glyphs`; it is drawn with its pen origin at the cell's left edge and its baseline
/// `baseline` px below the cell top; black pixels are transparent. Each cell is centred on the
/// typeface's cap band (so capitals sit on the screen's centre line when the clip centres the band).
public enum ReaderFontRenderer {
    /// ORP column and the fit margin (`RSVP_ORP_X`, the painter's 8 px margin).
    public static let orpX = 230
    public static let margin = 8

    /// The normal size: a 12-glyph word fits with its ORP pinned at x = 230, capitals at most 96 px.
    public static let normalReference = "connaissance"
    public static let normalCapMax = 96.0
    /// The compact size, for longer words: a 20-glyph word fits, capitals at most 64 px.
    public static let compactReference = "internationalisation"
    public static let compactCapMax = 64.0

    /// The glyph set: printable ASCII, Latin-1 (French accents, « », ·, no-break space), Œ œ Ÿ, curly
    /// quotes, dashes, …, •, ‹ ›, € and ™ — 210 code points (the clip allows 256).
    public static let glyphs: String = {
        var scalars: [Unicode.Scalar] = []
        scalars += (0x20...0x7E).compactMap(Unicode.Scalar.init)
        scalars += (0xA0...0xFF).compactMap(Unicode.Scalar.init)
        let extras: [UInt32] = [0x0152, 0x0153, 0x0178, 0x2010, 0x2011, 0x2013, 0x2014, 0x2018, 0x2019, 0x201A,
                                0x201C, 0x201D, 0x201E, 0x2022, 0x2026, 0x2039, 0x203A, 0x20AC, 0x2122]
        scalars += extras.compactMap(Unicode.Scalar.init)
        var s = String.UnicodeScalarView()
        s.append(contentsOf: scalars)
        return String(s)
    }()

    public enum RenderError: Error, Equatable { case noFit, encoding }

    /// Render both sizes and colours.
    /// - Parameters:
    ///   - name: the typeface's display name (kept with the font, not sent).
    ///   - accent: the ORP colour (the brand accent).
    ///   - makeFont: the typeface at a point size (the app resolves system designs with UIKit).
    public static func render(name: String, accentORP: Bool = true, accent: RGBAColor = .accent,
                              makeFont: (CGFloat) -> CTFont) throws -> ReaderFont {
        let normalSize = fitSize(reference: normalReference, capMax: normalCapMax, makeFont: makeFont)
        let compactSize = min(normalSize, fitSize(reference: compactReference, capMax: compactCapMax, makeFont: makeFont))
        return try render(name: name, accentORP: accentORP, accent: accent, normalSize: normalSize, compactSize: compactSize,
                          makeFont: makeFont)
    }

    /// Render at two given point sizes, with any glyph set and id prefix (the Tarot's fonts use this with
    /// their own sizes and prefixes).
    public static func render(name: String, accentORP: Bool = true, accent: RGBAColor = .accent,
                              normalSize: CGFloat, compactSize: CGFloat, largeSize: CGFloat? = nil, glyphs: String = ReaderFontRenderer.glyphs,
                              prefix: String = ReaderFontRenderer.assetPrefix, makeFont: (CGFloat) -> CTFont) throws -> ReaderFont {
        let n = renderFace(makeFont(normalSize), size: normalSize, accent: accent, glyphs: glyphs)
        let c = renderFace(makeFont(compactSize), size: compactSize, accent: accent, glyphs: glyphs)
        let l = largeSize.map { renderFace(makeFont($0), size: $0, accent: accent, glyphs: glyphs) }
        func encode(_ frames: [RGB565Frame]) throws -> Data {
            do { return try HCAEncoder.encode(frames: frames.map { .init(pixels: $0, durationMs: 0) }, glyphAtlas: true) } catch {
                throw RenderError.encoding
            }
        }
        let nData = try encode(n.white), naData = try encode(n.accent), cData = try encode(c.white), caData = try encode(c.accent)
        let lData = try l.map { try encode($0.white) }, laData = try l.map { try encode($0.accent) }
        var all = Data(glyphs.utf8)
        for d in [nData, naData, cData, caData] + [lData, laData].compactMap({ $0 }) { all.append(d) }
        let hash = String(Hashing.sha256Hex(all).prefix(8))
        let ids = atlasIDs(hash: hash, prefix: prefix)
        var normalDoc = n.doc, compactDoc = c.doc
        normalDoc.atlasWhite = ids.n; normalDoc.atlasAccent = ids.na
        compactDoc.atlasWhite = ids.c; compactDoc.atlasAccent = ids.ca
        let normal = ReaderFontFace(document: normalDoc, white: n.white, accent: n.accent, pointSize: Double(normalSize),
                                    capHeight: Double(CTFontGetCapHeight(makeFont(normalSize))))
        let compact = ReaderFontFace(document: compactDoc, white: c.white, accent: c.accent, pointSize: Double(compactSize),
                                     capHeight: Double(CTFontGetCapHeight(makeFont(compactSize))))
        let label = prefix == assetPrefix ? "reader" : "font"
        var allAssets = [LocalAsset(id: ids.n, data: nData, name: "\(name) · \(label)"),
                         LocalAsset(id: ids.na, data: naData, name: "\(name) · \(label) accent"),
                         LocalAsset(id: ids.c, data: cData, name: "\(name) · \(label) compact"),
                         LocalAsset(id: ids.ca, data: caData, name: "\(name) · \(label) compact accent")]
        var large: ReaderFontFace?
        if let l, let lData, let laData, let largeSize {
            let lids = largeAtlasIDs(hash: hash, prefix: prefix)
            var doc = l.doc
            doc.atlasWhite = lids.l; doc.atlasAccent = lids.la
            large = ReaderFontFace(document: doc, white: l.white, accent: l.accent, pointSize: Double(largeSize),
                                   capHeight: Double(CTFontGetCapHeight(makeFont(largeSize))))
            allAssets += [LocalAsset(id: lids.l, data: lData, name: "\(name) · \(label) large"),
                          LocalAsset(id: lids.la, data: laData, name: "\(name) · \(label) large accent")]
        }
        return ReaderFont(hash: hash, name: name, accentORP: accentORP, normal: normal, compact: compact, large: large,
                          allAtlases: allAssets, prefix: prefix)
    }

    /// `reader-font-<hash>-n`, `-na`, `-c`, `-ca` (or the same under another prefix).
    public static func atlasIDs(hash: String, prefix: String = assetPrefix) -> (n: String, na: String, c: String, ca: String) {
        let base = "\(prefix)\(hash)"
        return ("\(base)-n", "\(base)-na", "\(base)-c", "\(base)-ca")
    }

    /// §5f.11 the large face's atlases: `…-l`, `…-la`.
    public static func largeAtlasIDs(hash: String, prefix: String = assetPrefix) -> (l: String, la: String) {
        ("\(prefix)\(hash)-l", "\(prefix)\(hash)-la")
    }

    /// Every reader-font asset starts with this (protected from the sync's orphan clean-up).
    public static let assetPrefix = "reader-font-"

    public static func fontID(hash: String, accentORP: Bool, prefix: String = assetPrefix) -> String {
        "\(prefix)\(hash)\(accentORP ? "" : "-w")"
    }

    /// The hash inside a font or atlas id (`reader-font-<hash>…`, or under another prefix).
    public static func hash(inID id: String, prefix: String = assetPrefix) -> String? {
        guard id.hasPrefix(prefix) else { return nil }
        let rest = id.dropFirst(prefix.count)
        let h = rest.prefix { $0 != "-" }
        return h.count == 8 ? String(h) : nil
    }

    static func document(normal: ReaderFontDocument.Face, compact: ReaderFontDocument.Face, large: ReaderFontDocument.Face? = nil,
                         hash: String, accentORP: Bool, prefix: String = assetPrefix) -> ReaderFontDocument {
        let ids = atlasIDs(hash: hash, prefix: prefix)
        var n = normal, c = compact
        n.atlasWhite = ids.n; c.atlasWhite = ids.c
        n.atlasAccent = accentORP ? ids.na : ids.n
        c.atlasAccent = accentORP ? ids.ca : ids.c
        var l = large
        if l != nil {
            let lids = largeAtlasIDs(hash: hash, prefix: prefix)
            l!.atlasWhite = lids.l
            l!.atlasAccent = accentORP ? lids.la : lids.l
        }
        return ReaderFontDocument(normal: n, compact: c, large: l)
    }

    // MARK: Sizing

    /// Integer pen advance of each glyph at this size (Core Text, no kerning: the clip can't kern).
    static func advance(_ s: String, _ font: CTFont) -> Int {
        Int(CTLineGetTypographicBounds(line(s, font), nil, nil, nil).rounded())
    }

    static func line(_ s: String, _ font: CTFont, _ color: CGColor? = nil) -> CTLine {
        var attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if let color { attrs[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    }

    /// Whether `word` fits on the clip with its ORP centred on x = 230 (the painter's test).
    static func fits(_ word: String, font: CTFont) -> Bool {
        let w = RSVPText(body: word).words.first
        let scalars = Array(word.unicodeScalars)
        let adv = scalars.map { advance(String($0), font) }
        let orp = min(w?.orp ?? 0, max(0, adv.count - 1))
        let pen = adv.prefix(orp).reduce(0, +)
        let total = adv.reduce(0, +)
        let left = orpX - pen - (adv.isEmpty ? 0 : adv[orp] / 2)
        return left >= margin && left + total <= ClipCanvas.width - margin
    }

    /// The largest whole point size whose capitals stay under `capMax` and where `reference` fits.
    static func fitSize(reference: String, capMax: Double, makeFont: (CGFloat) -> CTFont) -> CGFloat {
        func ok(_ s: Int) -> Bool {
            let f = makeFont(CGFloat(s))
            return Double(CTFontGetCapHeight(f)) <= capMax && fits(reference, font: f)
        }
        var lo = 6, hi = 400
        if !ok(lo) { return CGFloat(lo) }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if ok(mid) { lo = mid } else { hi = mid - 1 }
        }
        return CGFloat(lo)
    }

    // MARK: Rendering

    struct RenderedFace {
        var doc: ReaderFontDocument.Face
        var white: [RGB565Frame]
        var accent: [RGB565Frame]
    }

    static func renderFace(_ font: CTFont, size: CGFloat, accent: RGBAColor, glyphs: String = ReaderFontRenderer.glyphs) -> RenderedFace {
        let scalars = Array(glyphs.unicodeScalars)
        let strings = scalars.map { String($0) }
        let lines = strings.map { line($0, font, CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)) }
        let advances = lines.map { Int(CTLineGetTypographicBounds($0, nil, nil, nil).rounded()) }
        // Ink extents over the whole set (accented capitals, descenders, fallback glyphs).
        var above: CGFloat = 0, below: CGFloat = 0, right: CGFloat = 0
        for (l, a) in zip(lines, advances) {
            let ink = CTLineGetBoundsWithOptions(l, .useGlyphPathBounds)
            guard !ink.isNull, ink.width > 0 else { right = max(right, CGFloat(a)); continue }
            above = max(above, ink.maxY)
            below = max(below, -ink.minY)
            right = max(right, ink.maxX, CGFloat(a))
        }
        let capMid = CTFontGetCapHeight(font) / 2
        let half = min(ClipCanvas.height / 2, Int(ceil(max(above - capMid, below + capMid))) + 1)
        let cellH = 2 * half
        let baseline = min(cellH, Int((CGFloat(half) + capMid).rounded()))
        let cellW = min(ClipCanvas.width, max(1, Int(ceil(right)) + 1))

        var white: [RGB565Frame] = [], tinted: [RGB565Frame] = []
        white.reserveCapacity(lines.count); tinted.reserveCapacity(lines.count)
        let (ar, ag, ab, _) = accent.withAlpha(1).premultipliedBytes
        for l in lines {
            // White glyph on transparent: alpha = coverage.
            let cov = Raster.draw(width: cellW, height: cellH) { ctx in
                ctx.textMatrix = .identity
                ctx.textPosition = CGPoint(x: 0, y: CGFloat(cellH - baseline))
                CTLineDraw(l, ctx)
            }
            var w = [UInt8](repeating: 255, count: cellW * cellH * 4)
            var t = w
            for i in 0..<(cellW * cellH) {
                let a = UInt32(cov.bytes[i * 4 + 3])
                let o = i * 4
                w[o] = UInt8(a); w[o + 1] = UInt8(a); w[o + 2] = UInt8(a)
                t[o] = UInt8((UInt32(ar) * a + 127) / 255)
                t[o + 1] = UInt8((UInt32(ag) * a + 127) / 255)
                t[o + 2] = UInt8((UInt32(ab) * a + 127) / 255)
            }
            white.append(ClipRenderer.quantize(RGBA8Image(width: cellW, height: cellH, bytes: w), mode: .none))
            tinted.append(ClipRenderer.quantize(RGBA8Image(width: cellW, height: cellH, bytes: t), mode: .none))
        }
        let doc = ReaderFontDocument.Face(glyphs: glyphs, advance: advances.map { min(max($0, 0), 1024) }, cellW: cellW, cellH: cellH,
                                          baseline: baseline, atlasWhite: "", atlasAccent: "")
        return RenderedFace(doc: doc, white: white, accent: tinted)
    }
}
