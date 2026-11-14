import CoreGraphics
import Foundation
import Observation
import PixelClipKit

/// Pure rendering: source frames → clip frames, off the main actor.
enum RenderWorker {
    struct Output: @unchecked Sendable {
        var preview: ClipFrames
        var hca: Data?
        var bytes: Int
    }

    /// Render `images` through the real pipeline and encode. `encodeFile` builds the full .hca.
    static func render(images: [CGImage], durations: [Double], transform: CropTransform, adjustments: ImageAdjustments,
                       encodeFile: Bool) throws -> Output {
        var frames: [HCAEncoder.Frame] = []
        var previews: [CGImage] = []
        var scratch = RLE16Scratch()
        var bytes = HCA.headerSize + images.count * HCA.frameEntrySize
        for (img, d) in zip(images, durations) {
            try Task.checkCancellation()
            let f = ClipRenderer.render(img, transform: transform, adjustments: adjustments)
            bytes += scratch.encode(f.pixels).count
            if let cg = ClipRenderer.makeCGImage(f) { previews.append(cg) }
            if encodeFile { frames.append(.init(pixels: f, durationMs: images.count == 1 ? 0 : Int((d * 1000).rounded()))) }
        }
        let hca = encodeFile ? try HCAEncoder.encode(frames: frames) : nil
        return Output(preview: ClipFrames(images: previews, durations: durations), hca: hca, bytes: hca?.count ?? bytes)
    }
}

/// State for the import/edit screen. Every preview goes through the real encoder, so what you see
/// is what the clip gets.
@MainActor @Observable
final class EditorModel {
    static let fpsChoices: [Double] = [8, 12, 15, 24, 30]
    static let maxFrames = 150
    /// Above this the size readout turns orange (the clip has ~12 MB in total).
    static let sizeWarning = 1_500_000

    let media: ImportedMedia
    var name: String

    var transform: CropTransform { didSet { if transform != oldValue { changed(posterOnly: true) } } }
    var adjustments: ImageAdjustments { didSet { if adjustments != oldValue { changed(posterOnly: false) } } }
    /// 0 = the GIF's own timing.
    var fps: Double { didSet { if fps != oldValue { resample() } } }
    var trimStart: Double { didSet { if trimStart != oldValue { resample() } } }
    var trimEnd: Double { didSet { if trimEnd != oldValue { resample() } } }
    /// Set by the crop canvas while a finger is down: only the poster re-renders.
    var isInteracting = false { didSet { if !isInteracting && oldValue { changed(posterOnly: false) } } }

    /// Source frames after trim/fps (1 for stills).
    private(set) var sourceImages: [CGImage] = []
    private(set) var sourceDurations: [Double] = []
    private(set) var preview: ClipFrames?
    private(set) var bytes = 0
    private(set) var bytesAreExact = false
    private(set) var preparing: String?
    private(set) var capped = false
    var error: String?

    @ObservationIgnored private var posterTask: Task<Void, Never>?
    @ObservationIgnored private var fullTask: Task<Void, Never>?
    @ObservationIgnored private var sampleTask: Task<Void, Never>?
    @ObservationIgnored private var lastFull: (key: Int, output: RenderWorker.Output)?

    init(media: ImportedMedia) {
        self.media = media
        let edit = media.replacing?.edit
        name = media.replacing?.name ?? media.suggestedName
        adjustments = edit?.adjustments ?? .default
        transform = edit?.transform ?? CropTransform(scale: 1)
        switch media.source {
        case .still(let img):
            fps = 0; trimStart = 0; trimEnd = 0
            sourceImages = [img]; sourceDurations = [0]
            if edit == nil { transform = .fill(CGSize(width: img.width, height: img.height)) }
        case .frames(let f):
            fps = edit?.fps ?? 0
            trimStart = edit?.trimStart ?? 0
            trimEnd = edit.map { $0.trimEnd > 0 ? $0.trimEnd : f.totalDuration } ?? f.totalDuration
            if edit == nil { transform = .fill(f.pixelSize) }
        case .video(_, let duration):
            fps = edit?.fps ?? 12
            trimStart = edit?.trimStart ?? 0
            trimEnd = edit.map { $0.trimEnd > 0 ? $0.trimEnd : min(duration, 6) } ?? min(duration, 6)
        }
        if media.source.isAnimated { resample() } else { changed(posterOnly: false) }
    }

    var isAnimated: Bool { media.source.isAnimated }
    var sourceDuration: Double {
        switch media.source {
        case .still: 0
        case .frames(let f): f.totalDuration
        case .video(_, let d): d
        }
    }
    var isVideo: Bool { if case .video = media.source { true } else { false } }
    var posterSource: CGImage? { sourceImages.first }
    var sourceSize: CGSize { posterSource.map { CGSize(width: $0.width, height: $0.height) } ?? ClipCanvas.size }
    var frameCount: Int { max(1, sourceImages.count) }
    /// Frame-based and over the budget (`ClipBudget`): Add is disabled with an explanation.
    var isOverBudget: Bool { ClipBudget.isOverLimit(bytes: bytes, frames: frameCount) }

    var sizeLine: String {
        let size = (bytesAreExact ? "" : "≈ ") + bytes.byteString
        guard isAnimated else { return "Still · \(size)" }
        let rate = fps > 0 ? " · \(Int(fps)) fps" : ""
        return "\(frameCount) frames\(rate) · \(size)"
    }

    // MARK: Sampling

