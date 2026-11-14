import CoreGraphics
import CoreText
import Foundation

/// Flattens a drawing frame: background → paint layer → ink → overlays, at exactly 536×240.
/// The app supplies the ink image (PencilKit), fonts (UIFont) and sticker art (SF Symbols).
public struct OverlayProviders: @unchecked Sendable {
    public var font: (FontSelection, CGFloat) -> CTFont
    /// A symbol rendered `height` px tall in `color` (nil if unknown).
    public var sticker: (String, CGFloat, RGBAColor) -> CGImage?

    public init(font: @escaping (FontSelection, CGFloat) -> CTFont,
                sticker: @escaping (String, CGFloat, RGBAColor) -> CGImage?) {
        self.font = font; self.sticker = sticker
    }

    /// CoreText fonts, no stickers (tests, previews without UIKit).
    public static let basic = OverlayProviders(font: { FontCatalog.ctFont(for: $0, size: $1) }, sticker: { _, _, _ in nil })
}

public enum FrameCompositor {
    /// `background: nil` leaves the frame transparent (onion skins, thumbnails of content only).
    public static func composite(background: RGBAColor?, pixels: PixelLayer?, ink: CGImage?, overlays: [CanvasOverlay],
                                 providers: OverlayProviders,
                                 width: Int = ClipCanvas.width, height: Int = ClipCanvas.height) -> RGBA8Image {
        Raster.draw(width: width, height: height, background: background?.withAlpha(1)) { ctx in
            let full = CGRect(x: 0, y: 0, width: width, height: height)
            if let pixels, !pixels.isEmpty, let img = Raster.cgImage(pixels.image) {
                ctx.interpolationQuality = .none
                ctx.draw(img, in: full)
                ctx.interpolationQuality = .high
            }
            if let ink { ctx.draw(ink, in: full) }
            drawOverlays(overlays, in: ctx, providers: providers, height: height)
        }
    }

    /// Overlays alone on transparent (the canvas shows them on a layer above the ink).
    public static func overlayLayer(_ overlays: [CanvasOverlay], providers: OverlayProviders,
                                    width: Int = ClipCanvas.width, height: Int = ClipCanvas.height) -> RGBA8Image {
        Raster.draw(width: width, height: height) { ctx in drawOverlays(overlays, in: ctx, providers: providers, height: height) }
    }

    static func drawOverlays(_ overlays: [CanvasOverlay], in ctx: CGContext, providers: OverlayProviders, height: Int) {
        for o in overlays {
            let cy = CGFloat(height) - o.center.y   // y-up
            switch o.kind {
            case .text(let s, let sel):
                let layout = TextLayoutEngine.layout(s, font: providers.font(sel, CGFloat(o.size)), size: CGFloat(o.size))
                let origins = TextPainter.centredOrigins(layout, center: CGPoint(x: o.center.x, y: cy))
                TextPainter.draw(layout, in: ctx, origins: origins, style: TextStyle(fill: .solid(o.color)))
            case .sticker(let name):
                guard let img = providers.sticker(name, CGFloat(o.size), o.color) else { continue }
                let h = CGFloat(o.size), w = h * CGFloat(img.width) / CGFloat(max(1, img.height))
                ctx.draw(img, in: CGRect(x: o.center.x - w / 2, y: cy - h / 2, width: w, height: h))
            }
        }
    }

    /// An overlay's box in canvas coordinates (y-down), for hit-testing and selection.
    public static func bounds(of o: CanvasOverlay, providers: OverlayProviders) -> CGRect {
        switch o.kind {
        case .text(let s, let sel):
            let layout = TextLayoutEngine.layout(s, font: providers.font(sel, CGFloat(o.size)), size: CGFloat(o.size))
            let ink = layout.blockInk
            guard !ink.isNull else { return CGRect(x: o.center.x - 10, y: o.center.y - 10, width: 20, height: 20) }
            return CGRect(x: o.center.x - layout.maxInkWidth / 2, y: o.center.y - ink.height / 2,
                          width: layout.maxInkWidth, height: ink.height).insetBy(dx: -4, dy: -4)
        case .sticker:
            let s = CGFloat(o.size)
            return CGRect(x: o.center.x - s / 2, y: o.center.y - s / 2, width: s, height: s).insetBy(dx: -4, dy: -4)
        }
    }
}
