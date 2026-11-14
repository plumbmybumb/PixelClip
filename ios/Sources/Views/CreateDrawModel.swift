import Observation
import PencilKit
import SwiftUI
import UIKit
import PixelClipKit

enum DrawTool: String, CaseIterable, Identifiable {
    case pen, marker, highlighter, crayon, eraser, fill, pixel, shape, text, sticker, move

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pen: "Pen"
        case .marker: "Marker"
        case .highlighter: "Highlight"
        case .crayon: "Crayon"
        case .eraser: "Eraser"
        case .fill: "Fill"
        case .pixel: "Pixel"
        case .shape: "Shapes"
        case .text: "Text"
        case .sticker: "Stickers"
        case .move: "Move"
        }
    }
    var systemImage: String {
        switch self {
        case .pen: "pencil.tip"
        case .marker: "paintbrush.pointed"
        case .highlighter: "highlighter"
        case .crayon: "scribble.variable"
        case .eraser: "eraser"
        case .fill: "drop.halffull"
        case .pixel: "square.grid.3x3.square"
        case .shape: "square.on.circle"
        case .text: "character.textbox"
        case .sticker: "face.smiling"
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        }
    }
    /// Handled by PencilKit (everything else goes through our touch layer).
    var isInk: Bool { [.pen, .marker, .highlighter, .crayon, .eraser].contains(self) }
}

enum ShapeKind: String, CaseIterable, Identifiable {
    case line, rect, ellipse
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .line: "line.diagonal"
        case .rect: "rectangle"
        case .ellipse: "circle"
        }
    }
}

/// Everything the canvas shows besides the PencilKit ink.
struct CanvasLayers: Equatable {
    var pixels: CGImage?
    var overlays: CGImage?
    var onionPrev: CGImage?
    var onionNext: CGImage?
}

/// State of the Draw & Animate editor. The document is a `DrawingDocument` (PixelClipKit) persisted as a
/// draft after every change; PencilKit drawings are cached per frame.
@MainActor @Observable
final class CreateDrawModel {
    let store: DraftStore
    private(set) var doc: DrawingDocument
    private(set) var current = 0

    var tool: DrawTool = .pen { didSet { if tool != .move { selection = nil }; refreshLayers() } }
    var color = RGBAColor.accent { didSet { recolorSelection() } }
    var width: Double = 6
    var pixelCell = 4
    /// Fill and pixel tools clear instead of paint.
    var erasing = false
    var shapeKind = ShapeKind.rect
    var shapeFilled = false
    var sticker = "heart.fill"
    var textFont = FontSelection.systemBold
    var stampSize: Double = 44 { didSet { resizeSelection() } }
    private(set) var selection: UUID? { didSet { refreshLayers() } }
    var playing = false { didSet { refreshPreview() } }
    /// Set when the text tool is tapped: the view asks for the words.
    var pendingTextPoint: CGPoint?
    var zoomLabel = "Fit"

    private(set) var preview: ClipFrames?
    private(set) var layers = CanvasLayers()
    private(set) var thumbnails: [UUID: CGImage] = [:]
    /// Bumped when the canvas must reload the current frame's ink (frame switch, undo, shapes).
    private(set) var canvasRevision = 0
    private(set) var canUndo = false
    private(set) var canRedo = false
    var error: String?

    @ObservationIgnored private var drawings: [UUID: PKDrawing] = [:]
    @ObservationIgnored private var versions: [UUID: Int] = [:]
    @ObservationIgnored private var rendered: [UUID: (version: Int, image: CGImage, bytes: Int)] = [:]
    @ObservationIgnored private var undoStack: [Snapshot] = []
    @ObservationIgnored private var redoStack: [Snapshot] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var dirty: Set<UUID> = []

    private struct Snapshot { var frames: [DrawingFrame]; var current: Int; var background: RGBAColor }

    init(draftID: String?, store: DraftStore = .standard()) {
        self.store = store
        if let draftID, let d = try? store.load(draftID) {
            doc = d
        } else {
            let n = store.list().count + 1
            doc = DrawingDocument(name: n == 1 ? "Drawing" : "Drawing \(n)")
        }
        dirty = Set(doc.frames.map(\.id))
    }

    @ObservationIgnored private var started = false

    /// Called from the view's `.task` (SwiftUI may create and discard models while settling a view).
    func start() {
        guard !started else { return }
        started = true
        scheduleRender(immediate: true)
        refreshLayers()
    }

    // MARK: Accessors

    var frames: [DrawingFrame] { doc.frames }
    var currentFrame: DrawingFrame { doc.frames[current] }
    var frameCount: Int { doc.frames.count }

