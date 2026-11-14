import CoreGraphics
import XCTest
@testable import PixelClipKit

final class DrawingTests: XCTestCase {

    // MARK: Pixel layer

    func testCellLineHasNoGaps() {
        let cells = PixelLayer.cellLine(from: (3, 3), to: (90, 41), cell: 8)
        XCTAssertEqual(cells.first!.x, 0); XCTAssertEqual(cells.first!.y, 0)
        XCTAssertEqual(cells.last!.x, 11); XCTAssertEqual(cells.last!.y, 5)
        for (a, b) in zip(cells, cells.dropFirst()) {
            XCTAssertLessThanOrEqual(max(abs(a.x - b.x), abs(a.y - b.y)), 1)
        }
    }

    func testPixelPenSnapsToTheGrid() {
        var layer = PixelLayer()
        layer.setCell(x: 13, y: 5, cell: 4, color: .white)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { layer.bytes[(y * 536 + x) * 4 + 3] }
        for y in 4..<8 { for x in 12..<16 { XCTAssertEqual(alpha(x, y), 255) } }
        XCTAssertEqual(alpha(11, 5), 0); XCTAssertEqual(alpha(16, 5), 0); XCTAssertEqual(alpha(12, 3), 0)
        layer.setCell(x: 12, y: 4, cell: 4, color: nil)
        XCTAssertTrue(layer.isEmpty)
    }

    func testFloodFillStopsAtLines() {
        // A white ring on black; fill inside it.
        let reference = Raster.draw(width: 536, height: 240, background: .black) { ctx in
            ctx.setStrokeColor(RGBAColor.white.cgColor)
            ctx.setLineWidth(4)
            ctx.strokeEllipse(in: CGRect(x: 100, y: 40, width: 200, height: 160))
        }
        var layer = PixelLayer()
        let n = layer.floodFill(x: 200, y: 120, reference: reference, tolerance: 40, color: RGBAColor(hex: 0xFF0000), dilate: 1)
        XCTAssertGreaterThan(n, 20_000)
        XCTAssertLessThan(n, 30_000, "stayed inside the ring (π·98·78 ≈ 24k px)")
        XCTAssertEqual(layer.bytes[(120 * 536 + 200) * 4], 255)
        XCTAssertEqual(layer.bytes[(10 * 536 + 10) * 4 + 3], 0, "outside untouched")
        // Dilation grows the region by one pixel ring.
        let m0 = PixelLayer.regionMask(x: 200, y: 120, reference: reference, tolerance: 40, dilate: 0).filter { $0 }.count
        let m1 = PixelLayer.regionMask(x: 200, y: 120, reference: reference, tolerance: 40, dilate: 1).filter { $0 }.count
        XCTAssertGreaterThan(m1, m0)
    }

    // MARK: Drafts

    func makeDocument() -> DrawingDocument {
        var pixels = PixelLayer()
        pixels.setCell(x: 40, y: 40, cell: 8, color: .accent)
        var doc = DrawingDocument(name: "Heart", background: RGBAColor(hex: 0x101030), fps: 10)
        var rng = SeededRNG(7)
        doc.frames = (0..<3).map { i in
            DrawingFrame(ink: Data((0..<(200 + i * 50)).map { _ in UInt8.random(in: 0...255, using: &rng) }),
                         pixels: i == 1 ? pixels : nil,
                         overlays: i == 2 ? [CanvasOverlay(kind: .text("Hi ✨", .systemBold), center: CGPoint(x: 100, y: 50), size: 40, color: .white),
                                             CanvasOverlay(kind: .sticker("heart.fill"), center: CGPoint(x: 400, y: 120), size: 60, color: .accent)] : [],
                         hold: i + 1)
        }
        doc.libraryItemID = "heart-1a2b"
        return doc
    }

