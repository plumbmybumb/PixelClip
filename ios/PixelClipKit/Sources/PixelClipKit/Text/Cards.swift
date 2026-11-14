import CoreGraphics
import CoreText
import Foundation

/// Designed one-tap templates built on the text engine.
public struct CardSpec: Codable, Sendable, Hashable {
    public enum Template: String, Codable, CaseIterable, Sendable, Identifiable {
        case greeting, emoji, countdown, colorBlock
        public var id: String { rawValue }
    }

    public var template: Template
    /// Greeting: the line above the name. Emoji: caption. Countdown: what it counts to. Block: left word.
    public var title: String
    /// Greeting: the name. Block: right word.
    public var name: String
    public var emoji: String
    public var count: Int
    public var prefix: String
    public var colorA: RGBAColor
    public var colorB: RGBAColor

    public init(template: Template, title: String, name: String = "", emoji: String = "🎉", count: Int = 3,
                prefix: String = "J-", colorA: RGBAColor, colorB: RGBAColor) {
        self.template = template; self.title = title; self.name = name; self.emoji = emoji
        self.count = count; self.prefix = prefix; self.colorA = colorA; self.colorB = colorB
    }

    public static func preset(_ t: Template) -> CardSpec {
        switch t {
        case .greeting:
            CardSpec(template: t, title: "Joyeux anniversaire", name: "Léa", colorA: RGBAColor(hex: 0x2B0F4C), colorB: RGBAColor(hex: 0xFF8FC7))
        case .emoji:
            CardSpec(template: t, title: "", emoji: "🥰", colorA: .black, colorB: .accent)
        case .countdown:
            CardSpec(template: t, title: "avant les vacances", count: 3, colorA: .black, colorB: .accent)
        case .colorBlock:
            CardSpec(template: t, title: "LOVE", name: "YOU", colorA: RGBAColor(hex: 0xFF3B6B), colorB: RGBAColor(hex: 0x1E1B4B))
        }
    }

    /// Fonts each template is designed around (resolved by the app, falling back to SF).
    public static func preferredFonts(_ t: Template) -> (title: FontSelection, body: FontSelection) {
        switch t {
        case .greeting: (FontSelection(familyID: "snell-roundhand", weight: 0.4), FontSelection(familyID: FontCatalog.sfRounded, weight: 0.62))
        case .emoji: (FontSelection(familyID: FontCatalog.sfRounded, weight: 0.4), FontSelection(familyID: FontCatalog.sfRounded, weight: 0.4))
        case .countdown: (FontSelection(familyID: "avenir-next-condensed", weight: 0.62), FontSelection(familyID: FontCatalog.sfPro, weight: 0.23))
        case .colorBlock: (FontSelection(familyID: "futura", weight: 0.4), FontSelection(familyID: "futura", weight: 0.4))
        }
    }
}

public struct CardFonts: @unchecked Sendable {
    public var title: CTFont
    public var body: CTFont
    public init(title: CTFont, body: CTFont) { self.title = title; self.body = body }
}