    var name: String {
        get { doc.name }
        set { doc.name = newValue; scheduleSave() }
    }
    var background: RGBAColor {
        get { doc.background }
        set { guard newValue != doc.background else { return }; checkpoint(); doc.background = newValue; dirtyAll() }
    }
    var fps: Int {
        get { doc.fps }
        set { doc.fps = newValue; refreshPreview(); scheduleSave() }
    }
    var dither: Bool {
        get { doc.dither }
        set { doc.dither = newValue; dirtyAll() }
    }
    var onionSkin: Bool {
        get { doc.onionSkin }
        set { doc.onionSkin = newValue; refreshLayers(); scheduleSave() }
    }

    func drawing(at index: Int) -> PKDrawing {
        let f = doc.frames[index]
        if let d = drawings[f.id] { return d }
        let d = f.ink.isEmpty ? PKDrawing() : ((try? PKDrawing(data: f.ink)) ?? PKDrawing())
        drawings[f.id] = d
        return d
    }

    var currentDrawing: PKDrawing { drawing(at: current) }

    var bytes: Int {
        let payload = doc.frames.reduce(0) { $0 + (rendered[$1.id]?.bytes ?? 0) }
        return CreationEncoder.fileSize(frames: doc.frames.count, payloadBytes: payload)
    }

    var infoLine: String {
        var parts = ["Frame \(current + 1) of \(frameCount)"]
        if frameCount > 1 { parts.append("\(doc.fps) fps · \(String(format: "%.1f s", Double(doc.loopMs) / 1000))") }
        parts.append(bytes.byteString)
        return parts.joined(separator: " · ")
    }

    var selectedOverlay: CanvasOverlay? { currentFrame.overlays.first { $0.id == selection } }

    // MARK: PencilKit tool

    var pkTool: PKTool {
        let ui = color.uiColor
        switch tool {
        case .pen: return PKInkingTool(.pen, color: ui, width: width)
        case .marker: return PKInkingTool(.monoline, color: ui, width: width)
        case .highlighter: return PKInkingTool(.marker, color: ui, width: max(8, width * 2.5))
        case .crayon: return PKInkingTool(.crayon, color: ui, width: max(6, width * 1.5))
        case .eraser: return PKEraserTool(.bitmap, width: max(6, width * 2))
        default: return PKInkingTool(.pen, color: ui, width: width)
        }
    }

    // MARK: Undo

