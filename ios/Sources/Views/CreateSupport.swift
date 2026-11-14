import CoreText
import SwiftUI
import UIKit
import PixelClipKit

// Shared plumbing for the makers (Draw, Write): font resolution (UIFont), colour bridging,
// sticker art, pipeline output → preview frames, and saving into the library through the existing store.

// MARK: - Fonts

/// The curated font list, filtered to what's actually installed (checked once per launch).
enum CreateFonts {
    /// `UIFont.familyNames` at launch, plus the bundled (UIAppFonts) families that resolve by name.
    static let installed: Set<String> = Set(UIFont.familyNames).union(FontCatalog.registeredBundledFamilies())
    static let available: [FontChoice] = FontCatalog.available(installed: installed)
    /// Curated names that aren't on this device (shown nowhere; logged for the report).
    static let missing: [String] = FontCatalog.curated.compactMap { c in
        guard let f = c.familyName, !available.contains(where: { $0.id == c.id }) else { return nil }
        return f
    }

    static func choice(_ id: String) -> FontChoice {
        available.first { $0.id == id } ?? available[0]
    }

    static func byMood(_ mood: FontMood) -> [FontChoice] { available.filter { $0.mood == mood } }

    private static let facesCache = LockedCache<String, [FontFace]>()

    static func faces(_ choice: FontChoice) -> [FontFace] {
        guard let family = choice.familyName else { return [] }
        if let hit = facesCache[family] { return hit }
        let f = FontCatalog.faces(ofFamily: family)
        facesCache[family] = f
        return f
    }

    static func weights(_ choice: FontChoice) -> [(weight: Double, name: String)] {
        if choice.systemDesign != nil { return FontCatalog.systemWeights }
        return FontCatalog.weightSteps(faces(choice))
    }

    static func hasItalic(_ choice: FontChoice) -> Bool {
        switch choice.systemDesign {
        case .rounded: false
        case .some: true
        case nil: faces(choice).contains { $0.italic }
        }
    }

    static func uiFont(_ sel: FontSelection, size: CGFloat) -> UIFont {
        let c = choice(sel.familyID)
        guard let design = c.systemDesign else {
            return FontCatalog.ctFont(for: sel, size: size) as UIFont
        }
        var font = UIFont.systemFont(ofSize: size, weight: UIFont.Weight(rawValue: sel.weight))
        let uiDesign: UIFontDescriptor.SystemDesign = switch design {
        case .standard: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
        if let d = font.fontDescriptor.withDesign(uiDesign) { font = UIFont(descriptor: d, size: size) }
        if sel.italic, let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            font = UIFont(descriptor: d, size: size)
        }
        return font
    }

    static func ctFont(_ sel: FontSelection, size: CGFloat) -> CTFont { uiFont(sel, size: size) as CTFont }

    /// SwiftUI font for labels in the picker.
    static func swiftUIFont(_ choice: FontChoice, size: CGFloat) -> Font {
        Font(uiFont(FontSelection(familyID: choice.id, weight: choice.systemDesign == nil ? 0 : 0.3), size: size))
    }
}

/// A tiny thread-safe dictionary (font faces, sticker art).
final class LockedCache<K: Hashable & Sendable, V>: @unchecked Sendable {
    private var store: [K: V] = [:]
    private let lock = NSLock()
    subscript(key: K) -> V? {
        get { lock.withLock { store[key] } }
        set { lock.withLock { store[key] = newValue } }
    }
}

/// CTFont isn't annotated Sendable but is immutable and thread-safe.
struct FontBox: @unchecked Sendable { let font: CTFont }

// MARK: - Stickers

enum CreateStickers {
    /// SF Symbols offered as stickers (filtered to those present on this OS).
    static let all: [String] = [
        "heart.fill", "star.fill", "sparkles", "sun.max.fill", "moon.stars.fill", "cloud.fill", "bolt.fill", "flame.fill",
        "drop.fill", "snowflake", "leaf.fill", "camera.macro", "music.note", "music.quarternote.3", "face.smiling.inverse",
        "hand.wave.fill", "hand.thumbsup.fill", "crown.fill", "gift.fill", "balloon.2.fill", "birthday.cake.fill",
        "party.popper.fill", "pawprint.fill", "cat.fill", "dog.fill", "bird.fill", "fish.fill", "hare.fill", "ladybug.fill",
        "airplane", "tram.fill", "bicycle", "figure.dance", "gamecontroller.fill", "headphones", "eye.fill", "mouth.fill",
        "wand.and.stars", "rainbow", "arrow.right", "exclamationmark.3", "checkmark.seal.fill", "infinity", "peacesign",
        "globe.europe.africa.fill", "atom", "eyeglasses", "mustache.fill", "cup.and.saucer.fill", "wineglass.fill",
    ].filter { UIImage(systemName: $0) != nil }