    private func resample() {
        sampleTask?.cancel()
        let start = trimStart, end = max(trimEnd, trimStart + 0.05), fps = fps
        switch media.source {
        case .still: return
        case .frames(let f):
            let sampled = Self.sample(f, start: start, end: end, fps: fps, max: Self.maxFrames)
            capped = sampled.capped
            sourceImages = sampled.images; sourceDurations = sampled.durations
            changed(posterOnly: false)
        case .video(let url, _):
            preparing = "Reading video…"
            let want = Int(((end - start) * max(fps, 1)).rounded(.up))
            capped = want > Self.maxFrames
            sampleTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))   // coalesce slider drags
                guard !Task.isCancelled else { return }
                do {
                    let frames = try await VideoSampler.frames(url: url, start: start, end: end, fps: max(fps, 1), maxFrames: Self.maxFrames)
                    guard !Task.isCancelled, let self else { return }
                    if self.sourceImages.isEmpty, self.media.replacing == nil {
                        self.transform = .fill(frames.pixelSize)
                    }
                    self.sourceImages = frames.images
                    self.sourceDurations = frames.delays
                    self.preparing = nil
                    self.changed(posterOnly: false)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.preparing = nil
                    self?.error = "Couldn’t read frames from this video."
                }
            }
        }
    }

    /// Trim a GIF and optionally resample it to a fixed rate.
    nonisolated static func sample(_ f: SourceFrames, start: Double, end: Double, fps: Double, max cap: Int)
        -> (images: [CGImage], durations: [Double], capped: Bool) {
        var images: [CGImage] = [], durations: [Double] = []
        if fps <= 0 {
            var t = 0.0
            for (img, d) in zip(f.images, f.delays) {
                let mid = t + d / 2
                t += d
                guard mid >= start && mid <= end else { continue }
                images.append(img); durations.append(d)
            }
        } else {
            let n = max(1, Int(((end - start) * fps - 1e-6).rounded(.up)))
            for k in 0..<min(n, cap + 1) {
                let t = start + Double(k) / fps
                var acc = 0.0, pick = f.images.count - 1
                for (i, d) in f.delays.enumerated() { acc += d; if t < acc { pick = i; break } }
                images.append(f.images[pick]); durations.append(1 / fps)
            }
        }
        if images.isEmpty { images = [f.images[0]]; durations = [f.delays.first ?? 0.1] }
        let capped = images.count > cap
        if capped { images = Array(images.prefix(cap)); durations = Array(durations.prefix(cap)) }
        return (images, durations, capped)
    }

    // MARK: Rendering

    private var renderKey: Int {
        var h = Hasher()
        h.combine(transform); h.combine(adjustments); h.combine(sourceImages.count)
        h.combine(sourceDurations); h.combine(trimStart); h.combine(fps)
        for img in sourceImages.prefix(1) { h.combine(ObjectIdentifier(img)) }
        return h.finalize()
    }

    private func changed(posterOnly: Bool) {
        guard !sourceImages.isEmpty else { return }
        renderPoster()
        fullTask?.cancel()
        if !isAnimated { return }   // the poster *is* the full render for stills
        if posterOnly && isInteracting { return }
        let images = sourceImages, durations = sourceDurations, t = transform, a = adjustments, key = renderKey
        fullTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            let out = await Task.detached(priority: .userInitiated) {
                try? RenderWorker.render(images: images, durations: durations, transform: t, adjustments: a, encodeFile: false)
            }.value
            guard let self, !Task.isCancelled, let out else { return }
            self.preview = out.preview
            self.bytes = out.bytes
            self.bytesAreExact = true
            self.lastFull = (key, out)
        }
    }

    /// Latest-wins render of frame 0 (fast feedback while dragging sliders or the image).
    private func renderPoster() {
        guard posterTask == nil else { posterDirty = true; return }
        let img = sourceImages[0], t = transform, a = adjustments, count = sourceImages.count
        posterTask = Task { [weak self] in
            let out = await Task.detached(priority: .userInitiated) {
                try? RenderWorker.render(images: [img], durations: [0], transform: t, adjustments: a, encodeFile: false)
            }.value
            guard let self else { return }
            self.posterTask = nil
            if let out {
                // Animations keep looping the last full render unless it's stale.
                if !self.isAnimated || self.isInteracting || self.lastFull?.key != self.renderKey {
                    self.preview = out.preview
                }
                if !self.isAnimated {
                    self.bytes = out.bytes
                    self.bytesAreExact = true
                } else {
                    self.bytes = HCA.headerSize + (out.bytes - HCA.headerSize) * count
                    self.bytesAreExact = false
                }
            }
            if self.posterDirty { self.posterDirty = false; self.renderPoster() }
        }
    }
    @ObservationIgnored private var posterDirty = false

    /// Final render for saving.
    func renderForSave() async throws -> RenderedAsset {
        let images = sourceImages, durations = sourceDurations, t = transform, a = adjustments
        let out = try await Task.detached(priority: .userInitiated) {
            try RenderWorker.render(images: images, durations: durations, transform: t, adjustments: a, encodeFile: true)
        }.value
        guard let data = out.hca else { throw ImportError.unreadable }
        let edit = EditParams(transform: t, adjustments: a, trimStart: trimStart, trimEnd: trimEnd, fps: fps)
        let loopMs = images.count > 1 ? durations.reduce(0) { $0 + Int(($1 * 1000).rounded()) } : 0
        return RenderedAsset(data: data, poster: out.preview.images.first, frameCount: images.count, durationMs: loopMs, edit: edit)
    }

    // MARK: Crop helpers

    var fitScale: Double { CropTransform.fitScale(for: sourceSize) }
    var fillScale: Double { CropTransform.fillScale(for: sourceSize) }
}
