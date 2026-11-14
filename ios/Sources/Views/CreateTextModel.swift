import Foundation
import Observation
import SwiftUI
import PixelClipKit

/// State of the Text & Marquee editor. Every change re-renders off the main actor (latest wins)
/// through the pipeline so the preview is exactly the clip's. Smooth-scroll and LED styles export one
/// wide strip the clip scrolls itself (tens of KB); typewriter, bounce, ticker and still export frames.
@MainActor @Observable
final class CreateTextModel {
    var spec: MarqueeSpec { didSet { if spec != oldValue { changed() } } }
    var name: String

    private(set) var preview: ClipFrames?
    private(set) var summary: MarqueeSummary?
    /// Set when the current spec exports as a scrolling strip: its width and one pass in ms.
    private(set) var strip: (width: Int, passMs: Int)?
    private(set) var bytes = 0
    private(set) var bytesExact = false
    private(set) var rendering = false
    private(set) var progress = 0
    /// Last full render, for the report and the size readout.
    private(set) var renderMs: Double = 0
    var error: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    static let specURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Create/text.json")

    init(spec: MarqueeSpec? = nil) {
        if let spec {
            self.spec = spec
        } else if let data = try? Data(contentsOf: Self.specURL), let saved = try? JSONDecoder().decode(MarqueeSpec.self, from: data) {
            self.spec = saved
        } else {
            self.spec = MarqueeSpec(font: FontSelection(familyID: FontCatalog.sfRounded, weight: 0.4))
        }
        name = ""
    }

    @ObservationIgnored private var started = false
    /// The LED dot-matrix style switches to a pixel face the first time it's chosen in this editor.
    @ObservationIgnored var ledFontApplied = false

    /// LED dots were just turned on: the first time, start from a pixel face (Press Start 2P, else
    /// Silkscreen) unless the font already is one. Later toggles keep whatever the user picked.
    func ledTurnedOn() {
        guard !ledFontApplied else { return }
        ledFontApplied = true
        if let pixel = FontCatalog.ledDefaultFont(current: spec.font, available: CreateFonts.available) { spec.font = pixel }
    }

    /// Called from the view's `.task`: SwiftUI may build (and drop) several models while it settles
    /// the view, so nothing heavy happens in `init`.
    func start() {
        guard !started else { return }
        started = true
        changed(debounce: false)
    }

    var font: CTFont { CreateFonts.ctFont(spec.font, size: 100) }

    var infoLine: String {
        guard let s = summary else { return "…" }
        var parts: [String] = []
        if let strip {
            parts.append("Scrolling strip · \(strip.width) px")
            parts.append(String(format: "%.1f s per pass", Double(strip.passMs) / 1000))
            parts.append((bytesExact ? "" : "≈ ") + bytes.byteString)
            if bytesExact && bytes > 0 { parts.append(CreateBudget.share(bytes)) }
            return parts.joined(separator: " · ")
        }
        if s.frames == 1 { parts.append("Still") } else {
            parts.append("\(s.frames) frames")
            parts.append(String(format: "%.1f s loop", Double(s.loopMs) / 1000))
        }
        parts.append((bytesExact ? "" : "≈ ") + bytes.byteString)
        if bytesExact && bytes > 0 { parts.append(CreateBudget.share(bytes)) }
        if rendering && s.frames > 1 { parts.append("\(progress)/\(s.frames)") }
        return parts.joined(separator: " · ")
    }

    /// The 3 MB warning: only frame-based exports can get that big (a strip is one frame).
    var tooBig: Bool { strip == nil && bytes > CreateBudget.warning }

    var isStrip: Bool { strip != nil }

    var suggestedName: String {
        let t = spec.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return t.isEmpty ? "Message" : String(t.prefix(28))
    }

    // MARK: Rendering