    private static let cache = LockedCache<String, CGImage>()

    /// The symbol rendered `height` px tall (scale 1) in `color`. Thread-safe.
    static func image(_ name: String, height: CGFloat, color: RGBAColor) -> CGImage? {
        let key = "\(name)|\(Int(height))|\(color.r),\(color.g),\(color.b),\(color.a)"
        if let hit = cache[key] { return hit }
        let config = UIImage.SymbolConfiguration(pointSize: height, weight: .semibold)
        guard let symbol = UIImage(systemName: name, withConfiguration: config) else { return nil }
        let aspect = symbol.size.width / max(1, symbol.size.height)
        let size = CGSize(width: max(1, (height * aspect).rounded()), height: max(1, height.rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let ui = UIColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)
        let img = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            symbol.withTintColor(ui, renderingMode: .alwaysOriginal).draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
        if let img { cache[key] = img }
        return img
    }

    static let providers = OverlayProviders(font: { CreateFonts.ctFont($0, size: $1) },
                                            sticker: { CreateStickers.image($0, height: $1, color: $2) })
}

// MARK: - Colours

extension RGBAColor {
    init(_ color: Color) {
        let ui = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if !ui.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var w: CGFloat = 0
            ui.getWhite(&w, alpha: &a); r = w; g = w; b = w
        }
        self.init(min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1), a)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }
}

extension Binding where Value == RGBAColor {
    /// For `ColorPicker`.
    var color: Binding<Color> {
        Binding<Color>(get: { wrappedValue.color }, set: { wrappedValue = RGBAColor($0) })
    }
}

// MARK: - Pipeline output

/// Collects pipeline frames for on-screen previews: exactly what the clip will show. Frames are
/// quantised and RLE-sized in parallel batches (the RLE count dominates in debug builds).
struct PreviewCollector {
    private(set) var images: [CGImage] = []
    private(set) var durations: [Double] = []
    private(set) var payload = 0
    private var pending: [RGBA8Image] = []
    private var pendingDurations: [Int] = []
    let encoder: CreationEncoder
    static let batch = max(2, ProcessInfo.processInfo.activeProcessorCount) * 2

    init(dither: Bool) { encoder = CreationEncoder(dither: dither) }

    /// Queue a frame. Returns its preview when it was processed right away (the first frame).
    @discardableResult
    mutating func add(_ rgba: RGBA8Image, durationMs: Int) -> CGImage? {
        pending.append(rgba)
        pendingDurations.append(durationMs)
        if images.isEmpty || pending.count >= Self.batch {
            flush()
            return images.count == 1 ? images[0] : nil
        }
        return nil
    }

    mutating func flush() {
        guard !pending.isEmpty else { return }
        let n = pending.count
        let frames = pending, enc = encoder
        var out = [(CGImage?, Int)](repeating: (nil, 0), count: n)
        out.withUnsafeMutableBufferPointer { results in
            let r = ResultSlots(base: results)   // each iteration writes only its own slot
            DispatchQueue.concurrentPerform(iterations: n) { i in
                let p = enc.process(frames[i])
                var scratch = RLE16Scratch()
                r.base[i] = (p.preview, CreationEncoder.rleSize(p.frame, scratch: &scratch))
            }
        }
        for (i, o) in out.enumerated() {
            guard let img = o.0 else { continue }
            images.append(img)
            durations.append(Double(pendingDurations[i]) / 1000)
            payload += o.1
        }
        pending.removeAll(keepingCapacity: true)
        pendingDurations.removeAll(keepingCapacity: true)
    }

    /// Call `flush()` first.
    var frames: ClipFrames? {
        images.isEmpty ? nil : ClipFrames(images: images, durations: images.count == 1 ? [0] : durations)
    }
    var bytes: Int { CreationEncoder.fileSize(frames: images.count, payloadBytes: payload) }
}

private struct ResultSlots: @unchecked Sendable { let base: UnsafeMutableBufferPointer<(CGImage?, Int)> }

/// Collects everything needed to store an item: RGB565 frames for the .hca, the APNG original and
/// a poster.
struct SaveCollector {
    private(set) var frames: [RGB565Frame] = []
    private(set) var durations: [Int] = []
    private(set) var poster: CGImage?
    private let apng: APNGWriter
    let encoder: CreationEncoder

    init(frameCount: Int, dither: Bool) {
        apng = APNGWriter(frameCount: frameCount)
        encoder = CreationEncoder(dither: dither)
    }

    mutating func add(_ rgba: RGBA8Image, durationMs: Int) {
        let f = encoder.quantize(rgba)
        if poster == nil { poster = ClipRenderer.makeCGImage(f) }
        frames.append(f)
        durations.append(durationMs)
        if let cg = Raster.cgImage(rgba) { apng.add(cg, durationMs: durationMs) }
    }

