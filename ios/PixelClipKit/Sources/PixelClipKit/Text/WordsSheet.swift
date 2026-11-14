import CoreGraphics
import CoreText
import Foundation

/// The `words` scene's sheet (PROTOCOL §5b.1): one frame per word of a short text, drawn by the phone in a Write
/// look on black (black is transparent on the clip), at the largest size that keeps the words readable and free to
/// move. The clip finds each frame's ink box and bounces the words with the IMU; the phone shows them resting along
/// the bottom edge (`restingStill`).
public struct WordsSheetSpec: Sendable, Hashable {
    public var text: String
    public var font: FontSelection
    /// The DOTS look: the words go through the LED dot-matrix pattern.
    public var led: Bool
    public var ledPitch: Int
    /// Letter-spacing in ems.
    public var tracking: Double
    public var color: RGBAColor

    public init(text: String, font: FontSelection, led: Bool = false, ledPitch: Int = 5, tracking: Double = 0,
                color: RGBAColor = .accent) {
        self.text = text; self.font = font; self.led = led; self.ledPitch = ledPitch; self.tracking = tracking; self.color = color
    }

    /// The words, in order (whitespace-separated, at most `WordsSheetRenderer.maxWords`).
    public var words: [String] { WordsSheetRenderer.words(text) }
}

public struct WordsSheet: Sendable {
    /// `words-<10 hex>`: a hash of the text, the look and the size (stable: the same text and look give the same id).
    public var id: String
    public var words: [String]
    /// The point size chosen.
    public var pointSize: Double
    /// One frame per word, all `width × height`, the word's ink centred on black.
    public var frames: [RGB565Frame]
    public var width: Int { frames.first?.width ?? 0 }
    public var height: Int { frames.first?.height ?? 0 }
    /// The `.hca` (RGB565BE, RLE16 when it's smaller, glyph-atlas flag: its frames are sprites, not an animation).
    public var data: Data
}

public enum WordsSheetRenderer {
    /// PROTOCOL §5b.1 limits.
    public static let maxWords = 12
    public static let maxCapHeight: CGFloat = 72
    public static let maxWordWidth: CGFloat = 360
    public static let maxLineHeight: CGFloat = 96
    /// The words' ink may cover at most this share of the screen (so they have room to move).
    public static let maxInkShare = 0.45
    /// N · w · h of the sheet.
    public static let maxSheetPixels = 514_560
    /// Frames are the largest word box plus this (in total, per axis).
    public static let framePadding = 2

    public enum Failure: Error, Equatable { case noWords, tooLarge }