    private func changed(debounce: Bool = true) {
        guard started else { return }
        persist()
        let spec = spec
        let fontBox = FontBox(font: font)
        // Layout-only numbers right away.
        let s = MarqueeRenderer.summary(spec, font: fontBox.font)
        summary = s
        let stripLayout = MarqueeRenderer.usesStrip(spec) ? MarqueeRenderer.stripWidth(spec, font: fontBox.font) : nil
        let scroll = MarqueeRenderer.scrollBlock(spec)
        strip = stripLayout.map { ($0.width, StripScroller.durationMs(stripWidth: $0.width, scroll: scroll)) }
        generation += 1
        let gen = generation
        task?.cancel()
        rendering = true
        progress = 0
        if stripLayout != nil {
            renderStrip(spec: spec, font: fontBox, generation: gen, debounce: debounce)
            return
        }
        task = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(140)) }
            guard !Task.isCancelled else { return }
            let started = Date()
            let work = Task.detached(priority: .userInitiated) { () -> (ClipFrames?, Int)? in
                var c = PreviewCollector(dither: spec.dither)
                var lastReport = Date()
                do {
                    try MarqueeRenderer.render(spec, font: fontBox.font) { i, f, d in
                        let img = c.add(f, durationMs: d)
                        if i == 0, let img {
                            let box = ImageBox(image: img)
                            Task { @MainActor [weak self] in self?.poster(box.image, generation: gen) }
                        }
                        if Date().timeIntervalSince(lastReport) > 0.1 {
                            lastReport = Date()
                            let n = i + 1
                            Task { @MainActor [weak self] in if self?.generation == gen { self?.progress = n } }
                        }
                    }
                } catch {
                    return nil
                }
                c.flush()
                return (c.frames, c.bytes)
            }
            // Cancelling this task must stop the render too (a detached task doesn't inherit it).
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled, gen == self.generation, let result else { return }
            self.preview = result.0
            self.bytes = result.1
            self.bytesExact = true
            self.rendering = false
            self.renderMs = Date().timeIntervalSince(started) * 1000
            #if DEBUG
            print(String(format: "TEXT_RENDER %d frames (%@%@) in %.0f ms, %@", result.0?.images.count ?? 0, spec.motion.rawValue,
                         spec.led ? "+led" : "", self.renderMs, result.1.byteString))
            #endif
        }
    }

    /// The strip export: draw the message once, quantise it, and size the real `.hca`.
    private func renderStrip(spec: MarqueeSpec, font fontBox: FontBox, generation gen: Int, debounce: Bool) {
        task = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(100)) }
            guard !Task.isCancelled else { return }
            let started = Date()
            let work = Task.detached(priority: .userInitiated) { () -> (ClipFrames, Int)? in
                guard let strip = MarqueeRenderer.renderStrip(spec, font: fontBox.font) else { return nil }
                let p = CreationEncoder(dither: spec.dither).process(strip.image)
                guard let full = p.preview, let first = ClipRenderer.makeCGImage(StripScroller.firstScreen(p.frame)),
                      let data = try? HCAEncoder.encodeStrip(p.frame) else { return nil }
                return (ClipFrames(strip: full, firstScreen: first, scroll: strip.scroll), data.count)
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled, gen == self.generation, let result else { return }
            self.preview = result.0
            self.bytes = result.1
            self.bytesExact = true
            self.rendering = false
            self.renderMs = Date().timeIntervalSince(started) * 1000
            #if DEBUG
            print(String(format: "TEXT_RENDER strip %d px (%@%@) in %.0f ms, %@", result.0.strip?.width ?? 0, spec.motion.rawValue,
                         spec.led ? "+led" : "", self.renderMs, result.1.byteString))
            #endif
        }
    }

    /// First frame of a new render, shown while the rest is drawn (only if it's a still, or the old
    /// preview no longer matches the text at all).
    private func poster(_ img: CGImage, generation gen: Int) {
        guard gen == generation, rendering else { return }
        if preview == nil || summary?.frames == 1 { preview = ClipFrames(single: img) }
        if let s = summary, !bytesExact || bytes == 0 { bytes = CreationEncoder.fileSize(frames: s.frames, payloadBytes: 0) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(spec) else { return }
        try? FileManager.default.createDirectory(at: Self.specURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.specURL, options: .atomic)
    }

    func renderForSave() async throws -> (asset: RenderedAsset, original: Data) {
        let spec = spec
        let fontBox = FontBox(font: font)
        let frames = summary?.frames ?? 1
        if strip != nil {
            return try await Task.detached(priority: .userInitiated) {
                guard let strip = MarqueeRenderer.renderStrip(spec, font: fontBox.font) else { throw HCAEncoder.Error.badGeometry }
                let p = CreationEncoder(dither: spec.dither).process(strip.image)
                let data = try HCAEncoder.encodeStrip(p.frame)
                let poster = ClipRenderer.makeCGImage(StripScroller.firstScreen(p.frame))
                let edit = EditParams(transform: CropTransform(scale: 1), adjustments: ImageAdjustments(amoledDark: false, dither: spec.dither),
                                      trimStart: 0, trimEnd: 0, fps: 0)
                let asset = RenderedAsset(data: data, poster: poster, frameCount: 1, durationMs: strip.passMs, edit: edit,
                                          strip: (strip.width, strip.scroll))
                let original = Raster.cgImage(strip.image).flatMap(ImageLoader.pngData) ?? Data()
                return (asset, original)
            }.value
        }
        return try await Task.detached(priority: .userInitiated) {
            var c = SaveCollector(frameCount: frames, dither: spec.dither)
            try MarqueeRenderer.render(spec, font: fontBox.font) { _, f, d in c.add(f, durationMs: d) }
            return try c.finish(edit: spec.fps, dither: spec.dither)
        }.value
    }

    var recipe: Data? {
        struct Recipe: Encodable { var creator = "text"; var spec: MarqueeSpec }
        return try? JSONEncoder().encode(Recipe(spec: spec))
    }
}

struct ImageBox: @unchecked Sendable { let image: CGImage }
