import Accelerate
import CoreGraphics
import CoreText
import Foundation

/// An sRGB colour that survives JSON (drafts, specs) and converts to CoreGraphics.
public struct RGBAColor: Codable, Sendable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }

    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    public func withAlpha(_ alpha: Double) -> RGBAColor { RGBAColor(r, g, b, alpha) }

    /// Premultiplied 8-bit RGBA (the layout of every `RGBA8Image` we draw).
    public var premultipliedBytes: (UInt8, UInt8, UInt8, UInt8) {
        func q(_ v: Double) -> UInt8 { UInt8(min(max((v * 255).rounded(), 0), 255)) }
        let al = min(max(a, 0), 1)
        return (q(r * al), q(g * al), q(b * al), q(al))
    }

    public static let black = RGBAColor(0, 0, 0)
    public static let white = RGBAColor(1, 1, 1)
    /// The brand accent on the clip: soft violet (`BrandPalette.primary`). The default ink of
    /// everything Create makes (marquee fill and glow, LED pen, card colour).
    public static let accent = RGBAColor(hex: BrandPalette.primary)
}

/// The brand palette: soft violet and its derived siblings. Every value is RGB565-exact and shares
/// one OKLCH hue (301° ± 1°). The app's `AccentColor` asset is `lightMode` / `primary`; the
/// firmware's `UI_ACCENT` is `primary`.
public enum BrandPalette {
    /// #C6A2FF, RGB565 C51F: lit on black, dark-mode accent (10.0:1 on black).
    public static let primary: UInt32 = 0xC6A2FF
    /// #52416B, RGB565 520D: ~40 %, the unlit-but-present n, secondary marks.
    public static let dim: UInt32 = 0x52416B
    /// #DECBFF, RGB565 DE5F: pale highlight (flashes, glows).
    public static let glow: UInt32 = 0xDECBFF
    /// #9C82C6, RGB565 9C18: pressed state on dark surfaces.
    public static let pressed: UInt32 = 0x9C82C6
    /// #8445CE, RGB565 8239: light-mode accent, 5.64:1 on white (5.05:1 on #F2F2F7).
    public static let lightMode: UInt32 = 0x8445CE
    /// #6B38A5, RGB565 69D4: pressed state of the light-mode accent (7.68:1 on white).
    public static let lightModePressed: UInt32 = 0x6B38A5

    /// `primary` as an RGB565 pixel (`C51F`, exact): the clip's accent (cursor, page dots, the hint).
    public static let accentPixel: UInt16 = 0xC51F
    /// `dim` as an RGB565 pixel (`520D`): the dots of the pages not on screen.
    public static let dimPixel: UInt16 = 0x520D
}

/// How glyphs are painted.
public enum TextFill: Codable, Sendable, Hashable {
    case solid(RGBAColor)
    /// Two-colour linear gradient across the text's ink bounds.
    case gradient(RGBAColor, RGBAColor, vertical: Bool)

    public var primary: RGBAColor {
        switch self {
        case .solid(let c): c
        case .gradient(let a, _, _): a
        }
    }
}

/// Which font to use, independent of how the platform resolves it (the app maps `familyID`
/// to a `UIFont`/`CTFont` through `FontCatalog`).
public struct FontSelection: Codable, Sendable, Hashable {
    /// A `FontChoice.id` from `FontCatalog`.
    public var familyID: String
    /// CoreText weight trait, -1 (thinnest) … 1 (heaviest); 0 regular, 0.4 bold.
    public var weight: Double
    public var italic: Bool

    public init(familyID: String, weight: Double = 0, italic: Bool = false) {
        self.familyID = familyID; self.weight = weight; self.italic = italic
    }

    public static let systemBold = FontSelection(familyID: FontCatalog.sfPro, weight: 0.4)
}

