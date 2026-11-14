import CoreGraphics
import CoreText
import Foundation

/// Everything the marquee creator lets you choose. Saved as JSON with the library item.
public struct MarqueeSpec: Codable, Sendable, Hashable {
    public enum Motion: String, Codable, CaseIterable, Sendable {
        case scroll, typewriter, bounce, still, ticker
    }

    public var text: String
    /// Ticker headline (the top line).
    public var headline: String
    public var font: FontSelection
    /// Share of the auto-fit size, 0.3…1.
    public var sizePercent: Double
    /// Letter-spacing in ems (-0.1…0.5).
    public var tracking: Double
    public var fill: TextFill
    public var outlineWidth: Double
    public var outlineColor: RGBAColor
    public var glowRadius: Double
    public var glowColor: RGBAColor
    public var background: RGBAColor
    public var motion: Motion
    /// LED dot-matrix look (any motion).
    public var led: Bool
    public var ledPitch: Int
    /// Show unlit LEDs as dim dots (classic, but every frame becomes much bigger to store).
    public var ledUnlit: Bool
    public var leftward: Bool
    /// px/s for scrolls (also sets the typewriter's pace).
    public var speed: Double
    /// Space between repeats as a share of the screen width.
    public var spacing: Double
    public var fps: Double
    public var dither: Bool

    public init(text: String = "Bonjour ✨", headline: String = "Ce soir", font: FontSelection = .systemBold,
                sizePercent: Double = 0.75, tracking: Double = 0, fill: TextFill = .solid(.accent),
                outlineWidth: Double = 0, outlineColor: RGBAColor = .white, glowRadius: Double = 0,
                glowColor: RGBAColor = .accent, background: RGBAColor = .black, motion: Motion = .scroll,
                led: Bool = false, ledPitch: Int = 6, ledUnlit: Bool = false, leftward: Bool = true, speed: Double = 160,
                spacing: Double = 0.4, fps: Double = 20, dither: Bool = false) {
        self.text = text; self.headline = headline; self.font = font; self.sizePercent = sizePercent
        self.tracking = tracking; self.fill = fill; self.outlineWidth = outlineWidth; self.outlineColor = outlineColor
        self.glowRadius = glowRadius; self.glowColor = glowColor; self.background = background; self.motion = motion
        self.led = led; self.ledPitch = ledPitch; self.ledUnlit = ledUnlit; self.leftward = leftward; self.speed = speed; self.spacing = spacing
        self.fps = fps; self.dither = dither
    }

    public var style: TextStyle {
        TextStyle(fill: fill, outlineWidth: outlineWidth, outlineColor: outlineColor, glowRadius: glowRadius, glowColor: glowColor)
    }

    /// Off-dot colour for the LED look: the background, or a dim echo of the ink on black
    /// (nil when unlit dots are hidden).
    public var ledOffColor: RGBAColor? {
        guard ledUnlit else { return nil }
        let bg = background
        if bg.r + bg.g + bg.b > 0.02 { return bg }
        let c = fill.primary
        return RGBAColor(c.r * 0.13 + 0.02, c.g * 0.13 + 0.02, c.b * 0.13 + 0.02)
    }
}

/// What a render produced (or would produce).
public struct MarqueeSummary: Equatable, Sendable {
    public var frames: Int
    public var loopMs: Int
    public var fontSize: Double
    /// Hit the frame cap (step or reveal compressed).
    public var capped: Bool
}

/// Text → frames for every marquee style. Frames are streamed to `emit` (premultiplied RGBA,
/// opaque, 536×240) with their duration, so callers can quantise and drop them as they go.
public enum MarqueeRenderer {
    public static let maxFrames = 400

    public typealias Emit = (_ index: Int, _ frame: RGBA8Image, _ durationMs: Int) throws -> Void