    func testDraftPersistenceRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DraftStore(root: root)
        let doc = makeDocument()
        try store.save(doc, thumbnail: Data([1, 2, 3]))
        let back = try store.load(doc.id)
        XCTAssertEqual(back, doc)
        XCTAssertEqual(back.frames[1].pixels, doc.frames[1].pixels)
        XCTAssertEqual(back.durationsMs, [100, 200, 300])
        let list = store.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].frameCount, 3)
        XCTAssertEqual(list[0].name, "Heart")
        XCTAssertNotNil(list[0].thumbnailURL)
        // A fresh store on the same folder (an app restart) sees it too.
        XCTAssertEqual(try DraftStore(root: root).load(doc.id), doc)
        store.delete(doc.id)
        XCTAssertTrue(store.list().isEmpty)
    }

    func testDuplicateGetsNewIdentity() {
        let f = makeDocument().frames[2]
        let d = f.duplicated()
        XCTAssertNotEqual(d.id, f.id)
        XCTAssertEqual(d.ink, f.ink)
        XCTAssertNotEqual(d.overlays[0].id, f.overlays[0].id)
    }

    // MARK: Export

    /// Stand-in for `PKDrawing.image(from:scale:)`: strokes on transparent at 536×240.
    func inkImage(_ i: Int) -> CGImage {
        Raster.cgImage(Raster.draw(width: 536, height: 240) { ctx in
            ctx.setStrokeColor(RGBAColor(hex: 0x33E0FF).cgColor)
            ctx.setLineWidth(6)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: 60 + i * 40, y: 60))
            ctx.addLine(to: CGPoint(x: 260 + i * 40, y: 180))
            ctx.strokePath()
        })!
    }

    func exportedFile() throws -> (Data, [RGB565Frame]) {
        let doc = makeDocument()
        let enc = CreationEncoder(dither: doc.dither)
        let frames = doc.frames.enumerated().map { i, f in
            enc.quantize(FrameCompositor.composite(background: doc.background, pixels: f.pixels, ink: inkImage(i),
                                                   overlays: f.overlays, providers: .basic))
        }
        return (try CreationEncoder.encode(frames, durationsMs: doc.durationsMs), frames)
    }

    func testDrawingExportProducesAValidAnimation() throws {
        let (data, frames) = try exportedFile()
        let file = try HCAFile(data: data)
        XCTAssertEqual(file.width, 536); XCTAssertEqual(file.height, 240)
        XCTAssertEqual(file.frameCount, 3)
        XCTAssertEqual(file.frames.map(\.durationMs), [100, 200, 300])
        for i in 0..<3 { XCTAssertEqual(try file.decodeFrame(i), frames[i]) }
        // Flat art isn't dithered: the background stays a single RGB565 value.
        let bg = frames[0].pixels[0]
        XCTAssertTrue(frames[0].pixels[0..<(536 * 30)].allSatisfy { $0 == bg })
        // Ink and overlays made it in.
        XCTAssertTrue(frames[0].pixels.contains { $0 != bg })
        XCTAssertGreaterThan(Set(frames[2].pixels).count, 3)
    }

    func testSingleFrameExportIsAStill() throws {
        let f = CreationEncoder().quantize(Raster.filled(width: 536, height: 240, color: .accent))
        let file = try HCAFile(data: try CreationEncoder.encode([f], durationsMs: [83]))
        XCTAssertEqual(file.frames.map(\.durationMs), [0])
    }

    func testAPNGOriginalReadsBack() throws {
        let w = APNGWriter(frameCount: 3)
        for i in 0..<3 { w.add(inkImage(i), durationMs: 100) }
        let data = try XCTUnwrap(w.finish())
        let loaded = try ImageLoader.load(data: data)
        XCTAssertEqual(loaded.images.count, 3)
    }

    #if os(macOS)
    func testDrawingExportAcceptedByCDecoder() throws {
        guard let hcainfo = Paths.cTool("hcainfo") else { throw XCTSkip("build/core/tools/hcainfo not built") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("draw-\(UUID().uuidString).hca")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try exportedFile().0.write(to: tmp)
        let r = try runTool(hcainfo, [tmp.path])
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertTrue(r.output.contains("3 frames"), r.output)

        // And a marquee.
        var frames: [RGB565Frame] = [], durations: [Int] = []
        let enc = CreationEncoder()
        try MarqueeRenderer.render(MarqueeSpec(text: "PixelClip", motion: .scroll, led: true, speed: 500),
                                   font: CTFontCreateWithName("Helvetica-Bold" as CFString, 40, nil)) { _, f, d in
            frames.append(enc.quantize(f)); durations.append(d)
        }
        try CreationEncoder.encode(frames, durationsMs: durations).write(to: tmp)
        let m = try runTool(hcainfo, [tmp.path, "-q"])
        XCTAssertEqual(m.status, 0, m.output)
    }
    #endif
}