public enum CardRenderer {
    @discardableResult
    public static func render(_ spec: CardSpec, fonts: CardFonts, width: Int = ClipCanvas.width, height: Int = ClipCanvas.height,
                              emit: MarqueeRenderer.Emit) throws -> MarqueeSummary {
        let W = CGFloat(width), H = CGFloat(height)
        func fit(_ text: String, _ font: CTFont, w: CGFloat, h: CGFloat, tracking: Double = 0) -> TextLayout {
            let ref = TextLayoutEngine.layout(text, font: font, size: 100, tracking: tracking)
            return TextLayoutEngine.layout(text, font: font, size: max(4, TextPainter.fitSize(ref, width: w, height: h).rounded()), tracking: tracking)
        }
        func frames(_ n: Int, ms: Int, _ draw: (Int, CGContext) -> Void) throws -> MarqueeSummary {
            for i in 0..<n {
                try Task.checkCancellation()
                try emit(i, Raster.draw(width: width, height: height, background: .black) { draw(i, $0) }, n == 1 ? 0 : ms)
            }
            return MarqueeSummary(frames: n, loopMs: n == 1 ? 0 : n * ms, fontSize: 0, capped: false)
        }

        switch spec.template {
        case .greeting:
            let title = fit(spec.title, fonts.title, w: W - 56, h: 74)
            let name = fit(spec.name.isEmpty ? " " : spec.name, fonts.body, w: W - 64, h: 104)
            let stars = sparkles(count: 18, width: W, height: H)
            let a = spec.colorA, deep = RGBAColor(a.r * 0.35, a.g * 0.35, a.b * 0.35)
            return try frames(16, ms: 90) { i, ctx in
                Raster.fillGradient(ctx, in: CGRect(x: 0, y: 0, width: W, height: H), from: a, to: deep, vertical: true)
                for s in stars {
                    let phase = Double(i) / 16 + s.phase
                    let k = 0.5 + 0.5 * sin(2 * Double.pi * phase)
                    star(ctx, at: s.p, radius: s.r * (0.55 + 0.45 * k), color: spec.colorB.withAlpha(0.25 + 0.75 * k))
                }
                TextPainter.draw(title, in: ctx, origins: TextPainter.centredOrigins(title, center: CGPoint(x: W / 2, y: H * 0.72)),
                                 style: TextStyle(fill: .solid(spec.colorB)))
                TextPainter.draw(name, in: ctx, origins: TextPainter.centredOrigins(name, center: CGPoint(x: W / 2, y: H * 0.3)),
                                 style: TextStyle(fill: .solid(.white), glowRadius: 7, glowColor: spec.colorB))
            }

        case .emoji:
            let captioned = !spec.title.trimmingCharacters(in: .whitespaces).isEmpty
            let emoji = fit(spec.emoji.isEmpty ? "🙂" : spec.emoji, fonts.body, w: captioned ? W * 0.42 : W - 40, h: H * 0.72)
            let caption = captioned ? fit(spec.title, fonts.title, w: W * 0.48, h: H * 0.5) : nil
            let cx = captioned ? W * 0.26 : W / 2
            return try frames(20, ms: 70) { i, ctx in
                ctx.setFillColor(spec.colorA.withAlpha(1).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
                let bob = (9 * sin(2 * Double.pi * Double(i) / 20)).rounded()
                TextPainter.draw(emoji, in: ctx, origins: TextPainter.centredOrigins(emoji, center: CGPoint(x: cx, y: H / 2 + bob)),
                                 style: TextStyle(fill: .solid(.white)))
                if let caption {
                    TextPainter.draw(caption, in: ctx, origins: TextPainter.centredOrigins(caption, center: CGPoint(x: W * 0.73, y: H / 2)),
                                     style: TextStyle(fill: .solid(spec.colorB)))
                }
            }

        case .countdown:
            let big = fit("\(spec.prefix)\(spec.count)", fonts.title, w: W - 60, h: H * 0.6)
            let label = fit(spec.title.isEmpty ? " " : spec.title, fonts.body, w: W - 60, h: 34)
            return try frames(10, ms: 100) { i, ctx in
                ctx.setFillColor(spec.colorA.withAlpha(1).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
                let glow = 5 + 7 * (0.5 + 0.5 * sin(2 * Double.pi * Double(i) / 10))
                TextPainter.draw(big, in: ctx, origins: TextPainter.centredOrigins(big, center: CGPoint(x: W / 2, y: H * 0.6)),
                                 style: TextStyle(fill: .solid(spec.colorB), glowRadius: glow, glowColor: spec.colorB))
                TextPainter.draw(label, in: ctx, origins: TextPainter.centredOrigins(label, center: CGPoint(x: W / 2, y: H * 0.15)),
                                 style: TextStyle(fill: .solid(RGBAColor(1, 1, 1, 0.85))))
            }

        case .colorBlock:
            let left = fit(spec.title.isEmpty ? " " : spec.title, fonts.title, w: W / 2 - 36, h: H * 0.42)
            let right = fit(spec.name.isEmpty ? " " : spec.name, fonts.body, w: W / 2 - 36, h: H * 0.42)
            return try frames(1, ms: 0) { _, ctx in
                ctx.setFillColor(spec.colorA.withAlpha(1).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: W / 2, height: H))
                ctx.setFillColor(spec.colorB.withAlpha(1).cgColor)
                ctx.fill(CGRect(x: W / 2, y: 0, width: W / 2, height: H))
                TextPainter.draw(left, in: ctx, origins: TextPainter.centredOrigins(left, center: CGPoint(x: W / 4, y: H / 2)),
                                 style: TextStyle(fill: .solid(spec.colorB)))
                TextPainter.draw(right, in: ctx, origins: TextPainter.centredOrigins(right, center: CGPoint(x: W * 0.75, y: H / 2)),
                                 style: TextStyle(fill: .solid(spec.colorA)))
            }
        }
    }

    struct Sparkle { var p: CGPoint; var r: CGFloat; var phase: Double }

    /// Deterministic sparkle field (LCG), kept clear of the centre band where the name sits.
    static func sparkles(count: Int, width: CGFloat, height: CGFloat) -> [Sparkle] {
        var seed: UInt64 = 0x5EED_CAFE
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        return (0..<count).map { _ in
            let x = CGFloat(rnd()) * width
            var y = CGFloat(rnd()) * height
            if abs(y - height * 0.32) < height * 0.2 { y = rnd() < 0.5 ? height * CGFloat(0.02 + rnd() * 0.08) : height * CGFloat(0.9 + rnd() * 0.08) }
            return Sparkle(p: CGPoint(x: x, y: y), r: CGFloat(3 + rnd() * 5), phase: rnd())
        }
    }

    static func star(_ ctx: CGContext, at p: CGPoint, radius r: CGFloat, color: RGBAColor) {
        let path = CGMutablePath()
        let inner = r * 0.28
        for k in 0..<8 {
            let a = CGFloat(k) * .pi / 4
            let rr = k % 2 == 0 ? r : inner
            let pt = CGPoint(x: p.x + rr * cos(a + .pi / 2), y: p.y + rr * sin(a + .pi / 2))
            if k == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }
}
