import CoreGraphics
import CoreText
import Foundation

/// Procedurally drawn content: the idle screen, demo media and the
/// marquee used by the Create shell. Everything is drawn at 536×240 and quantised through the
/// real pipeline so it looks exactly like it would on the clip.
public enum PlaceholderArt {

    /// A y-down drawing context of the clip's size.
    static func draw(width: Int = ClipCanvas.width, height: Int = ClipCanvas.height,
                     _ body: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: ClipRenderer.srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray(0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        body(ctx)
        return ctx.makeImage()!
    }

    static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
    static func hex(_ v: UInt32, _ a: Double = 1) -> CGColor {
        rgb(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255, a)
    }
    static func gray(_ w: Double) -> CGColor { rgb(w, w, w) }

    /// Draw a single line of text with its baseline at `y` (y-down canvas).
    @discardableResult
    static func text(_ ctx: CGContext, _ s: String, x: CGFloat, y: CGFloat, size: CGFloat,
                     weight: CGFloat = 0.4, color: CGColor, align: CGFloat = 0, tracking: CGFloat = 0) -> CGFloat {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)!
        let traits: [CFString: Any] = [kCTFontWeightTrait: weight]
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: traits] as CFDictionary)
        let font = CTFontCreateCopyWithAttributes(base, size, nil, desc)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color,
                                      kCTKernAttributeName: tracking]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, s as CFString, attrs as CFDictionary))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: x - CGFloat(width) * align, y: y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        return CGFloat(width)
    }

    // MARK: Screens

    /// Shown by the virtual clip when the playlist is empty.
    public static func idleScreen(name: String = "PixelClip") -> CGImage {
        draw { ctx in
            ctx.setFillColor(hex(BrandPalette.dim))
            for i in 0..<3 {
                ctx.fillEllipse(in: CGRect(x: 244 + i * 18, y: 150, width: 8, height: 8))
            }
            text(ctx, name, x: 268, y: 128, size: 44, weight: 0.3, color: gray(0.92), align: 0.5, tracking: -0.8)
        }
    }

    /// A clock face for `clock` playlist items.
    public static func clockScreen(_ time: String) -> CGImage {
        draw { ctx in
            text(ctx, time, x: 268, y: 160, size: 120, weight: 0.25, color: gray(0.95), align: 0.5, tracking: -4)
        }
    }

    /// A still stand-in for a live scene (the device simulates it; the virtual clip doesn't).
    public static func scenePlaceholder(_ name: String) -> CGImage {
        let palettes: [String: [UInt32]] = [
            "sand": [0xE8B04A, 0xC98A2E, 0xF4D27A], "water": [0x2E7BD6, 0x5AA8F0, 0x1B4F99],
            "fire": [0xFF5A1F, 0xFFB01F, 0xD42A0A], "balls": [0xFF5E8A, 0x7CE0C3, 0x7AA8FF, 0xFFB86B],
            "snow": [0xFFFFFF, 0xCFE3FF, 0xA9C8F0], "lava": [0xFF3B1F, 0xB81E0F, 0xFF8A1F],
        ]
        let colors = palettes[name] ?? palettes["sand"]!
        let rising = name == "fire" || name == "lava"
        return draw { ctx in
            var seed: UInt64 = name.utf8.reduce(0x9E3779B97F4A7C15) { ($0 ^ UInt64($1)) &* 0x100000001B3 }
            func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
            if name == "balls" {
                for i in 0..<9 {
                    let r = 10 + rnd() * 18
                    ctx.setFillColor(hex(colors[i % colors.count]))
                    ctx.fillEllipse(in: CGRect(x: 20 + rnd() * 480, y: 20 + rnd() * 190, width: 2 * r, height: 2 * r))
                }
                return
            }
            // A heap of 4×4 grains, denser towards the "floor".
            for x in stride(from: 0, to: 536, by: 4) {
                let height = 40 + 50 * sin(Double(x) / 536 * .pi) + rnd() * 16
                var y = 0.0
                while y < height {
                    if rnd() < 0.85 - y / height * 0.5 {
                        ctx.setFillColor(hex(colors[Int(rnd() * Double(colors.count)) % colors.count]))
                        let py = rising ? y : 236 - y
                        ctx.fill(CGRect(x: Double(x), y: py, width: 4, height: 4))
                    }
                    y += 4
                }
            }
        }
    }

    // MARK: Demo media

    /// A sunset "photo", larger than the canvas so it can be cropped.
    public static func sunsetPhoto(width: Int = 1600, height: Int = 1066) -> CGImage {
        draw(width: width, height: height) { ctx in
            let w = CGFloat(width), h = CGFloat(height)
            let sky = CGGradient(colorsSpace: ClipRenderer.srgb,
                                 colors: [hex(0x120A2E), hex(0x5B1F5E), hex(0xD9534F), hex(0xF6A04D), hex(0xFFD27A)] as CFArray,
                                 locations: [0, 0.35, 0.62, 0.8, 1])!
            ctx.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: h * 0.72), options: [.drawsAfterEndLocation])
            let sun = CGPoint(x: w * 0.58, y: h * 0.62)
            let glow = CGGradient(colorsSpace: ClipRenderer.srgb,
                                  colors: [hex(0xFFF3C4), hex(0xFFD27A, 0.6), hex(0xF6A04D, 0)] as CFArray,
                                  locations: [0, 0.25, 1])!
            ctx.drawRadialGradient(glow, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: w * 0.3, options: [])
            ctx.setFillColor(hex(0xFFF6D8))
            ctx.fillEllipse(in: CGRect(x: sun.x - 70, y: sun.y - 70, width: 140, height: 140))
            // Hills
            func hill(_ color: CGColor, _ base: CGFloat, _ amp: CGFloat, _ freq: CGFloat, _ phase: CGFloat) {
                let p = CGMutablePath()
                p.move(to: CGPoint(x: 0, y: h))
                var x: CGFloat = 0
                while x <= w {
                    p.addLine(to: CGPoint(x: x, y: base + sin(x / w * .pi * freq + phase) * amp))
                    x += 8
                }
                p.addLine(to: CGPoint(x: w, y: h)); p.closeSubpath()
                ctx.setFillColor(color); ctx.addPath(p); ctx.fillPath()
            }
            hill(hex(0x3A1740), h * 0.70, 40, 3, 0.4)
            hill(hex(0x1C0B24), h * 0.78, 34, 5, 1.7)
            hill(hex(0x050208), h * 0.86, 22, 7, 2.9)
        }
    }

    /// Frames of an orbiting-dots animation (24 frames, 60 ms).
    public static func orbitFrames(count: Int = 24) -> [CGImage] {
        (0..<count).map { f in
            draw { ctx in
                let t = Double(f) / Double(count) * 2 * .pi
                let colors: [UInt32] = [0xFF5E8A, 0xFFB86B, 0x7CE0C3, 0x7AA8FF, 0xC48BFF]
                for (i, c) in colors.enumerated() {
                    let a = t + Double(i) * 2 * .pi / Double(colors.count)
                    let x = 268 + cos(a) * 150, y = 120 + sin(a) * 58
                    let r = 16 + sin(a) * 6
                    let glow = CGGradient(colorsSpace: ClipRenderer.srgb,
                                          colors: [hex(c, 0.55), hex(c, 0)] as CFArray, locations: [0, 1])!
                    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                                           endCenter: CGPoint(x: x, y: y), endRadius: r * 2.6, options: [])
                    ctx.setFillColor(hex(c))
                    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                }
            }
        }
    }

    /// A scrolling text marquee (used by the Create shell).
    public static func marqueeFrames(_ message: String = "hello ✦ bonjour ✦", count: Int = 48) -> [CGImage] {
        let size: CGFloat = 96
        var width: CGFloat = 0
        _ = draw(width: 4, height: 4) { ctx in
            width = text(ctx, message, x: 0, y: 0, size: size, weight: 0.45, color: gray(1), tracking: -2)
        }
        let span = width + 60
        return (0..<count).map { f in
            draw { ctx in
                let shift = CGFloat(f) / CGFloat(count) * span
                let grad = [0xFF5E8A, BrandPalette.primary] as [UInt32]   // pink, brand violet (the centred copy)
                for k in 0..<3 {
                    let x = 536 - shift + CGFloat(k - 1) * span
                    text(ctx, message, x: x, y: 154, size: size, weight: 0.45,
                         color: hex(grad[k % 2]), tracking: -2)
                }
            }
        }
    }
}
