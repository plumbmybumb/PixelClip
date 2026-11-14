import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The last stage for everything made in Create: canvas-sized RGBA frames → the clip pipeline
/// (adjustments + RGB565 quantisation) → `.hca`. Flat art isn't dithered unless asked, and the
/// AMOLED curve stays off (a chosen dark background colour is intentional).
public struct CreationEncoder: Sendable {
    public var adjustments: ImageAdjustments

    public init(dither: Bool = false) {
        adjustments = ImageAdjustments(amoledDark: false, dither: dither)
    }

    /// True when the pipeline reduces to "round each channel to RGB565" (no tone changes, no dither),
    /// which vImage does bit-identically and fast.
    public var isPlainQuantize: Bool {
        adjustments.brightness == 0 && adjustments.contrast == 1 && adjustments.saturation == 1
            && !adjustments.amoledDark && !adjustments.dither
    }

    /// One frame through the pipeline. `rgba` must be opaque and canvas-sized.
    public func quantize(_ rgba: RGBA8Image) -> RGB565Frame { process(rgba, preview: false).frame }

    /// The pipeline frame plus its on-screen preview (bit-identical to `ClipRenderer.makeCGImage`).
    public func process(_ rgba: RGBA8Image, preview: Bool = true) -> (frame: RGB565Frame, preview: CGImage?) {
        guard isPlainQuantize else {
            var img = rgba
            ClipRenderer.apply(adjustments, to: &img)
            let f = ClipRenderer.quantize(img, dither: adjustments.dither)
            return (f, preview ? ClipRenderer.makeCGImage(f) : nil)
        }
        let w = rgba.width, h = rgba.height
        var pixels = [UInt16](repeating: 0, count: w * h)
        var shown: [UInt8] = preview ? [UInt8](repeating: 0, count: w * h * 4) : []
        rgba.bytes.withUnsafeBytes { sp in
            var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: sp.baseAddress!), height: vImagePixelCount(h),
                                    width: vImagePixelCount(w), rowBytes: w * 4)
            pixels.withUnsafeMutableBytes { dp in
                // (v*31+127)/255 per channel == the pipeline's round-to-nearest (v*31*32+16*255)/8160.
                var dst = vImage_Buffer(data: dp.baseAddress!, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 2)
                _ = vImageConvert_RGBA8888toRGB565(&src, &dst, vImage_Flags(kvImageNoFlags))
            }
            if preview {
                shown.withUnsafeMutableBytes { dp in
                    var dst = vImage_Buffer(data: dp.baseAddress!, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                    // Tables are applied in memory order (R, G, B, A for our buffers).
                    _ = vImageTableLookUp_ARGB8888(&src, &dst, Self.show5, Self.show6, Self.show5, Self.opaque, vImage_Flags(kvImageNoFlags))
                }
            }
        }
        let frame = RGB565Frame(width: w, height: h, pixels: pixels)
        guard preview, let provider = CGDataProvider(data: Data(shown) as CFData) else { return (frame, nil) }
        let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        return (frame, img)
    }

    /// 8-bit value → its RGB565 level, bit-replicated back to 8 bits (what the preview shows).
    static let show5: [UInt8] = (0..<256).map { v in let q = (v * 31 * 32 + 16 * 255) / 8160; return UInt8(q << 3 | q >> 2) }
    static let show6: [UInt8] = (0..<256).map { v in let q = (v * 63 * 32 + 16 * 255) / 8160; return UInt8(q << 2 | q >> 4) }
    static let opaque = [UInt8](repeating: 255, count: 256)

    /// A rendered CGImage (exactly 536×240, e.g. from `PKDrawing.image(from:scale:)`) through the pipeline.
    public func quantize(_ image: CGImage) -> RGB565Frame {
        quantize(ClipRenderer.rasterize(image, transform: CropTransform(scale: 1)))
    }

    /// Assemble a file. A single frame is a still (duration 0); otherwise durations are per frame.
    public static func encode(_ frames: [RGB565Frame], durationsMs: [Int]) throws -> Data {
        let still = frames.count == 1
        return try HCAEncoder.encode(frames: frames.enumerated().map { i, f in
            HCAEncoder.Frame(pixels: f, durationMs: still ? 0 : (i < durationsMs.count ? durationsMs[i] : HCA.defaultFrameDurationMs))
        })
    }

    /// Compressed size of one frame (for live size estimates).
    public static func rleSize(_ frame: RGB565Frame, scratch: inout RLE16Scratch) -> Int {
        scratch.encode(frame.pixels).count
    }

    /// File size for frames whose RLE payloads total `payloadBytes`.
    public static func fileSize(frames: Int, payloadBytes: Int) -> Int {
        HCA.headerSize + frames * HCA.frameEntrySize + payloadBytes
    }
}

/// Lossless animated PNG of the pre-quantisation frames: the "original" stored with a created
/// library item (re-openable by the import editor, which reads APNG).
public final class APNGWriter {
    private let data = NSMutableData()
    private let dest: CGImageDestination?
    private var count = 0

    public init(frameCount: Int) {
        dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, max(1, frameCount), nil)
        if let dest, frameCount > 1 {
            CGImageDestinationSetProperties(dest, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
        }
    }

    public func add(_ image: CGImage, durationMs: Int) {
        guard let dest else { return }
        let props = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: max(0.02, Double(durationMs) / 1000)]]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        count += 1
    }

    public func finish() -> Data? {
        guard let dest, count > 0, CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
