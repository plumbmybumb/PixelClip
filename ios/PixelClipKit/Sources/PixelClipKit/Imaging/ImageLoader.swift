import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decoded source media ready for the crop editor.
public struct SourceFrames: @unchecked Sendable {
    // CGImage is immutable and thread-safe; Sendable conformance is missing only for historical reasons.
    public var images: [CGImage]
    /// Seconds per frame, same count as `images`.
    public var delays: [Double]

    public init(images: [CGImage], delays: [Double]) {
        precondition(images.count == delays.count)
        self.images = images; self.delays = delays
    }

    public var isAnimated: Bool { images.count > 1 }
    public var totalDuration: Double { delays.reduce(0, +) }
    public var pixelSize: CGSize {
        images.first.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
    }
}

public enum ImageLoader {
    public enum LoadError: Error { case unreadable }

    /// Default working resolution for editing. Big enough for 8× zoom on the 536-px canvas
    /// without making every live re-render expensive.
    public static let editingMaxPixel = 2048
    public static let animationMaxPixel = 1072
    public static let maxAnimationFrames = 600

    /// Decode a still or an animated image (GIF, APNG, HEICS). EXIF orientation is applied.
    public static func load(data: Data, maxPixel: Int? = nil) throws -> SourceFrames {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { throw LoadError.unreadable }
        return try load(source: src, maxPixel: maxPixel)
    }

    public static func load(url: URL, maxPixel: Int? = nil) throws -> SourceFrames {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw LoadError.unreadable }
        return try load(source: src, maxPixel: maxPixel)
    }

    static func load(source src: CGImageSource, maxPixel: Int?) throws -> SourceFrames {
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { throw LoadError.unreadable }
        let animated = count > 1
        let limit = maxPixel ?? (animated ? animationMaxPixel : editingMaxPixel)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        var images: [CGImage] = []
        var delays: [Double] = []
        for i in 0..<min(count, maxAnimationFrames) {
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) else { continue }
            images.append(img)
            delays.append(animated ? frameDelay(src, i) : 0)
        }
        guard !images.isEmpty else { throw LoadError.unreadable }
        return SourceFrames(images: images, delays: delays)
    }

    /// Per-frame delay with browser-compatible clamping (< 20 ms → 100 ms).
    static func frameDelay(_ src: CGImageSource, _ i: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] else { return 0.1 }
        let dicts: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for (dk, unclamped, clamped) in dicts {
            if let d = props[dk] as? [CFString: Any] {
                let v = (d[unclamped] as? Double) ?? (d[clamped] as? Double) ?? 0.1
                return v < 0.02 ? 0.1 : v
            }
        }
        return 0.1
    }

    /// Encode a CGImage as PNG (used for originals/thumbnails on disk).
    public static func pngData(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

public enum Hashing {
    /// Lower-case hex SHA-256, as sent in `X-Content-SHA256` and reported by `GET /assets`.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
