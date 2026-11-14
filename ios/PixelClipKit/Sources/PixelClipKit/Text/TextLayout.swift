import CoreGraphics
import CoreText
import Foundation

/// One positioned glyph. Colour glyphs (emoji) have no outline path and are drawn as bitmaps.
public struct LaidGlyph: @unchecked Sendable {
    public let font: CTFont
    public let glyph: CGGlyph
    /// Relative to the line's baseline origin, y-up.
    public let position: CGPoint
    /// Glyph ink box relative to `position`.
    public let bounds: CGRect
    public let isColor: Bool
    /// UTF-16 offset into the whole text.
    public let stringIndex: Int
}

public struct LaidLine: @unchecked Sendable {
    public let line: CTLine
    public let glyphs: [LaidGlyph]
    /// Typographic advance width (includes tracking).
    public let width: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    /// Union of glyph ink, relative to the baseline origin (y-up). `.null` for an empty line.
    public let ink: CGRect
    /// UTF-16 range of this line within the whole text.
    public let range: Range<Int>

    /// x of the caret before UTF-16 offset `index` (whole-text offset).
    public func caretX(_ index: Int) -> CGFloat {
        CTLineGetOffsetForStringIndex(line, max(0, index - range.lowerBound), nil)
    }
}

/// Lines of text laid out with CoreText at one size. Line i's baseline is `i * lineHeight` below
/// line 0's.
public struct TextLayout: @unchecked Sendable {
    public let lines: [LaidLine]
    public let size: CGFloat
    public let lineHeight: CGFloat

    /// Ink of all lines relative to line 0's baseline origin (y-up), lines left-aligned at x = 0.
    public var blockInk: CGRect {
        var r = CGRect.null
        for (i, l) in lines.enumerated() where !l.ink.isNull {
            r = r.union(l.ink.offsetBy(dx: 0, dy: -CGFloat(i) * lineHeight))
        }
        return r
    }

    /// Widest line's ink width (0 when there's no ink).
    public var maxInkWidth: CGFloat { lines.map { $0.ink.isNull ? 0 : $0.ink.width }.max() ?? 0 }
    public var glyphCount: Int { lines.reduce(0) { $0 + $1.glyphs.count } }
    public var isEmpty: Bool { blockInk.isNull }
}

public enum TextLayoutEngine {
    /// Lay out `text` (split on newlines) in `font` at `size`, with `tracking` in ems.
    /// Characters the font lacks (emoji, other scripts) fall back through CoreText's cascade.
    public static func layout(_ text: String, font: CTFont, size: CGFloat, tracking: Double = 0) -> TextLayout {
        let sized = CTFontCreateCopyWithAttributes(font, size, nil, nil)
        let ns = text as NSString
        var lines: [LaidLine] = []
        var start = 0
        var ranges: [Range<Int>] = []
        while start <= ns.length {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: start, length: ns.length - start))
            let end = r.location == NSNotFound ? ns.length : r.location
            ranges.append(start..<end)
            if r.location == NSNotFound { break }
            start = end + 1
        }
        for range in ranges {
            let sub = ns.substring(with: NSRange(location: range.lowerBound, length: range.count))
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: sized,
                kCTKernAttributeName: tracking * Double(size),
                kCTForegroundColorFromContextAttributeName: true,
            ]
            let attributed = CFAttributedStringCreate(nil, sub as CFString, attrs as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attributed)
            lines.append(laidLine(line, offset: range.lowerBound, range: range))
        }
        let ascent = CTFontGetAscent(sized), descent = CTFontGetDescent(sized), leading = CTFontGetLeading(sized)
        return TextLayout(lines: lines, size: size, lineHeight: (ascent + descent + max(leading, size * 0.08)).rounded())
    }

    private static func laidLine(_ line: CTLine, offset: Int, range: Range<Int>) -> LaidLine {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        var glyphs: [LaidGlyph] = []
        var ink = CGRect.null
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let fontRef = attrs[kCTFontAttributeName as String] else { continue }
            let font = fontRef as! CTFont
            let isColor = CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
            var g = [CGGlyph](repeating: 0, count: n)
            var p = [CGPoint](repeating: .zero, count: n)
            var idx = [CFIndex](repeating: 0, count: n)
            var boxes = [CGRect](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &g)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &p)
            CTRunGetStringIndices(run, CFRange(location: 0, length: n), &idx)
            CTFontGetBoundingRectsForGlyphs(font, .horizontal, g, &boxes, n)
            for k in 0..<n {
                let b = boxes[k]
                glyphs.append(LaidGlyph(font: font, glyph: g[k], position: p[k], bounds: b, isColor: isColor,
                                        stringIndex: offset + idx[k]))
                if b.width > 0.01 && b.height > 0.01 { ink = ink.union(b.offsetBy(dx: p[k].x, dy: p[k].y)) }
            }
        }
        return LaidLine(line: line, glyphs: glyphs, width: width, ascent: ascent, descent: descent, ink: ink, range: range)
    }
}