    private func checkpoint() {
        undoStack.append(Snapshot(frames: doc.frames, current: current, background: doc.background))
        if undoStack.count > 40 { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true; canRedo = false
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(Snapshot(frames: doc.frames, current: current, background: doc.background))
        restore(s)
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(Snapshot(frames: doc.frames, current: current, background: doc.background))
        restore(s)
    }

    private func restore(_ s: Snapshot) {
        let changed = Set(s.frames.map(\.id)).union(doc.frames.map(\.id))
        doc.frames = s.frames
        doc.background = s.background
        current = min(s.current, doc.frames.count - 1)
        for id in changed { drawings[id] = nil }
        canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty
        selection = nil
        canvasRevision += 1
        dirtyAll()
    }

    // MARK: Edits from the canvas

    /// PencilKit finished a stroke (or erased).
    func inkChanged(_ d: PKDrawing) {
        let id = currentFrame.id
        let data = d.dataRepresentation()
        guard data != doc.frames[current].ink else { return }
        checkpoint()
        drawings[id] = d
        doc.frames[current].ink = data
        frameChanged(id)
    }

    func fill(at p: CGPoint) {
        let x = Int(p.x), y = Int(p.y)
        guard x >= 0, y >= 0, x < ClipCanvas.width, y < ClipCanvas.height else { return }
        let reference = composite(current, background: doc.background)
        var layer = currentFrame.pixels ?? PixelLayer()
        var trial = layer
        guard trial.floodFill(x: x, y: y, reference: reference, tolerance: 48, color: erasing ? nil : color) > 0 else { return }
        checkpoint()
        layer = trial
        doc.frames[current].pixels = layer.isEmpty ? nil : layer
        frameChanged(currentFrame.id)
    }

    func beginPixels(at p: CGPoint) {
        checkpoint()
        var layer = currentFrame.pixels ?? PixelLayer()
        layer.setCell(x: Int(p.x), y: Int(p.y), cell: pixelCell, color: erasing ? nil : color)
        doc.frames[current].pixels = layer
        frameChanged(currentFrame.id, live: true)
    }

    func continuePixels(from a: CGPoint, to b: CGPoint) {
        var layer = currentFrame.pixels ?? PixelLayer()
        layer.strokeCells(from: (Int(a.x.rounded(.down)), Int(a.y.rounded(.down))), to: (Int(b.x.rounded(.down)), Int(b.y.rounded(.down))),
                          cell: pixelCell, color: erasing ? nil : color)
        doc.frames[current].pixels = layer
        frameChanged(currentFrame.id, live: true)
    }

    func endPixels() {
        if doc.frames[current].pixels?.isEmpty == true { doc.frames[current].pixels = nil }
        frameChanged(currentFrame.id)
    }

    func addShape(from a: CGPoint, to b: CGPoint) {
        guard hypot(b.x - a.x, b.y - a.y) > 2 else { return }
        checkpoint()
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        if shapeFilled && shapeKind != .line {
            var layer = currentFrame.pixels ?? PixelLayer()
            let c = color.withAlpha(1).cgColor
            let kind = shapeKind
            layer.draw { ctx in
                ctx.setFillColor(c)
                if kind == .rect { ctx.fill(rect) } else { ctx.fillEllipse(in: rect) }
            }
            doc.frames[current].pixels = layer
        } else {
            var d = currentDrawing
            d.strokes.append(Self.shapeStroke(shapeKind, a, b, color: color.uiColor, width: width))
            drawings[currentFrame.id] = d
            doc.frames[current].ink = d.dataRepresentation()
            canvasRevision += 1
        }
        frameChanged(currentFrame.id)
    }

    /// A rectangle / ellipse / line as a real PencilKit stroke (so the eraser and undo treat it as ink).
    static func shapeStroke(_ kind: ShapeKind, _ a: CGPoint, _ b: CGPoint, color: UIColor, width: Double) -> PKStroke {
        var pts: [CGPoint] = []
        func segment(_ p: CGPoint, _ q: CGPoint) {
            let n = max(2, Int(hypot(q.x - p.x, q.y - p.y) / 3))
            for i in 0...n { let t = CGFloat(i) / CGFloat(n); pts.append(CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)) }
            // Repeat the corner so the spline stays sharp there.
            pts.append(q); pts.append(q)
        }
        switch kind {
        case .line:
            segment(a, b)
        case .rect:
            let p0 = a, p1 = CGPoint(x: b.x, y: a.y), p2 = b, p3 = CGPoint(x: a.x, y: b.y)
            pts.append(p0); pts.append(p0)
            segment(p0, p1); segment(p1, p2); segment(p2, p3); segment(p3, p0)
        case .ellipse:
            let c = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), rx = abs(b.x - a.x) / 2, ry = abs(b.y - a.y) / 2
            let n = max(48, Int((rx + ry) / 2))
            for i in 0...n {
                let t = CGFloat(i) / CGFloat(n) * 2 * .pi
                pts.append(CGPoint(x: c.x + rx * cos(t), y: c.y + ry * sin(t)))
            }
        }
        let size = CGSize(width: width, height: width)
        let points = pts.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: TimeInterval(i) * 0.004, size: size, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.monoline, color: color), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    // MARK: Overlays

    func addText(_ text: String, at p: CGPoint) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        checkpoint()
        let o = CanvasOverlay(kind: .text(s, textFont), center: p, size: stampSize, color: color)
        doc.frames[current].overlays.append(o)
        selection = o.id
        frameChanged(currentFrame.id)
    }

    func placeSticker(at p: CGPoint) {
        checkpoint()
        let o = CanvasOverlay(kind: .sticker(sticker), center: p, size: stampSize * 1.3, color: color)
        doc.frames[current].overlays.append(o)
        frameChanged(currentFrame.id)
    }

    /// Start dragging the overlay under `p` (topmost first). Returns false when nothing is there.
    func beginMove(at p: CGPoint) -> Bool {
        guard let o = currentFrame.overlays.last(where: { FrameCompositor.bounds(of: $0, providers: CreateStickers.providers).contains(p) }) else {
            selection = nil
            return false
        }
        checkpoint()
        selection = o.id
        return true
    }

    func moveSelection(by d: CGSize) {
        guard let i = currentFrame.overlays.firstIndex(where: { $0.id == selection }) else { return }
        doc.frames[current].overlays[i].center.x += d.width
        doc.frames[current].overlays[i].center.y += d.height
        frameChanged(currentFrame.id, live: true)
    }

    func endMove() { frameChanged(currentFrame.id) }

    func deleteSelection() {
        guard let id = selection else { return }
        checkpoint()
        doc.frames[current].overlays.removeAll { $0.id == id }
        selection = nil
        frameChanged(currentFrame.id)
    }

    func select(overlay id: UUID?) {
        selection = id
        if let o = selectedOverlay { stampSize = o.kind.isSticker ? o.size / 1.3 : o.size }
    }

    private func resizeSelection() {
        guard let i = currentFrame.overlays.firstIndex(where: { $0.id == selection }) else { return }
        let o = doc.frames[current].overlays[i]
        let size = o.kind.isSticker ? stampSize * 1.3 : stampSize
        guard abs(o.size - size) > 0.5 else { return }
        doc.frames[current].overlays[i].size = size
        frameChanged(currentFrame.id, live: true)
    }

    private func recolorSelection() {
        guard let i = currentFrame.overlays.firstIndex(where: { $0.id == selection }), doc.frames[current].overlays[i].color != color else { return }
        checkpoint()
        doc.frames[current].overlays[i].color = color
        frameChanged(currentFrame.id)
    }

    // MARK: Frames

    func selectFrame(_ i: Int) {
        guard i != current, doc.frames.indices.contains(i) else { return }
        current = i
        selection = nil
        canvasRevision += 1
        refreshLayers()
        refreshPreview()
    }

    func addFrame() {
        guard frameCount < DrawingDocument.maxFrames else { return }
        checkpoint()
        doc.frames.insert(DrawingFrame(), at: current + 1)
        dirty.insert(doc.frames[current + 1].id)
        selectFrame(current + 1)
        structureChanged()
    }

    func duplicateFrame(_ i: Int) {
        guard frameCount < DrawingDocument.maxFrames else { return }
        checkpoint()
        let copy = doc.frames[i].duplicated()
        doc.frames.insert(copy, at: i + 1)
        dirty.insert(copy.id)
        selectFrame(i + 1)
        structureChanged()
    }

    func deleteFrame(_ i: Int) {
        checkpoint()
        if frameCount == 1 {
            doc.frames[0] = DrawingFrame()
        } else {
            doc.frames.remove(at: i)
        }
        dirty.insert(doc.frames[min(i, frameCount - 1)].id)
        current = min(current >= i ? max(0, current - 1) : current, frameCount - 1)
        if frameCount == 1 { current = 0 }
        canvasRevision += 1
        structureChanged()
    }

    func moveFrame(from: Int, to: Int) {
        guard from != to, doc.frames.indices.contains(from), doc.frames.indices.contains(to) else { return }
        checkpoint()
        let f = doc.frames.remove(at: from)
        doc.frames.insert(f, at: to)
        current = to
        canvasRevision += 1
        structureChanged()
    }

    func moveFrame(id: UUID, before target: UUID) {
        guard let from = doc.frames.firstIndex(where: { $0.id == id }), let to = doc.frames.firstIndex(where: { $0.id == target }) else { return }
        moveFrame(from: from, to: to)
    }

    func setHold(_ i: Int, _ hold: Int) {
        guard doc.frames[i].hold != hold else { return }
        checkpoint()
        doc.frames[i].hold = hold
        structureChanged()
    }

    func clearFrame() {
        checkpoint()
        let id = currentFrame.id
        doc.frames[current] = DrawingFrame(id: id, hold: currentFrame.hold)
        drawings[id] = PKDrawing()
        canvasRevision += 1
        frameChanged(id)
    }

    // MARK: Rendering

    private func frameChanged(_ id: UUID, live: Bool = false) {
        versions[id, default: 0] += 1
        dirty.insert(id)
        refreshLayers()
        scheduleRender(immediate: live)
        scheduleSave()
    }

    private func structureChanged() {
        refreshLayers()
        refreshPreview()
        scheduleRender(immediate: false)
        scheduleSave()
    }

    private func dirtyAll() {
        for f in doc.frames { versions[f.id, default: 0] += 1; dirty.insert(f.id) }
        refreshLayers()
        scheduleRender(immediate: false)
        scheduleSave()
    }

    func inkImage(_ d: PKDrawing) -> CGImage? {
        guard !d.strokes.isEmpty else { return nil }
        var img: UIImage?
        // Inks adapt to dark mode; render with the light trait so colours are exactly the ones picked.
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            img = d.image(from: CGRect(origin: .zero, size: ClipCanvas.size), scale: 1)
        }
        return img?.cgImage
    }

    /// The frame flattened at 536×240 (what goes into the pipeline).
    func composite(_ index: Int, background: RGBAColor?) -> RGBA8Image {
        let f = doc.frames[index]
        return FrameCompositor.composite(background: background, pixels: f.pixels, ink: inkImage(drawing(at: index)),
                                         overlays: f.overlays, providers: CreateStickers.providers)
    }

    /// Re-render dirty frames through the pipeline (current frame first), then refresh the preview.
    private func scheduleRender(immediate: Bool) {
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(90)) }
            guard let self, !Task.isCancelled else { return }
            let encoder = CreationEncoder(dither: doc.dither)
            let order = [currentFrame.id] + doc.frames.map(\.id).filter { $0 != currentFrame.id }
            for id in order where dirty.contains(id) {
                guard !Task.isCancelled, let i = doc.frames.firstIndex(where: { $0.id == id }) else { continue }
                let out = encoder.process(composite(i, background: doc.background))
                var scratch = RLE16Scratch()
                if let img = out.preview {
                    rendered[id] = (versions[id, default: 0], img, CreationEncoder.rleSize(out.frame, scratch: &scratch))
                    thumbnails[id] = img
                }
                dirty.remove(id)
                if id == currentFrame.id { refreshPreview() }
                await Task.yield()
            }
            refreshPreview()
            let live = Set(doc.frames.map(\.id))
            for k in thumbnails.keys where !live.contains(k) { thumbnails[k] = nil; rendered[k] = nil }
        }
    }

    private func refreshPreview() {
        if playing && frameCount > 1 {
            let imgs = doc.frames.compactMap { rendered[$0.id]?.image }
            guard imgs.count == frameCount else { return }
            preview = ClipFrames(images: imgs, durations: doc.durationsMs.map { Double($0) / 1000 })
        } else if let img = rendered[currentFrame.id]?.image {
            preview = ClipFrames(single: img)
        }
    }

    /// Paint layer, overlays and onion skins for the canvas.
    private func refreshLayers() {
        let f = currentFrame
        var l = CanvasLayers()
        if let p = f.pixels, !p.isEmpty { l.pixels = Raster.cgImage(p.image) }
        if !f.overlays.isEmpty { l.overlays = Raster.cgImage(FrameCompositor.overlayLayer(f.overlays, providers: CreateStickers.providers)) }
        if doc.onionSkin && frameCount > 1 {
            if current > 0 { l.onionPrev = onion(current - 1, tint: RGBAColor(hex: 0xFF5A5F)) }
            if current + 1 < frameCount { l.onionNext = onion(current + 1, tint: RGBAColor(hex: 0x4CD964)) }
        }
        layers = l
    }

    @ObservationIgnored private var onionCache: [UUID: (Int, CGImage)] = [:]

    /// A neighbour frame as a tinted silhouette.
    private func onion(_ i: Int, tint: RGBAColor) -> CGImage? {
        let f = doc.frames[i]
        let v = versions[f.id, default: 0] &* 31 &+ (tint == RGBAColor(hex: 0xFF5A5F) ? 1 : 2)
        if let hit = onionCache[f.id], hit.0 == v { return hit.1 }
        var img = composite(i, background: nil)
        let (r, g, b, _) = tint.premultipliedBytes
        img.bytes.withUnsafeMutableBufferPointer { p in
            for k in stride(from: 0, to: p.count, by: 4) where p[k + 3] != 0 {
                let a = UInt32(p[k + 3])
                p[k] = UInt8(UInt32(r) * a / 255); p[k + 1] = UInt8(UInt32(g) * a / 255); p[k + 2] = UInt8(UInt32(b) * a / 255)
            }
        }
        let cg = Raster.cgImage(img)
        if let cg { onionCache[f.id] = (v, cg) }
        return cg
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        doc.updatedAt = Date()
        let thumb = (rendered[doc.frames[0].id]?.image).flatMap(ImageLoader.pngData)
        do { try store.save(doc, thumbnail: thumb) } catch { self.error = "Couldn’t save the draft. Try again." }
    }

    /// Every frame through the pipeline, plus the APNG original.
    func renderForSave() throws -> (asset: RenderedAsset, original: Data) {
        var c = SaveCollector(frameCount: frameCount, dither: doc.dither)
        for i in doc.frames.indices { c.add(composite(i, background: doc.background), durationMs: doc.durationMs(i)) }
        return try c.finish(edit: Double(doc.fps), dither: doc.dither)
    }

    func markSaved(itemID: String) {
        doc.libraryItemID = itemID
        saveNow()
    }

    var recipe: Data? {
        struct Recipe: Encodable { var creator = "draw"; var draftID: String }
        return try? JSONEncoder().encode(Recipe(draftID: doc.id))
    }
}

extension CanvasOverlay.Kind {
    var isSticker: Bool { if case .sticker = self { true } else { false } }
}
