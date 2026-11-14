import CoreGraphics
import Foundation

/// The clip's canvas.
public enum ClipCanvas {
    public static let width = 536
    public static let height = 240
    public static let aspect = Double(width) / Double(height)
    public static var size: CGSize { CGSize(width: width, height: height) }
}

/// How a source image sits inside the 536×240 canvas.
/// All values are in output pixels: the source's centre is placed at the canvas centre plus `offset`,
/// scaled by `scale` (output px per source px) and rotated by `rotation` radians, clockwise-positive
/// in screen space (the same convention as SwiftUI's `rotationEffect`).
public struct CropTransform: Codable, Sendable, Equatable, Hashable {
    public var scale: Double
    public var offsetX: Double
    public var offsetY: Double
    public var rotation: Double

    public init(scale: Double, offsetX: Double = 0, offsetY: Double = 0, rotation: Double = 0) {
        self.scale = scale; self.offsetX = offsetX; self.offsetY = offsetY; self.rotation = rotation
    }

    public static func fitScale(for source: CGSize, canvas: CGSize = ClipCanvas.size) -> Double {
        guard source.width > 0, source.height > 0 else { return 1 }
        return min(canvas.width / source.width, canvas.height / source.height)
    }

    public static func fillScale(for source: CGSize, canvas: CGSize = ClipCanvas.size) -> Double {
        guard source.width > 0, source.height > 0 else { return 1 }
        return max(canvas.width / source.width, canvas.height / source.height)
    }

    public static func fill(_ source: CGSize) -> CropTransform { CropTransform(scale: fillScale(for: source)) }
    public static func fit(_ source: CGSize) -> CropTransform { CropTransform(scale: fitScale(for: source)) }
}

/// User adjustments applied before quantisation. Neutral values leave pixels untouched.
public struct ImageAdjustments: Codable, Sendable, Equatable, Hashable {
    /// -1…1, additive in sRGB-encoded space (±0.35 of full scale at the extremes).
    public var brightness: Double
    /// 0…2, scales around mid-grey in sRGB-encoded space. 1 = neutral.
    public var contrast: Double
    /// 0…2, mixes with Rec. 709 luminance in linear light. 1 = neutral, 0 = greyscale.
    public var saturation: Double
    /// Crush near-black to true black (pixels off = battery saved), keep highlights.
    public var amoledDark: Bool
    /// Ordered 4×4 Bayer dither when reducing to RGB565 (flat areas are left undithered).
    public var dither: Bool

    public init(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1,
                amoledDark: Bool = true, dither: Bool = true) {
        self.brightness = brightness; self.contrast = contrast; self.saturation = saturation
        self.amoledDark = amoledDark; self.dither = dither
    }

    public static let neutral = ImageAdjustments(amoledDark: false, dither: false)
    public static let `default` = ImageAdjustments()

    var touchesToneCurve: Bool { brightness != 0 || contrast != 1 }
}

/// An 8-bit RGBA buffer (non-premultiplied after compositing on black, alpha ignored).
public struct RGBA8Image: Sendable {
    public let width: Int
    public let height: Int
    public var bytes: [UInt8]

    public init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4)
        self.width = width; self.height = height; self.bytes = bytes
    }
}

/// CGImage → RGBA8 (536×240) → adjustments → optional AMOLED curve → Bayer dither → RGB565.
/// Everything after the CoreGraphics draw is integer/LUT based and deterministic.
public enum ClipRenderer {

    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Full pipeline for one image.
    public static func render(_ image: CGImage, transform: CropTransform,
                              adjustments: ImageAdjustments,
                              width: Int = ClipCanvas.width, height: Int = ClipCanvas.height) -> RGB565Frame {
        var rgba = rasterize(image, transform: transform, width: width, height: height)
        apply(adjustments, to: &rgba)
        return quantize(rgba, dither: adjustments.dither)
    }