    /// The words of `text`: whitespace-separated, at most 12.
    public static func words(_ text: String) -> [String] {
        Array(text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init).prefix(maxWords))
    }

    /// The number of words in `text` (not capped), for the text box's "7 of 12 words".
    public static func wordCount(_ text: String) -> Int { text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }

    /// What the size search measures at one point size.
    public struct Measure: Sendable, Equatable {
        public var size: Double
        public var capHeight: CGFloat
        public var lineHeight: CGFloat
        /// Each word's ink box (glyph path bounds), in line coordinates (y up from the baseline).
        public var inks: [CGRect]
        public var widest: CGFloat { inks.map(\.width).max() ?? 0 }
        public var inkArea: CGFloat { inks.reduce(0) { $0 + $1.width * $1.height } }
        public var frameWidth: Int { Int((inks.map(\.width).max() ?? 0).rounded(.up)) + framePadding }
        public var frameHeight: Int { Int((inks.map(\.height).max() ?? 0).rounded(.up)) + framePadding }

        /// Within every §5b.1 limit.
        public var fits: Bool {
            let screen = CGFloat(ClipCanvas.width * ClipCanvas.height)
            return capHeight <= maxCapHeight && lineHeight <= maxLineHeight && widest <= maxWordWidth
                && inkArea <= screen * maxInkShare
                && frameWidth <= ClipCanvas.width && frameHeight <= ClipCanvas.height
                && inks.count * frameWidth * frameHeight <= maxSheetPixels
        }
    }

    static func line(_ word: String, font: CTFont, spec: WordsSheetSpec) -> CTLine {
        let size = CTFontGetSize(font)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): spec.color.cgColor,
            NSAttributedString.Key(kCTKernAttributeName as String): spec.tracking * Double(size),
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: attrs))
    }

    public static func measure(_ spec: WordsSheetSpec, size: Double, makeFont: (CGFloat) -> CTFont) -> Measure {
        let font = makeFont(CGFloat(size))
        let inks = spec.words.map { CTLineGetBoundsWithOptions(line($0, font: font, spec: spec), .useGlyphPathBounds).integral }
        return Measure(size: size, capHeight: CTFontGetCapHeight(font),
                       lineHeight: CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font), inks: inks)
    }

    /// The largest point size within every limit (binary search, to 0.25 pt).
    public static func pickSize(_ spec: WordsSheetSpec, makeFont: (CGFloat) -> CTFont) -> Measure? {
        guard !spec.words.isEmpty else { return nil }
        var lo = 4.0, hi = 240.0
        guard measure(spec, size: lo, makeFont: makeFont).fits else { return nil }
        while hi - lo > 0.25 {
            let mid = (lo + hi) / 2
            if measure(spec, size: mid, makeFont: makeFont).fits { lo = mid } else { hi = mid }
        }
        return measure(spec, size: lo, makeFont: makeFont)
    }

    public static func render(_ spec: WordsSheetSpec,
                              makeFont: (CGFloat) -> CTFont? = { _ in nil }) throws -> WordsSheet {
        func resolve(_ size: CGFloat) -> CTFont { makeFont(size) ?? FontCatalog.ctFont(for: spec.font, size: size) }
        guard !spec.words.isEmpty else { throw Failure.noWords }
        guard let m = pickSize(spec, makeFont: resolve) else { throw Failure.tooLarge }
        let font = resolve(CGFloat(m.size))
        let w = m.frameWidth, h = m.frameHeight
        var frames: [RGB565Frame] = []
        for (word, ink) in zip(spec.words, m.inks) {
            let l = line(word, font: font, spec: spec)
            var img = Raster.draw(width: w, height: h, background: .black) { ctx in
                // Centre the ink box in the frame (CoreGraphics is y-up: the ink's minY is above the baseline).
                let x = (CGFloat(w) - ink.width) / 2 - ink.minX
                let y = (CGFloat(h) - ink.height) / 2 - ink.minY
                ctx.textPosition = CGPoint(x: x.rounded(), y: y.rounded())
                CTLineDraw(l, ctx)
            }
            if spec.led { img = DotMatrix.render(img, pitch: max(3, spec.ledPitch)) }
            frames.append(ClipRenderer.quantize(img, dither: false))
        }
        let hcaFrames = frames.map { HCAEncoder.Frame(pixels: $0, durationMs: 0) }
        let rle = try HCAEncoder.encode(frames: hcaFrames, glyphAtlas: true, compression: .rle16)
        let raw = try HCAEncoder.encode(frames: hcaFrames, glyphAtlas: true, compression: .raw)
        return WordsSheet(id: sheetID(spec, size: m.size), words: spec.words, pointSize: m.size, frames: frames,
                          data: rle.count <= raw.count ? rle : raw)
    }

    /// `words-<10 hex of SHA-256 of the text, the look and the size>`.
    public static func sheetID(_ spec: WordsSheetSpec, size: Double) -> String {
        let key = [spec.words.joined(separator: " "), spec.font.familyID, String(format: "%.2f", spec.font.weight),
                   spec.font.italic ? "i" : "", spec.led ? "led\(spec.ledPitch)" : "", String(format: "%.3f", spec.tracking),
                   String(format: "%.3f,%.3f,%.3f", spec.color.r, spec.color.g, spec.color.b), String(format: "%.2f", size)].joined(separator: "\u{1}")
        return "words-" + Hashing.sha256Hex(Data(key.utf8)).prefix(10)
    }

    // MARK: The still (the phone's preview, the virtual clip)

    /// Each frame's tight box of non-black pixels (nil: no ink), as the clip finds it.
    public static func inkBox(_ f: RGB565Frame) -> (x: Int, y: Int, w: Int, h: Int)? {
        var x0 = f.width, y0 = f.height, x1 = -1, y1 = -1
        for y in 0..<f.height {
            for x in 0..<f.width where f.pixels[y * f.width + x] != 0 {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        return x1 < 0 ? nil : (x0, y0, x1 - x0 + 1, y1 - y0 + 1)
    }

    /// The words resting along the bottom edge (as they settle when the clip is still): rows from the bottom up,
    /// left to right with 8 px between words, each row centred, black elsewhere. No physics.
    public static func restingStill(_ frames: [RGB565Frame], width: Int = ClipCanvas.width, height: Int = ClipCanvas.height) -> RGB565Frame {
        var out = RGB565Frame(width: width, height: height)
        let gap = 8
        let boxes = frames.compactMap { f in inkBox(f).map { (f, $0) } }
        // Rows, filled in reading order, the first row at the bottom.
        var rows: [[(RGB565Frame, (x: Int, y: Int, w: Int, h: Int))]] = [[]]
        var used = 0
        for b in boxes {
            let need = (rows[rows.count - 1].isEmpty ? 0 : gap) + b.1.w
            if !rows[rows.count - 1].isEmpty && used + need > width { rows.append([]); used = 0 }
            used += (rows[rows.count - 1].isEmpty ? 0 : gap) + b.1.w
            rows[rows.count - 1].append(b)
        }
        var bottom = height
        for row in rows where !row.isEmpty {
            let rowW = row.reduce(0) { $0 + $1.1.w } + gap * (row.count - 1)
            let rowH = row.map(\.1.h).max() ?? 0
            var x = max(0, (width - rowW) / 2)
            for (f, box) in row {
                let top = bottom - box.h   // resting on the row's floor
                for yy in 0..<box.h where top + yy >= 0 && top + yy < height {
                    for xx in 0..<box.w where x + xx < width {
                        let p = f.pixels[(box.y + yy) * f.width + box.x + xx]
                        if p != 0 { out.pixels[(top + yy) * width + x + xx] = p }
                    }
                }
                x += box.w + gap
            }
            bottom -= rowH
            if bottom <= 0 { break }
        }
        return out
    }
}