    @discardableResult
    public static func render(_ spec: MarqueeSpec, font: CTFont, width: Int = ClipCanvas.width, height: Int = ClipCanvas.height,
                              maxFrames: Int = maxFrames, emit: Emit) throws -> MarqueeSummary {
        let ctx = Context(spec: spec, font: font, width: width, height: height, maxFrames: maxFrames)
        switch spec.motion {
        case .scroll: return try ctx.scroll(emit)
        case .ticker: return try ctx.ticker(emit)
        case .typewriter: return try ctx.typewriter(emit)
        case .bounce: return try ctx.bounce(emit)
        case .still: return try ctx.still(emit)
        }
    }

    /// Frame count and loop length without drawing frames (layout only).
    public static func summary(_ spec: MarqueeSpec, font: CTFont, width: Int = ClipCanvas.width, height: Int = ClipCanvas.height,
                               maxFrames: Int = maxFrames) -> MarqueeSummary {
        let ctx = Context(spec: spec, font: font, width: width, height: height, maxFrames: maxFrames)
        switch spec.motion {
        case .scroll:
            let s = ctx.scrollSetup(bandHeight: height)
            return MarqueeSummary(frames: s.plan.frames, loopMs: s.plan.loopMs, fontSize: Double(s.layout.size), capped: s.plan.capped)
        case .ticker:
            let s = ctx.scrollSetup(bandHeight: height - ctx.tickerTop)
            return MarqueeSummary(frames: s.plan.frames, loopMs: s.plan.loopMs, fontSize: Double(s.layout.size), capped: s.plan.capped)
        case .typewriter:
            let t = ctx.typewriterPlan()
            return MarqueeSummary(frames: t.durations.count, loopMs: t.durations.reduce(0, +), fontSize: Double(t.layout.size), capped: t.capped)
        case .bounce:
            let n = LoopMath.bounceFrames(fps: spec.fps)
            return MarqueeSummary(frames: n, loopMs: n * ctx.frameMs, fontSize: Double(ctx.bounceLayout().size), capped: false)
        case .still:
            return MarqueeSummary(frames: 1, loopMs: 0, fontSize: Double(ctx.fittedBlock(spec.text, width: CGFloat(width), height: CGFloat(height)).size), capped: false)
        }
    }

    // MARK: - Implementation

    struct Context {
        let spec: MarqueeSpec
        let font: CTFont
        let width: Int
        let height: Int
        let maxFrames: Int

        var W: CGFloat { CGFloat(width) }
        var H: CGFloat { CGFloat(height) }
        var frameMs: Int { Int((1000 / max(1, spec.fps)).rounded()).clampedTo(20, 200) }
        var pitch: Int { spec.led ? max(3, spec.ledPitch) : 1 }
        var margin: CGFloat { spec.led ? CGFloat(pitch) : max(10, spec.style.bleed) }
        /// Smooth frames are drawn on black when the LED look samples them.
        var drawBackground: RGBAColor { spec.led ? .black : spec.background.withAlpha(1) }
        var tickerTop: Int { Int((H * 0.56).rounded()) }

        func finish(_ img: RGBA8Image) -> RGBA8Image {
            spec.led ? DotMatrix.render(img, pitch: pitch, off: spec.ledOffColor) : img
        }

        /// Lay out at a reference size, then at the size that fits.
        func fittedBlock(_ text: String, width: CGFloat?, height: CGFloat) -> TextLayout {
            let ref = TextLayoutEngine.layout(text, font: font, size: 100, tracking: spec.tracking)
            let size = TextPainter.fitSize(ref, width: width.map { max(8, $0 - 2 * margin) }, height: max(8, height - 2 * margin))
            return TextLayoutEngine.layout(text, font: font, size: max(4, (size * spec.sizePercent).rounded()), tracking: spec.tracking)
        }

        // MARK: Scroll

        struct ScrollSetup {
            let layout: TextLayout
            let strip: RGBA8Image
            let pad: Int
            let contentWidth: Int
            let plan: ScrollPlan
        }

        func singleLine(_ s: String) -> String {
            s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        }