/// Fill, outline and glow, all in output pixels.
public struct TextStyle: Sendable, Hashable {
    public var fill: TextFill
    public var outlineWidth: Double
    public var outlineColor: RGBAColor
    public var glowRadius: Double
    public var glowColor: RGBAColor

    public init(fill: TextFill, outlineWidth: Double = 0, outlineColor: RGBAColor = .black,
                glowRadius: Double = 0, glowColor: RGBAColor = .accent) {
        self.fill = fill; self.outlineWidth = outlineWidth; self.outlineColor = outlineColor
        self.glowRadius = glowRadius; self.glowColor = glowColor
    }

    /// How far paint can reach past the glyph ink.
    public var bleed: CGFloat { CGFloat(outlineWidth + glowRadius * 2) + 2 }
}

public enum TextPainter {
    /// Draw `layout` into a y-up context. `origins[i]` is line i's baseline origin.
    /// `include` filters glyphs (typewriter reveal); `offset` moves individual glyphs (bounce),
    /// both keyed by the glyph's running index across lines.
    public static func draw(_ layout: TextLayout, in ctx: CGContext, origins: [CGPoint], style: TextStyle,
                            include: ((Int, LaidGlyph) -> Bool)? = nil,
                            offset: ((Int, LaidGlyph) -> CGPoint)? = nil) {
        let path = CGMutablePath()
        var color: [(CTFont, CGGlyph, CGPoint)] = []
        var box = CGRect.null
        var running = 0
        for (li, line) in layout.lines.enumerated() where li < origins.count {
            let o = origins[li]
            for g in line.glyphs {
                defer { running += 1 }
                if let include, !include(running, g) { continue }
                let d = offset?(running, g) ?? .zero
                let p = CGPoint(x: o.x + g.position.x + d.x, y: o.y + g.position.y + d.y)
                if g.isColor {
                    color.append((g.font, g.glyph, p))
                    if g.bounds.width > 0 { box = box.union(g.bounds.offsetBy(dx: p.x, dy: p.y)) }
                } else {
                    var t = CGAffineTransform(translationX: p.x, y: p.y)
                    if let gp = CTFontCreatePathForGlyph(g.font, g.glyph, &t) { path.addPath(gp) }
                }
            }
        }
        if !path.isEmpty { box = box.union(path.boundingBoxOfPath) }
        guard !box.isNull else { return }

        func paint() {
            if !path.isEmpty {
                if style.outlineWidth > 0 {
                    ctx.addPath(path)
                    ctx.setLineWidth(CGFloat(style.outlineWidth * 2))
                    ctx.setLineJoin(.round)
                    ctx.setLineCap(.round)
                    ctx.setStrokeColor(style.outlineColor.cgColor)
                    ctx.strokePath()
                }
                switch style.fill {
                case .solid(let c):
                    ctx.addPath(path)
                    ctx.setFillColor(c.cgColor)
                    ctx.fillPath()
                case .gradient(let a, let b, let vertical):
                    ctx.saveGState()
                    ctx.addPath(path)
                    ctx.clip()
                    Raster.fillGradient(ctx, in: box.insetBy(dx: -1, dy: -1), from: a, to: b, vertical: vertical)
                    ctx.restoreGState()
                }
            }
            ctx.textMatrix = .identity
            var i = 0
            while i < color.count {
                let font = color[i].0
                var glyphs: [CGGlyph] = [], positions: [CGPoint] = []
                while i < color.count && CFEqual(color[i].0, font) {
                    glyphs.append(color[i].1); positions.append(color[i].2); i += 1
                }
                CTFontDrawGlyphs(font, glyphs, positions, glyphs.count, ctx)
            }
        }

        if style.glowRadius > 0 && style.glowColor.a > 0 {
            // Two shadowed passes: a single CG shadow is too faint to read as light.
            for _ in 0..<2 {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: CGFloat(style.glowRadius), color: style.glowColor.cgColor)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                paint()
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
        } else {
            paint()
        }
    }

    /// Font size that makes `layout` (laid out at `layout.size`) fill `height` (and `width`, when
    /// given) with its ink.
    public static func fitSize(_ layout: TextLayout, width: CGFloat?, height: CGFloat) -> CGFloat {
        let ink = layout.blockInk
        guard !ink.isNull, ink.height > 0.5 else { return height * 0.7 }
        var scale = height / ink.height
        if let width, ink.width > 0.5 { scale = min(scale, width / max(layout.maxInkWidth, 0.5)) }
        return layout.size * scale
    }

    /// Baseline origins that centre each line's ink horizontally and the block's ink vertically
    /// about `center` (y-up context coordinates).
    public static func centredOrigins(_ layout: TextLayout, center: CGPoint) -> [CGPoint] {
        let ink = layout.blockInk
        guard !ink.isNull else { return layout.lines.map { _ in center } }
        let baseline0 = center.y - (ink.minY + ink.height / 2)
        return layout.lines.enumerated().map { i, l in
            let x = l.ink.isNull ? center.x : center.x - (l.ink.minX + l.ink.width / 2)
            return CGPoint(x: x.rounded(), y: (baseline0 - CGFloat(i) * layout.lineHeight).rounded())
        }
    }
}