/// Raster helpers shared by the text and drawing engines. Images are premultiplied RGBA8, sRGB,
/// row 0 at the top (CGBitmapContext memory order).
public enum Raster {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Draw into a fresh width×height buffer. The context is y-up (CoreGraphics native): user-space
    /// y = height is the top row. Font smoothing is off so output doesn't depend on the device.
    public static func draw(width: Int, height: Int, background: RGBAColor? = nil,
                            _ body: (CGContext) -> Void) -> RGBA8Image {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setShouldSmoothFonts(false)
            ctx.setAllowsFontSmoothing(false)
            ctx.setShouldAntialias(true)
            ctx.interpolationQuality = .high
            if let background {
                ctx.setFillColor(background.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            body(ctx)
        }
        return RGBA8Image(width: width, height: height, bytes: bytes)
    }

    /// Solid width×height image.
    public static func filled(width: Int, height: Int, color: RGBAColor) -> RGBA8Image {
        let (r, g, b, a) = color.premultipliedBytes
        let word = UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | UInt32(a) << 24   // little-endian memory order R,G,B,A
        let words = [UInt32](repeating: word, count: width * height)
        return RGBA8Image(width: width, height: height, bytes: words.withUnsafeBytes { [UInt8]($0) })
    }

    /// A `width`×`height` window of `src` starting at (x, y). The window must lie inside `src`.
    public static func crop(_ src: RGBA8Image, x: Int, y: Int, width: Int, height: Int) -> RGBA8Image {
        precondition(x >= 0 && y >= 0 && x + width <= src.width && y + height <= src.height)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        src.bytes.withUnsafeBytes { s in
            out.withUnsafeMutableBytes { d in
                for row in 0..<height {
                    (d.baseAddress! + row * width * 4)
                        .copyMemory(from: s.baseAddress! + ((y + row) * src.width + x) * 4, byteCount: width * 4)
                }
            }
        }
        return RGBA8Image(width: width, height: height, bytes: out)
    }

    /// Overwrite rows of `dst` starting at `y` with `src` (same width).
    public static func copyRows(_ src: RGBA8Image, into dst: inout RGBA8Image, y: Int) {
        precondition(src.width == dst.width && y >= 0 && y + src.height <= dst.height)
        let n = src.bytes.count
        src.bytes.withUnsafeBytes { s in
            dst.bytes.withUnsafeMutableBytes { d in
                (d.baseAddress! + y * dst.width * 4).copyMemory(from: s.baseAddress!, byteCount: n)
            }
        }
    }

    /// Paint columns outside [x0, x1) and rows outside [y0, y1) opaque black (LED margins).
    public static func blackOutside(_ img: inout RGBA8Image, x0: Int, x1: Int, y0: Int, y1: Int) {
        let w = img.width, h = img.height
        let black = [UInt32](repeating: 0xFF00_0000, count: w)
        img.bytes.withUnsafeMutableBytes { d in
            black.withUnsafeBytes { b in
                for y in 0..<h {
                    let row = d.baseAddress! + y * w * 4
                    if y < y0 || y >= y1 {
                        row.copyMemory(from: b.baseAddress!, byteCount: w * 4)
                    } else {
                        if x0 > 0 { row.copyMemory(from: b.baseAddress!, byteCount: x0 * 4) }
                        if x1 < w { (row + x1 * 4).copyMemory(from: b.baseAddress!, byteCount: (w - x1) * 4) }
                    }
                }
            }
        }
    }

    /// Source-over blend of premultiplied `src` onto `dst` with src's top-left at (x, y) (row 0 =
    /// top), clipped to `dst`. Uses vImage (fast even in unoptimised builds, deterministic).
    public static func blend(_ src: RGBA8Image, into dst: inout RGBA8Image, x: Int, y: Int) {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(dst.width, x + src.width), y1 = min(dst.height, y + src.height)
        guard x0 < x1, y0 < y1 else { return }
        let sw = src.width, dw = dst.width
        src.bytes.withUnsafeBytes { sp in
            dst.bytes.withUnsafeMutableBytes { dp in
                // vImage only reads `top`.
                var top = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: sp.baseAddress!) + ((y0 - y) * sw + (x0 - x)) * 4, height: vImagePixelCount(y1 - y0),
                                        width: vImagePixelCount(x1 - x0), rowBytes: sw * 4)
                var bottom = vImage_Buffer(data: dp.baseAddress! + (y0 * dw + x0) * 4, height: vImagePixelCount(y1 - y0),
                                           width: vImagePixelCount(x1 - x0), rowBytes: dw * 4)
                _ = vImagePremultipliedAlphaBlend_BGRA8888(&top, &bottom, &bottom, vImage_Flags(kvImageNoFlags))
            }
        }
    }

    /// Linear gradient as flat 1 px bands (rows when `vertical`, top colour `a` first in y-down
    /// terms; columns otherwise). CoreGraphics dithers its own gradients, which is noise to RLE16;
    /// flat bands keep every row (or column) a single run. The context is y-up.
    public static func fillGradient(_ ctx: CGContext, in rect: CGRect, from a: RGBAColor, to b: RGBAColor, vertical: Bool) {
        let r = rect.integral
        let n = Int(vertical ? r.height : r.width)
        guard n > 0 else { return }
        for i in 0..<n {
            let t = n == 1 ? 0 : Double(i) / Double(n - 1)
            let c = RGBAColor(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
            ctx.setFillColor(c.cgColor)
            if vertical {
                ctx.fill(CGRect(x: r.minX, y: r.maxY - CGFloat(i + 1), width: r.width, height: 1))
            } else {
                ctx.fill(CGRect(x: r.minX + CGFloat(i), y: r.minY, width: 1, height: r.height))
            }
        }
    }

    /// RGBA8 → CGImage (premultiplied, for drawing an engine layer into a context).
    public static func cgImage(_ img: RGBA8Image) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(img.bytes) as CFData) else { return nil }
        return CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: img.width * 4, space: srgb,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Copy of `img` with every pixel over `background` (alpha becomes 255).
    public static func flattened(_ img: RGBA8Image, on background: RGBAColor) -> RGBA8Image {
        var out = filled(width: img.width, height: img.height, color: RGBAColor(background.r, background.g, background.b, 1))
        blend(img, into: &out, x: 0, y: 0)
        return out
    }
}