        func scrollSetup(bandHeight: Int, text: String? = nil, drawStrip: Bool = false) -> ScrollSetup {
            let message = singleLine(text ?? spec.text)
            let layout = fittedBlock(message, width: nil, height: CGFloat(bandHeight))
            let line = layout.lines.first
            let content = max(1, Int((line?.width ?? 0).rounded(.up)))
            let pad = Int(spec.style.bleed.rounded(.up)) + 2
            let gap = Int((spec.spacing * W).rounded())
            let plan = LoopMath.scrollPlan(contentWidth: content, gap: gap, speed: spec.speed, fps: spec.fps,
                                           pitch: pitch, maxFrames: maxFrames)
            var strip = RGBA8Image(width: 1, height: 1, bytes: [0, 0, 0, 0])
            if drawStrip {
                let sw = content + 2 * pad
                let origin = TextPainter.centredOrigins(layout, center: CGPoint(x: 0, y: CGFloat(bandHeight) / 2)).first ?? .zero
                strip = Raster.draw(width: sw, height: bandHeight) { ctx in
                    TextPainter.draw(layout, in: ctx, origins: [CGPoint(x: CGFloat(pad), y: origin.y)], style: spec.style)
                }
            }
            return ScrollSetup(layout: layout, strip: strip, pad: pad, contentWidth: content, plan: plan)
        }

        /// The whole loop as one wide image: frame i is the canvas-wide window at `windowStart(i)`.
        /// Scrolling only ever translates by whole steps (whole LED cells), so cropping this is
        /// identical to drawing every frame, and much cheaper.
        func scrollStrip(_ s: ScrollSetup, height bandHeight: Int, background: RGBAColor, ledOriginY: Int?) -> RGBA8Image {
            let p = s.plan
            let bw = p.period + width
            var big = Raster.filled(width: bw, height: bandHeight, color: background)
            let first = spec.leftward ? width - s.pad : p.period - s.contentWidth - s.pad
            var x = first - ((first + s.strip.width) / p.period + 1) * p.period
            while x < bw {
                if x + s.strip.width > 0 { Raster.blend(s.strip, into: &big, x: x, y: 0) }
                x += p.period
            }
            guard spec.led else { return big }
            let g = DotMatrix.grid(width: width, height: height, pitch: pitch)
            return DotMatrix.render(big, pitch: pitch, off: spec.ledOffColor, originX: g.originX, originY: ledOriginY ?? g.originY)
        }

        func windowStart(_ i: Int, _ plan: ScrollPlan) -> Int {
            spec.leftward ? (i * plan.step) % plan.period : plan.period - (i * plan.step) % plan.period
        }

        /// Black LED margins at the canvas edges (the strip has dots there; the canvas grid doesn't).
        func ledMargins(_ img: inout RGBA8Image) {
            guard spec.led else { return }
            let g = DotMatrix.grid(width: width, height: height, pitch: pitch)
            Raster.blackOutside(&img, x0: g.originX, x1: g.originX + g.cols * g.pitch, y0: g.originY, y1: g.originY + g.rows * g.pitch)
        }

        func scroll(_ emit: Emit) throws -> MarqueeSummary {
            let s = scrollSetup(bandHeight: height, drawStrip: true)
            let big = scrollStrip(s, height: height, background: drawBackground, ledOriginY: nil)
            for i in 0..<s.plan.frames {
                try Task.checkCancellation()
                var frame = Raster.crop(big, x: windowStart(i, s.plan), y: 0, width: width, height: height)
                ledMargins(&frame)
                try emit(i, frame, s.plan.frameMs)
            }
            return MarqueeSummary(frames: s.plan.frames, loopMs: s.plan.loopMs, fontSize: Double(s.layout.size), capped: s.plan.capped)
        }

        // MARK: Ticker

