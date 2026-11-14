import CoreGraphics

/// The drawing canvas always sits at a whole number of device pixels per canvas pixel (a "step"),
/// so pixel art stays crisp. These are the numbers behind the fitted zoom in both orientations.
public enum CanvasZoom {
    /// Breathing room around the fitted canvas, in points, on each side: a little more across than
    /// down (in landscape the height is the scarce side).
    public static let margin = CGSize(width: 8, height: 2)
    /// The pinch zoom goes up to this many times the fitted step.
    public static let maxFactor = 8

    /// The largest step at which the 536×240 canvas (plus `margin` on every side) fits in `size`
    /// points on a screen with `scale` device pixels per point. Never below 1.
    public static func fitStep(in size: CGSize, scale: CGFloat, margin: CGSize = margin) -> Int {
        let w = (size.width - 2 * margin.width) * scale / CGFloat(ClipCanvas.width)
        let h = (size.height - 2 * margin.height) * scale / CGFloat(ClipCanvas.height)
        // A hair of tolerance so an exact fit isn't lost to floating point.
        return max(1, Int((min(w, h) + 1e-6).rounded(.down)))
    }

    /// The canvas's size on screen, in points, at a step.
    public static func canvasSize(step: Int, scale: CGFloat) -> CGSize {
        CGSize(width: CGFloat(ClipCanvas.width * step) / scale, height: CGFloat(ClipCanvas.height * step) / scale)
    }

    /// The landscape Draw editor around the canvas: the tool rail on one side, the navigation bar
    /// on top and the frame strip along the bottom (all in points).
    public struct LandscapeChrome: Sendable, Equatable {
        public var railWidth: CGFloat
        public var navigationBar: CGFloat
        public var strip: CGFloat
        public init(railWidth: CGFloat, navigationBar: CGFloat = navigationBarHeight, strip: CGFloat = stripExpanded) {
            self.railWidth = railWidth; self.navigationBar = navigationBar; self.strip = strip
        }
        /// The inline navigation bar in iPhone landscape on iOS 26 (measured on the iPhone 18 Pro:
        /// the safe area's top inset under it is 78 pt).
        public static let navigationBarHeight: CGFloat = 78
        /// Rail cells are 44 pt (the minimum touch target), 4 pt apart across and 2 pt down, with
        /// 8 pt of padding at the sides.
        public static let railCell: CGFloat = 44
        public static let railSpacing: CGFloat = 4
        public static let railRowSpacing: CGFloat = 2
        public static let railPadding: CGFloat = 8
        public static func railWidth(columns: Int) -> CGFloat {
            CGFloat(columns) * railCell + CGFloat(max(0, columns - 1)) * railSpacing + 2 * railPadding
        }
        /// Frame strip heights: 40-pt thumbnails, or one thin line when collapsed.
        public static let stripExpanded: CGFloat = 48
        public static let stripCollapsed: CGFloat = 32

        /// Three rail columns (every tool and action visible without scrolling), the compact
        /// navigation bar and the expanded frame strip.
        public static let standard = LandscapeChrome(railWidth: railWidth(columns: 3))
        public static let twoColumns = LandscapeChrome(railWidth: railWidth(columns: 2))
    }

    /// Three rail columns unless the narrower two-column rail would buy a bigger zoom step (SE-class
    /// phones). `available` is the editor's area inside the safe area and below the navigation bar.
    public static func railColumns(available: CGSize, scale: CGFloat, strip: CGFloat = LandscapeChrome.stripExpanded) -> Int {
        func step(_ columns: Int) -> Int {
            fitStep(in: CGSize(width: available.width - LandscapeChrome.railWidth(columns: columns), height: available.height - strip), scale: scale)
        }
        return step(3) >= step(2) ? 3 : 2
    }

    /// Safe-area insets, in points.
    public struct Insets: Sendable, Equatable {
        public var top, leading, bottom, trailing: CGFloat
        public init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
            self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
        }
    }

    /// The space left for the canvas in the landscape editor on a screen of `screen` points.
    public static func landscapeCanvasArea(screen: CGSize, safeArea: Insets, chrome: LandscapeChrome = .standard) -> CGSize {
        CGSize(width: max(0, screen.width - safeArea.leading - safeArea.trailing - chrome.railWidth),
               height: max(0, screen.height - safeArea.top - safeArea.bottom - chrome.navigationBar - chrome.strip))
    }

    /// The fitted step in the landscape editor.
    public static func landscapeFitStep(screen: CGSize, safeArea: Insets, scale: CGFloat, chrome: LandscapeChrome = .standard) -> Int {
        fitStep(in: landscapeCanvasArea(screen: screen, safeArea: safeArea, chrome: chrome), scale: scale)
    }

    /// When the container changes size (rotation), keep the zoom relative to the fit: Fit stays
    /// Fit, ×2 stays ×2 (rounded to a whole step and clamped to the new range).
    public static func carriedStep(_ step: Int, from oldFit: Int, to newFit: Int) -> Int {
        guard oldFit > 0, newFit > 0 else { return max(1, newFit) }
        let factor = Double(step) / Double(oldFit)
        let carried = Int((factor * Double(newFit)).rounded())
        return min(max(carried, newFit), newFit * maxFactor)
    }

    /// The zoom readout: "Fit", "×2", "×1.5".
    public static func label(step: Int, fit: Int) -> String {
        guard step != fit, fit > 0 else { return "Fit" }
        let factor = Double(step) / Double(fit)
        if factor == factor.rounded() { return "×\(Int(factor))" }
        let s = String(Int((factor * 10).rounded()))
        return "×\(s.dropLast()).\(s.suffix(1))"
    }
}