    func finish(edit fps: Double, dither: Bool) throws -> (asset: RenderedAsset, original: Data) {
        let data = try CreationEncoder.encode(frames, durationsMs: durations)
        let loop = frames.count > 1 ? durations.reduce(0, +) : 0
        let edit = EditParams(transform: CropTransform(scale: 1), adjustments: ImageAdjustments(amoledDark: false, dither: dither),
                              trimStart: 0, trimEnd: Double(loop) / 1000, fps: fps)
        let asset = RenderedAsset(data: data, poster: poster, frameCount: frames.count, durationMs: loop, edit: edit)
        let original = apng.finish() ?? poster.flatMap(ImageLoader.pngData) ?? Data()
        return (asset, original)
    }
}

// MARK: - Library

@MainActor
enum CreateLibrary {
    /// Store (or replace) a created item. `recipe` is the creator's JSON, kept beside the asset
    /// (`create.json`) so the item reopens in its creator.
    static func save(_ asset: RenderedAsset, original: Data, name: String, recipe: Data?, replacing: String?,
                     library: LibraryStore) throws -> LibraryItem {
        if ClipBudget.isOverLimit(bytes: asset.data.count, frames: asset.frameCount, isStrip: asset.strip != nil) {
            throw BudgetError(bytes: asset.data.count)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = replacing.flatMap { library.item($0) }
        let finalName = existing?.name ?? (trimmed.isEmpty ? "Untitled" : trimmed)
        let item = try library.add(asset, name: finalName, source: .created, original: original,
                                   originalExtension: "png", replacing: existing?.id)
        if let recipe { try? recipe.write(to: library.folder(item.id).appendingPathComponent(CreateRecipe.fileName), options: .atomic) }
        return item
    }
}

/// A frame-based item over `ClipBudget.maxAnimationBytes` (until the firmware pans on its own).
struct BudgetError: LocalizedError {
    let bytes: Int
    var errorDescription: String? {
        "This is \(bytes.byteString), over the \(ClipBudget.maxAnimationBytes.byteString) an animation can be for now. Make it shorter or use fewer frames."
    }
}

/// What a created item was made from (`create.json`): reopens it in Draw, Text or Cards.
enum CreateRecipe: Hashable {
    case text(MarqueeSpec)
    case card(CardSpec)
    case draw(draftID: String)

    static let fileName = "create.json"

    private struct Envelope: Decodable {
        var creator: String
        var spec: MarqueeSpec?
        var card: CardSpec?
        var draftID: String?
        enum CodingKeys: String, CodingKey { case creator, spec, draftID }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            creator = try c.decode(String.self, forKey: .creator)
            draftID = try c.decodeIfPresent(String.self, forKey: .draftID)
            switch creator {
            case "text": spec = try c.decodeIfPresent(MarqueeSpec.self, forKey: .spec)
            case "card": card = try c.decodeIfPresent(CardSpec.self, forKey: .spec)
            default: break
            }
        }
    }

    init?(data: Data) {
        guard let e = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        switch e.creator {
        case "text": guard let s = e.spec else { return nil }; self = .text(s)
        case "card": guard let c = e.card else { return nil }; self = .card(c)
        case "draw": guard let d = e.draftID else { return nil }; self = .draw(draftID: d)
        default: return nil
        }
    }

    @MainActor static func load(_ item: LibraryItem, library: LibraryStore) -> CreateRecipe? {
        (try? Data(contentsOf: library.folder(item.id).appendingPathComponent(fileName))).flatMap(CreateRecipe.init(data:))
    }

    /// "Text · LED sign", "Card · Greeting", "Drawing".
    var label: String {
        switch self {
        case .text(let s):
            let style: String = switch s.motion {
            case .scroll: s.led ? "LED sign" : "Scroll"
            case .typewriter: "Typewriter"
            case .bounce: "Bounce"
            case .ticker: "Ticker"
            case .still: "Still"
            }
            return "Text · \(style)"
        case .card(let c): return "Card · \(c.template.rawValue.capitalized)"
        case .draw: return "Drawing"
        }
    }

    var creatorName: String {
        switch self {
        case .text: "Text"
        case .card: "Quick Cards"
        case .draw: "Draw"
        }
    }

    var systemImage: String {
        switch self {
        case .text: "textformat"
        case .card: "rectangle.on.rectangle.angled"
        case .draw: "pencil.tip.crop.circle"
        }
    }
}

/// How much of the clip's storage something takes.
enum CreateBudget {
    /// The clip has about 12 MB for pictures.
    static let clipBytes = 12_000_000
    /// Above this the readout turns orange (frame-based exports only: a strip is one frame).
    static let warning = 3_000_000
    static func share(_ bytes: Int) -> String {
        let pct = Double(bytes) / Double(clipBytes) * 100
        return pct < 1 ? "<1% of the clip" : "\(Int(pct.rounded()))% of the clip"
    }
}