        func ticker(_ emit: Emit) throws -> MarqueeSummary {
            let top = tickerTop
            let band = height - top
            let s = scrollSetup(bandHeight: band, drawStrip: true)
            let headline = fittedBlock(singleLine(spec.headline), width: W, height: CGFloat(top))
            let accent = spec.fill.primary
            let base = Raster.draw(width: width, height: height, background: drawBackground) { ctx in
                // y-up: the band is the bottom `band` rows.
                ctx.setFillColor(accent.withAlpha(spec.led ? 0.0 : 0.16).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: W, height: CGFloat(band)))
                ctx.setFillColor(accent.cgColor)
                ctx.fill(CGRect(x: 0, y: CGFloat(band), width: W, height: max(2, CGFloat(pitch))))
                let origins = TextPainter.centredOrigins(headline, center: CGPoint(x: W / 2, y: CGFloat(band) + CGFloat(top) / 2))
                TextPainter.draw(headline, in: ctx, origins: origins, style: spec.style)
            }
            if spec.led {
                // The band's dots must sit on the full-screen grid, so LED tickers sample each frame.
                for i in 0..<s.plan.frames {
                    try Task.checkCancellation()
                    var frame = base
                    for x in LoopMath.copies(frame: i, plan: s.plan, canvasWidth: width, contentWidth: s.contentWidth,
                                             stripWidth: s.strip.width, pad: s.pad, leftward: spec.leftward) {
                        Raster.blend(s.strip, into: &frame, x: x, y: top)
                    }
                    try emit(i, finish(frame), s.plan.frameMs)
                }
            } else {
                let bandBG = Raster.crop(base, x: 0, y: top, width: width, height: band)
                let big = tickerStrip(s, bandBG: bandBG)
                for i in 0..<s.plan.frames {
                    try Task.checkCancellation()
                    var frame = base
                    Raster.copyRows(Raster.crop(big, x: windowStart(i, s.plan), y: 0, width: width, height: band), into: &frame, y: top)
                    try emit(i, frame, s.plan.frameMs)
                }
            }
            return MarqueeSummary(frames: s.plan.frames, loopMs: s.plan.loopMs, fontSize: Double(s.layout.size), capped: s.plan.capped)
        }

        /// Ticker band as one wide image over the band's own (tinted) background.
        func tickerStrip(_ s: ScrollSetup, bandBG: RGBA8Image) -> RGBA8Image {
            let p = s.plan
            let bw = p.period + width
            // Tile the band background (it's uniform per row) across the wide strip.
            var big = Raster.filled(width: bw, height: bandBG.height, color: .black)
            for x in stride(from: 0, to: bw, by: width) {
                Raster.blend(bandBG, into: &big, x: x, y: 0)
            }
            let first = spec.leftward ? width - s.pad : p.period - s.contentWidth - s.pad
            var x = first - ((first + s.strip.width) / p.period + 1) * p.period
            while x < bw {
                if x + s.strip.width > 0 { Raster.blend(s.strip, into: &big, x: x, y: 0) }
                x += p.period
            }
            return big
        }

        // MARK: Typewriter

        struct TypewriterPlan {
            let layout: TextLayout
            /// UTF-16 end offset revealed at each typing step.
            let reveals: [Int]
            let durations: [Int]
            let typingFrames: Int
            let capped: Bool
        }

        func typewriterPlan() -> TypewriterPlan {
            let layout = fittedBlock(spec.text, width: W, height: H)
            var ends: [Int] = []
            var offset = 0
            for ch in spec.text {
                offset += ch.utf16.count
                if ch.isNewline { continue }
                ends.append(offset)
            }
            let charMs = LoopMath.typewriterCharMs(speed: spec.speed)
            let tail = 8   // start blank + 6 blink frames + end blank
            var capped = false
            if ends.count + tail > maxFrames {
                capped = true
                let keep = max(1, maxFrames - tail)
                ends = Array(ends.prefix(keep - 1)) + [ends.last!]
            }
            var durations = [300]
            durations += Array(repeating: charMs, count: ends.count)
            durations += [500, 400, 500, 400, 500, 400, 350]
            return TypewriterPlan(layout: layout, reveals: ends, durations: durations, typingFrames: ends.count, capped: capped)
        }