    /// Draw `image` into a black width×height sRGB canvas using `transform`.
    public static func rasterize(_ image: CGImage, transform: CropTransform,
                                 width: Int = ClipCanvas.width, height: Int = ClipCanvas.height) -> RGBA8Image {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .high
            // Work in a y-down space so offsets and rotation match on-screen gestures.
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: CGFloat(width) / 2 + transform.offsetX, y: CGFloat(height) / 2 + transform.offsetY)
            ctx.rotate(by: transform.rotation)
            ctx.scaleBy(x: transform.scale, y: transform.scale)
            let w = CGFloat(image.width), h = CGFloat(image.height)
            // Flip back locally so the bitmap is drawn upright.
            ctx.translateBy(x: -w / 2, y: h / 2)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // The canvas is opaque black underneath, so premultiplied == straight here.
        return RGBA8Image(width: width, height: height, bytes: bytes)
    }

    // MARK: Adjustments

    public static func apply(_ adj: ImageAdjustments, to img: inout RGBA8Image) {
        let n = img.width * img.height
        img.bytes.withUnsafeMutableBufferPointer { px in
            if adj.touchesToneCurve {
                let lut = toneLUT(brightness: adj.brightness, contrast: adj.contrast)
                lut.withUnsafeBufferPointer { l in
                    for i in 0..<n {
                        let o = i * 4
                        px[o] = l[Int(px[o])]; px[o + 1] = l[Int(px[o + 1])]; px[o + 2] = l[Int(px[o + 2])]
                    }
                }
            }
            if adj.saturation != 1 {
                let s = Float(max(0, adj.saturation))
                Tables.shared.toLinear.withUnsafeBufferPointer { toLin in
                    Tables.shared.toSRGB.withUnsafeBufferPointer { toEnc in
                        let maxIdx = Float(toEnc.count - 1)
                        for i in 0..<n {
                            let o = i * 4
                            let r = toLin[Int(px[o])], g = toLin[Int(px[o + 1])], b = toLin[Int(px[o + 2])]
                            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                            @inline(__always) func enc(_ v: Float) -> UInt8 {
                                let c = min(max(y + (v - y) * s, 0), 1)
                                return toEnc[Int(c * maxIdx + 0.5)]
                            }
                            px[o] = enc(r); px[o + 1] = enc(g); px[o + 2] = enc(b)
                        }
                    }
                }
            }
            if adj.amoledDark {
                Tables.shared.amoled.withUnsafeBufferPointer { f in
                    for i in 0..<n {
                        let o = i * 4
                        let r = Int(px[o]), g = Int(px[o + 1]), b = Int(px[o + 2])
                        // Rec. 709 weights on encoded values, 8.8 fixed point.
                        let luma = (54 * r + 183 * g + 19 * b) >> 8
                        let k = Int(f[luma])          // 0…256
                        if k == 256 { continue }
                        px[o] = UInt8((r * k) >> 8); px[o + 1] = UInt8((g * k) >> 8); px[o + 2] = UInt8((b * k) >> 8)
                    }
                }
            }
        }
    }

    static func toneLUT(brightness: Double, contrast: Double) -> [UInt8] {
        (0..<256).map { i in
            var v = Double(i) / 255
            v = (v - 0.5) * max(0, contrast) + 0.5
            v += brightness * 0.35
            return UInt8(min(max((v * 255).rounded(), 0), 255))
        }
    }

    /// Per-pixel scale factor (0…256) by luma: 0 below ~10/255, smooth to 256 at ~51/255.
    static func amoledCurve() -> [UInt16] {
        let lo = 0.04, hi = 0.20
        return (0..<256).map { i in
            let l = Double(i) / 255
            let t = min(max((l - lo) / (hi - lo), 0), 1)
            let s = t * t * (3 - 2 * t)
            return UInt16((s * 256).rounded())
        }
    }

    // MARK: Quantisation

    /// 4×4 Bayer matrix, values 0…15.
    public static let bayer4: [Int] = [0, 8, 2, 10,
                                       12, 4, 14, 6,
                                       3, 11, 1, 9,
                                       15, 7, 13, 5]

    public enum DitherMode: Sendable, Equatable {
        /// Round to nearest everywhere.
        case none
        /// Bayer dither, except pixels identical (all four RGBA bytes) to each in-bounds 4-neighbour,
        /// which are rounded. Flat colours stay flat so RLE keeps working (PROTOCOL §5 encoder note).
        case flatAware
        /// Classic ordered dither on every pixel.
        case all
        /// Floyd–Steinberg error diffusion (serpentine), for detailed pictures such as tarot cards:
        /// no visible pattern, and gentle gradients (cream paper, reds) don't band. 0 and 255 stay exact.
        case errorDiffusion
    }

    /// RGBA8 → RGB565, bit-identical to `tools/hcaenc.c`:
    /// `q = (v * L * 32 + t * 255) / (255 * 32)`, L = 31 (R,B) or 63 (G), `t = 2 * bayer + 1` when
    /// dithering, `t = 16` (round to nearest) otherwise. 0 maps to 0 and 255 to full scale, so true
    /// black stays true black.
    public static func quantize(_ img: RGBA8Image, dither: Bool) -> RGB565Frame {
        quantize(img, mode: dither ? .flatAware : .none)
    }

    public static func quantize(_ img: RGBA8Image, mode: DitherMode) -> RGB565Frame {
        if mode == .errorDiffusion { return diffuse(img) }
        let w = img.width, h = img.height
        var out = [UInt16](repeating: 0, count: w * h)
        let bayer = bayer4.map { UInt32(2 * $0 + 1) }
        img.bytes.withUnsafeBytes { raw in
            let px = raw.bindMemory(to: UInt8.self)
            @inline(__always) func word(_ k: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: k * 4, as: UInt32.self) }
            out.withUnsafeMutableBufferPointer { dst in
                bayer.withUnsafeBufferPointer { th in
                    for y in 0..<h {
                        let row = (y & 3) * 4
                        for x in 0..<w {
                            let i = y * w + x
                            var dith = mode == .all
                            if mode == .flatAware {
                                let c = word(i)
                                if (x > 0 && word(i - 1) != c) || (x + 1 < w && word(i + 1) != c)
                                    || (y > 0 && word(i - w) != c) || (y + 1 < h && word(i + w) != c) {
                                    dith = true
                                }
                            }
                            let t: UInt32 = dith ? th[row + (x & 3)] : 16
                            let o = i * 4
                            let tt = t * 255
                            let r = (UInt32(px[o]) * 31 * 32 + tt) / 8160
                            let g = (UInt32(px[o + 1]) * 63 * 32 + tt) / 8160
                            let b = (UInt32(px[o + 2]) * 31 * 32 + tt) / 8160
                            dst[i] = UInt16(r << 11 | g << 5 | b)
                        }
                    }
                }
            }
        }
        return RGB565Frame(width: w, height: h, pixels: out)
    }

    /// RGBA8 → RGB565 with Floyd–Steinberg error diffusion, serpentine rows, error carried in 1/16
    /// steps of the 8-bit value. Each channel is quantised to the nearest RGB565 level (bit-replicated
    /// back to 8 bits to measure the error), so pure black and pure white never pick up noise.
    static func diffuse(_ img: RGBA8Image) -> RGB565Frame {
        let w = img.width, h = img.height
        var out = [UInt16](repeating: 0, count: w * h)
        // Errors for this row and the next, per channel, with a pixel of padding on each side (×16).
        var cur = [Int32](repeating: 0, count: (w + 2) * 3), nxt = cur
        img.bytes.withUnsafeBufferPointer { px in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let ltr = y % 2 == 0
                    for i in nxt.indices { nxt[i] = 0 }
                    for step in 0..<w {
                        let x = ltr ? step : w - 1 - step
                        let o = (y * w + x) * 4
                        var word: UInt16 = 0
                        for c in 0..<3 {
                            let levels: Int32 = c == 1 ? 63 : 31
                            let e = (x + 1) * 3 + c
                            let v = min(max(Int32(px[o + c]) * 16 + cur[e], 0), 255 * 16)
                            let level = (v * levels + 255 * 8) / (255 * 16)
                            let back: Int32 = c == 1 ? (level << 2 | level >> 4) : (level << 3 | level >> 2)
                            word |= UInt16(level) << (c == 0 ? 11 : c == 1 ? 5 : 0)
                            let err = v - back * 16
                            let fwd = ltr ? 3 : -3
                            cur[e + fwd] += err * 7 / 16
                            nxt[e - fwd] += err * 3 / 16
                            nxt[e] += err * 5 / 16
                            nxt[e + fwd] += err / 16
                        }
                        dst[y * w + x] = word
                    }
                    swap(&cur, &nxt)
                }
            }
        }
        return RGB565Frame(width: w, height: h, pixels: out)
    }

    // MARK: Previews

    /// RGB565 → CGImage (bit-replicated to 8 bits), for on-screen previews.
    public static func makeCGImage(_ frame: RGB565Frame) -> CGImage? {
        let n = frame.width * frame.height
        var bytes = [UInt8](repeating: 255, count: n * 4)
        frame.pixels.withUnsafeBufferPointer { src in
            bytes.withUnsafeMutableBufferPointer { dst in
                for i in 0..<n {
                    let v = src[i]
                    let r = UInt8(v >> 11), g = UInt8((v >> 5) & 0x3F), b = UInt8(v & 0x1F)
                    let o = i * 4
                    dst[o] = r << 3 | r >> 2
                    dst[o + 1] = g << 2 | g >> 4
                    dst[o + 2] = b << 3 | b >> 2
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: frame.width * 4, space: srgb,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Precomputed colour tables.
final class Tables: Sendable {
    static let shared = Tables()
    /// sRGB-encoded byte → linear light.
    let toLinear: [Float]
    /// Linear light (4096 steps) → sRGB-encoded byte.
    let toSRGB: [UInt8]
    let amoled: [UInt16]

    private init() {
        toLinear = (0..<256).map { i in
            let c = Double(i) / 255
            return Float(c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4))
        }
        toSRGB = (0..<4096).map { i in
            let l = Double(i) / 4095
            let c = l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055
            return UInt8(min(max((c * 255).rounded(), 0), 255))
        }
        amoled = ClipRenderer.amoledCurve()
    }
}