        func typewriter(_ emit: Emit) throws -> MarqueeSummary {
            let t = typewriterPlan()
            let origins = TextPainter.centredOrigins(t.layout, center: CGPoint(x: W / 2, y: H / 2))
            let full = spec.text.utf16.count
            let caretW = max(2, (t.layout.size * 0.07).rounded())
            func frame(revealed: Int, cursor: Bool) -> RGBA8Image {
                Raster.draw(width: width, height: height, background: drawBackground) { ctx in
                    TextPainter.draw(t.layout, in: ctx, origins: origins, style: spec.style,
                                     include: { _, g in g.stringIndex < revealed })
                    guard cursor, !t.layout.lines.isEmpty else { return }
                    // Caret after the last revealed character, on its line.
                    var li = 0
                    for (i, l) in t.layout.lines.enumerated() where revealed >= l.range.lowerBound { li = i }
                    let line = t.layout.lines[li]
                    let x = origins[li].x + line.caretX(min(revealed, line.range.upperBound))
                    let y = origins[li].y - line.descent * 0.15
                    ctx.setFillColor(spec.fill.primary.cgColor)
                    ctx.fill(CGRect(x: x + caretW * 0.6, y: y, width: caretW, height: line.ascent * 0.95))
                }
            }
            var index = 0
            try emit(index, finish(frame(revealed: 0, cursor: true)), t.durations[0]); index += 1
            for (k, end) in t.reveals.enumerated() {
                try Task.checkCancellation()
                let revealed = k == t.reveals.count - 1 ? full : end
                try emit(index, finish(frame(revealed: revealed, cursor: true)), t.durations[index]); index += 1
            }
            let on = finish(frame(revealed: full, cursor: true)), off = finish(frame(revealed: full, cursor: false))
            for b in 0..<6 {
                try emit(index, b % 2 == 0 ? off : on, t.durations[index]); index += 1
            }
            try emit(index, finish(Raster.filled(width: width, height: height, color: drawBackground)), t.durations[index])
            return MarqueeSummary(frames: t.durations.count, loopMs: t.durations.reduce(0, +), fontSize: Double(t.layout.size), capped: t.capped)
        }

        // MARK: Bounce

        var bounceAmplitude: CGFloat { (H * 0.14).rounded() }

        func bounceLayout() -> TextLayout { fittedBlock(spec.text, width: W, height: H - bounceAmplitude) }

        func bounce(_ emit: Emit) throws -> MarqueeSummary {
            let layout = bounceLayout()
            let amp = bounceAmplitude
            let origins = TextPainter.centredOrigins(layout, center: CGPoint(x: W / 2, y: H / 2 - amp / 2))
            let n = LoopMath.bounceFrames(fps: spec.fps)
            // Index only glyphs with ink so spaces don't eat a beat of the wave.
            var inked: [Int: Int] = [:]
            var running = 0, visible = 0
            for l in layout.lines {
                for g in l.glyphs {
                    if g.bounds.width > 0.01 { inked[running] = visible; visible += 1 }
                    running += 1
                }
            }
            for i in 0..<n {
                try Task.checkCancellation()
                let img = Raster.draw(width: width, height: height, background: drawBackground) { ctx in
                    TextPainter.draw(layout, in: ctx, origins: origins, style: spec.style, offset: { idx, _ in
                        let h = LoopMath.hop(frame: i, period: n, index: inked[idx] ?? 0)
                        return CGPoint(x: 0, y: (amp * CGFloat(h)).rounded())
                    })
                }
                try emit(i, finish(img), frameMs)
            }
            return MarqueeSummary(frames: n, loopMs: n * frameMs, fontSize: Double(layout.size), capped: false)
        }

        // MARK: Still

        func still(_ emit: Emit) throws -> MarqueeSummary {
            let layout = fittedBlock(spec.text, width: W, height: H)
            let img = Raster.draw(width: width, height: height, background: drawBackground) { ctx in
                TextPainter.draw(layout, in: ctx, origins: TextPainter.centredOrigins(layout, center: CGPoint(x: W / 2, y: H / 2)),
                                 style: spec.style)
            }
            try emit(0, finish(img), 0)
            return MarqueeSummary(frames: 1, loopMs: 0, fontSize: Double(layout.size), capped: false)
        }
    }
}

// MARK: - Scrolling strips

/// A marquee exported as one wide frame the clip scrolls itself (PROTOCOL §2 `is_strip`, §4 `scroll`):
/// tens of KB instead of hundreds of frames.
public struct MarqueeStrip: Sendable {
    /// Opaque RGBA, 240 px tall, ≤ 8192 px wide: the message once, with its padding.
    public var image: RGBA8Image
    /// Speed, direction and gap (loops are chosen by the playlist entry).
    public var scroll: PlaylistItem.Scroll
    public var fontSize: Double
    public var width: Int { image.width }
    /// One pass (the strip enters, crosses and leaves), in ms.
    public var passMs: Int { StripScroller.durationMs(stripWidth: width, scroll: scroll) }
}

extension MarqueeRenderer {
    /// Smooth scroll and LED sign export a strip; typewriter, bounce, ticker and still stay frame
    /// based. The gaps between repeats are black on the clip, so a coloured background keeps frames.
    public static func usesStrip(_ spec: MarqueeSpec) -> Bool {
        guard spec.motion == .scroll else { return false }
        if spec.led { return true }
        let bg = spec.background
        return bg.r + bg.g + bg.b < 0.02
    }

    /// The scroll block for a spec: its speed (10–400 px/s), direction and the gap between repeats.
    public static func scrollBlock(_ spec: MarqueeSpec) -> PlaylistItem.Scroll {
        let r = PlaylistItem.Scroll.speedRange
        return PlaylistItem.Scroll(pxPerS: min(max(Int(spec.speed.rounded()), r.lowerBound), r.upperBound),
                                   direction: spec.leftward ? .left : .right,
                                   gapPx: max(0, Int((spec.spacing * Double(ClipCanvas.width)).rounded())))
    }

    /// Width the strip would have (layout only), or nil when the message is too long for one strip.
    public static func stripWidth(_ spec: MarqueeSpec, font: CTFont, height: Int = ClipCanvas.height) -> (width: Int, fontSize: Double)? {
        let ctx = Context(spec: spec, font: font, width: ClipCanvas.width, height: height, maxFrames: maxFrames)
        let s = ctx.scrollSetup(bandHeight: height)
        let w = stripWidth(content: s.contentWidth, pad: s.pad, pitch: ctx.pitch)
        return w <= PlaylistItem.Scroll.maxStripWidth ? (w, Double(s.layout.size)) : nil
    }

    /// Content plus padding, in whole LED cells, and at least 537 px (a strip must be wider than the
    /// screen; a short message gets black on its right, i.e. a longer gap).
    static func stripWidth(content: Int, pad: Int, pitch: Int) -> Int {
        let w = content + 2 * pad
        let cells = pitch > 1 ? (w + pitch - 1) / pitch * pitch : w
        return max(cells, PlaylistItem.Scroll.minStripWidth)
    }

    /// Render the message once as a strip. nil when it isn't a strip style or is wider than 8192 px.
    public static func renderStrip(_ spec: MarqueeSpec, font: CTFont, height: Int = ClipCanvas.height) -> MarqueeStrip? {
        guard usesStrip(spec) else { return nil }
        let ctx = Context(spec: spec, font: font, width: ClipCanvas.width, height: height, maxFrames: maxFrames)
        let s = ctx.scrollSetup(bandHeight: height, drawStrip: true)
        let w = stripWidth(content: s.contentWidth, pad: s.pad, pitch: ctx.pitch)
        guard w <= PlaylistItem.Scroll.maxStripWidth else { return nil }
        var img = Raster.filled(width: w, height: height, color: ctx.drawBackground)
        let used = min(w, (s.contentWidth + 2 * s.pad + ctx.pitch - 1) / max(1, ctx.pitch) * max(1, ctx.pitch))
        // The black padding of a short message trails the text (on the right when it moves left).
        let lead = spec.leftward ? 0 : w - used
        Raster.blend(s.strip, into: &img, x: lead + (used - s.strip.width) / 2, y: 0)
        if spec.led {
            let g = DotMatrix.grid(width: ClipCanvas.width, height: height, pitch: ctx.pitch)
            img = DotMatrix.render(img, pitch: ctx.pitch, off: spec.ledOffColor, originX: 0, originY: g.originY)
        }
        return MarqueeStrip(image: img, scroll: scrollBlock(spec), fontSize: Double(s.layout.size))
    }
}
