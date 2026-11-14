import CoreGraphics
import CoreText
import XCTest
@testable import PixelClipKit

final class TextTests: XCTestCase {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 40, nil)

    // MARK: Loop maths

    /// Copy positions for a raw (unwrapped) offset, to check the loop closes.
    private func positions(offset: Int, plan: ScrollPlan, content: Int, strip: Int, pad: Int, leftward: Bool, W: Int = 536) -> [Int] {
        let x0 = (leftward ? W - offset : offset - content) - pad
        let reach = (W + strip + abs(x0)) / plan.period + 2
        return (-reach...reach).map { x0 + $0 * plan.period }.filter { $0 < W && $0 + strip > 0 }.sorted()
    }

    func testScrollPlanClosesTheLoop() {
        for content in [1, 37, 300, 536, 1234, 5000] {
            for gap in [0, 100, 536] {
                for speed in [30.0, 150, 333] {
                    for pitch in [1, 4, 6, 8] {
                        let p = LoopMath.scrollPlan(contentWidth: content, gap: gap, speed: speed, fps: 30, pitch: pitch, maxFrames: 400)
                        XCTAssertEqual(p.period, p.frames * p.step)
                        XCTAssertGreaterThanOrEqual(p.period, content + gap)
                        XCTAssertLessThan(p.period - (content + gap), p.step, "period overshoots by a whole step")
                        XCTAssertEqual(p.step % pitch, 0, "LED steps must move whole cells")
                        XCTAssertLessThanOrEqual(p.frames, 400)
                        XCTAssertGreaterThan(p.frames, 0)
                        for leftward in [true, false] {
                            let strip = content + 20
                            XCTAssertEqual(positions(offset: 0, plan: p, content: content, strip: strip, pad: 10, leftward: leftward),
                                           positions(offset: p.period, plan: p, content: content, strip: strip, pad: 10, leftward: leftward),
                                           "frame N must equal frame 0")
                            XCTAssertEqual(LoopMath.copies(frame: 3, plan: p, canvasWidth: 536, contentWidth: content, stripWidth: strip, pad: 10, leftward: leftward),
                                           positions(offset: (3 % p.frames) * p.step, plan: p, content: content, strip: strip, pad: 10, leftward: leftward))
                        }
                    }
                }
            }
        }
    }

    func testScrollPlanCapKeepsSpeed() {
        let p = LoopMath.scrollPlan(contentWidth: 4000, gap: 200, speed: 150, fps: 30, maxFrames: 400)
        XCTAssertTrue(p.capped)
        XCTAssertLessThanOrEqual(p.frames, 400)
        XCTAssertEqual(p.speed, 150, accuracy: 3, "fewer, longer frames keep the speed")
        // Past 10 fps the speed gives instead.
        let huge = LoopMath.scrollPlan(contentWidth: 9000, gap: 200, speed: 150, fps: 30, maxFrames: 400)
        XCTAssertEqual(huge.frameMs, 100)
        XCTAssertLessThanOrEqual(huge.frames, 400)
        XCTAssertGreaterThan(huge.speed, 150)
        let easy = LoopMath.scrollPlan(contentWidth: 300, gap: 200, speed: 150, fps: 30)   // explicit fps
        XCTAssertFalse(easy.capped)
        XCTAssertEqual(easy.frameMs, 33)
        XCTAssertEqual(easy.step, 5)
        XCTAssertEqual(easy.frames, 100)
    }

    func testBounceHopIsPeriodic() {
        for i in 0..<10 {
            XCTAssertEqual(LoopMath.hop(frame: i, period: 35, index: 4), LoopMath.hop(frame: i + 35, period: 35, index: 4), accuracy: 1e-12)
        }
        XCTAssertEqual(LoopMath.hop(frame: 0, period: 35, index: 0), 0, accuracy: 1e-12)
    }

    // MARK: Layout

    func testTrackingAndEmojiLayout() {
        let a = TextLayoutEngine.layout("HELLO", font: font, size: 100, tracking: 0)
        let b = TextLayoutEngine.layout("HELLO", font: font, size: 100, tracking: 0.2)
        XCTAssertEqual(b.lines[0].width - a.lines[0].width, 5 * 20, accuracy: 0.5)
        let e = TextLayoutEngine.layout("hi 🥰", font: font, size: 60)
        XCTAssertTrue(e.lines[0].glyphs.contains { $0.isColor }, "emoji fall back to the colour emoji font")
        XCTAssertFalse(e.lines[0].glyphs.first!.isColor)
        let two = TextLayoutEngine.layout("one\ntwo", font: font, size: 50)
        XCTAssertEqual(two.lines.count, 2)
        XCTAssertEqual(two.lines[1].range, 4..<7)
    }

    func testFitSizeFillsTheBox() {
        let ref = TextLayoutEngine.layout("PixelClip", font: font, size: 100)
        let size = TextPainter.fitSize(ref, width: nil, height: 200)
        let fitted = TextLayoutEngine.layout("PixelClip", font: font, size: size)
        XCTAssertEqual(fitted.blockInk.height, 200, accuracy: 3)
        let narrow = TextPainter.fitSize(ref, width: 100, height: 200)
        XCTAssertEqual(TextLayoutEngine.layout("PixelClip", font: font, size: narrow).maxInkWidth, 100, accuracy: 3)
    }

    // MARK: Fonts

    func testFontAvailabilityFilter() {
        let installed: Set<String> = ["Didot", "zapfino", "Helvetica"]
        let avail = FontCatalog.available(installed: installed)
        let ids = Set(avail.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: [FontCatalog.sfPro, FontCatalog.sfRounded, FontCatalog.sfMono, FontCatalog.newYork]))
        XCTAssertTrue(ids.contains("didot"))
        XCTAssertTrue(ids.contains("zapfino"), "matching is case-insensitive")
        XCTAssertFalse(ids.contains("futura"))
        XCTAssertEqual(avail.count, 6)
        // Order is preserved.
        XCTAssertEqual(avail.map(\.id), FontCatalog.curated.map(\.id).filter(ids.contains))
        // Every curated id is unique.
        XCTAssertEqual(Set(FontCatalog.curated.map(\.id)).count, FontCatalog.curated.count)
    }

    func testNearestFace() {
        let faces = [FontFace(postScriptName: "X-Regular", styleName: "Regular", weight: 0, italic: false),
                     FontFace(postScriptName: "X-Bold", styleName: "Bold", weight: 0.4, italic: false),
                     FontFace(postScriptName: "X-Italic", styleName: "Italic", weight: 0, italic: true)]
        XCTAssertEqual(FontCatalog.nearestFace(faces, weight: 0.3, italic: false)?.postScriptName, "X-Bold")
        XCTAssertEqual(FontCatalog.nearestFace(faces, weight: 0.4, italic: true)?.postScriptName, "X-Italic")
        XCTAssertEqual(FontCatalog.nearestFace(faces.filter { !$0.italic }, weight: 0, italic: true)?.postScriptName, "X-Regular",
                       "no italic face: fall back to upright")
        XCTAssertEqual(FontCatalog.weightSteps(faces).map(\.name), ["Regular", "Bold"])
    }

    func testRealFamilyFacesResolve() {
        // Helvetica ships on both macOS and iOS.
        let faces = FontCatalog.faces(ofFamily: "Helvetica")
        XCTAssertFalse(faces.isEmpty)
        XCTAssertTrue(faces.contains { $0.weight > 0.2 })
        XCTAssertTrue(FontCatalog.installedFamilies().contains("Helvetica"))
    }

    // MARK: Dot matrix

    func testDotMatrixGeometryAndMask() {
        let g = DotMatrix.grid(width: 536, height: 240, pitch: 6)
        XCTAssertEqual(g.cols, 89); XCTAssertEqual(g.rows, 40); XCTAssertEqual(g.originX, 1); XCTAssertEqual(g.originY, 0)
        let m = DotMatrix.dotMask(pitch: 8, ratio: 0.8)
        XCTAssertEqual(m[3 * 8 + 3], 255); XCTAssertEqual(m[4 * 8 + 4], 255)
        XCTAssertEqual(m[0], 0); XCTAssertEqual(m[63], 0)
        for y in 0..<8 { for x in 0..<8 {
            XCTAssertEqual(m[y * 8 + x], m[y * 8 + (7 - x)]); XCTAssertEqual(m[y * 8 + x], m[x * 8 + y])
        } }
    }

    func testDotMatrixSamplerIsDeterministic() {
        // A synthetic scene: a red bar, a soft grey gradient, black elsewhere.
        var img = Raster.filled(width: 536, height: 240, color: .black)
        for y in 60..<120 { for x in 40..<300 { let o = (y * 536 + x) * 4; img.bytes[o] = 220; img.bytes[o + 1] = 30; img.bytes[o + 2] = 10 } }
        for y in 150..<230 { for x in 0..<536 { let o = (y * 536 + x) * 4; let v = UInt8(x * 255 / 535); img.bytes[o] = v; img.bytes[o + 1] = v; img.bytes[o + 2] = v } }
        let off = RGBAColor(0.1, 0.1, 0.1)
        let a = DotMatrix.render(img, pitch: 8, off: off)
        let b = DotMatrix.render(img, pitch: 8, off: off)
        XCTAssertEqual(a.bytes, b.bytes)
        // A cell inside the bar is lit, pushed to full brightness; its corner is dark.
        let cell = (x: 8 * 10 + 4, y: 8 * 10 + 4)            // cell (10,10) covers 80…87 × 80…87
        let o = (cell.y * 536 + cell.x) * 4
        XCTAssertEqual(a.bytes[o], 255)
        XCTAssertEqual(Int(a.bytes[o + 1]), 30 * 255 / 220)
        XCTAssertEqual(a.bytes[((80 * 536) + 80) * 4], 0, "between dots is true black")
        // An empty cell shows the off colour at its centre.
        let off0 = (4 * 536 + 4) * 4
        XCTAssertEqual(a.bytes[off0], off.premultipliedBytes.0)
        // Dark end of the gradient stays off, bright end lights.
        XCTAssertEqual(a.bytes[((196 * 536) + 4) * 4], a.bytes[off0])
        XCTAssertEqual(a.bytes[((196 * 536) + 532) * 4], 255)
        // Opaque everywhere.
        XCTAssertTrue(stride(from: 3, to: a.bytes.count, by: 4).allSatisfy { a.bytes[$0] == 255 })
        // Hard-edged dots: only full colour or black inside the bar, so each dot row is one RLE run.
        XCTAssertTrue(DotMatrix.dotMask(pitch: 6).allSatisfy { $0 == 0 || $0 == 255 })
        // Without unlit dots, empty areas are true black (and compress to nothing).
        XCTAssertEqual(DotMatrix.render(img, pitch: 8).bytes[off0], 0)
    }

    // MARK: Marquee rendering

    private func render(_ spec: MarqueeSpec) throws -> (frames: [RGBA8Image], durations: [Int], summary: MarqueeSummary) {
        var frames: [RGBA8Image] = [], durations: [Int] = []
        let s = try MarqueeRenderer.render(spec, font: font) { _, f, d in frames.append(f); durations.append(d) }
        return (frames, durations, s)
    }

    func testScrollFramesShiftByOneStepAndWrap() throws {
        let spec = MarqueeSpec(text: "Bonjour ✦ PixelClip", fill: .solid(.accent), speed: 240, spacing: 0.3, fps: 30)
        let r = try render(spec)
        let sum = MarqueeRenderer.summary(spec, font: font)
        XCTAssertEqual(r.frames.count, sum.frames)
        XCTAssertEqual(r.summary, sum)
        let plan = LoopMath.scrollPlan(contentWidth: 1, gap: 0, speed: 240, fps: 30)   // step for 240 px/s @ 30 fps
        let step = plan.step
        func shiftedEqual(_ a: RGBA8Image, _ b: RGBA8Image) -> Bool {
            // b == a moved left by `step`.
            for y in 0..<240 { for x in 0..<(536 - step) {
                let i = (y * 536 + x) * 4, j = (y * 536 + x + step) * 4
                if a.bytes[j] != b.bytes[i] || a.bytes[j + 1] != b.bytes[i + 1] || a.bytes[j + 2] != b.bytes[i + 2] { return false }
            } }
            return true
        }
        XCTAssertTrue(shiftedEqual(r.frames[0], r.frames[1]))
        XCTAssertTrue(shiftedEqual(r.frames[r.frames.count - 1], r.frames[0]), "the last frame flows into the first")
        XCTAssertTrue(r.durations.allSatisfy { $0 == 33 })
    }

    func testEveryMotionMatchesItsSummaryAndEncodes() throws {
        for motion in MarqueeSpec.Motion.allCases {
            for led in [false, true] {
                var spec = MarqueeSpec(text: "Ce soir 🎉", headline: "LIVE", motion: motion, led: led, speed: 300)
                spec.glowRadius = led ? 0 : 6
                spec.outlineWidth = 2
                spec.fill = .gradient(.accent, RGBAColor(hex: 0xFF3B6B), vertical: true)
                let r = try render(spec)
                XCTAssertEqual(r.frames.count, MarqueeRenderer.summary(spec, font: font).frames, "\(motion) led=\(led)")
                XCTAssertLessThanOrEqual(r.frames.count, MarqueeRenderer.maxFrames)
                let enc = CreationEncoder()
                let data = try CreationEncoder.encode(r.frames.map(enc.quantize), durationsMs: r.durations)
                let file = try HCAFile(data: data)
                XCTAssertEqual(file.frameCount, r.frames.count)
                // Something was drawn.
                XCTAssertTrue(r.frames.contains { f in stride(from: 0, to: f.bytes.count, by: 4).contains { f.bytes[$0] > 200 } }, "\(motion)")
            }
        }
        let typed = try render(MarqueeSpec(text: "abc de", motion: .typewriter))
        XCTAssertEqual(typed.frames.count, 6 + 8, "one frame per character plus blank, blinks and clear")
        XCTAssertEqual(try render(MarqueeSpec(motion: .still)).durations, [0])
    }

    func testFastQuantizeMatchesThePipeline() {
        var rng = SeededRNG(42)
        var img = RGBA8Image(width: 536, height: 240, bytes: (0..<(536 * 240 * 4)).map { _ in UInt8.random(in: 0...255, using: &rng) })
        for i in stride(from: 3, to: img.bytes.count, by: 4) { img.bytes[i] = 255 }
        let enc = CreationEncoder()
        XCTAssertTrue(enc.isPlainQuantize)
        let (fast, preview) = enc.process(img)
        let slow = ClipRenderer.quantize(img, mode: .none)
        XCTAssertEqual(fast, slow, "vImage rounding is bit-identical to the pipeline's")
        let a = preview!.dataProvider!.data! as Data, b = ClipRenderer.makeCGImage(slow)!.dataProvider!.data! as Data
        XCTAssertEqual(a, b, "preview bytes match ClipRenderer.makeCGImage")
        // The dithered path still goes through ClipRenderer.
        let dithered = CreationEncoder(dither: true)
        XCTAssertFalse(dithered.isPlainQuantize)
        XCTAssertEqual(dithered.quantize(img), ClipRenderer.quantize(img, dither: true))
    }

    func testRenderIsDeterministic() throws {
        let spec = MarqueeSpec(text: "LED ✦", motion: .scroll, led: true, ledPitch: 6, speed: 400)
        let a = try render(spec), b = try render(spec)
        XCTAssertEqual(a.frames.count, b.frames.count)
        for (x, y) in zip(a.frames, b.frames) { XCTAssertEqual(x.bytes, y.bytes) }
    }

    func testCardsRender() throws {
        let fonts = CardFonts(title: font, body: font)
        for t in CardSpec.Template.allCases {
            var frames: [RGBA8Image] = []
            let s = try CardRenderer.render(.preset(t), fonts: fonts) { _, f, _ in frames.append(f) }
            XCTAssertEqual(frames.count, s.frames, "\(t)")
            XCTAssertGreaterThan(frames.count, 0)
        }
    }

    /// Times a ~200-frame marquee end to end (render → pipeline → RLE). Prints MARQUEE_TIMING.
    func testMarqueePerformance200Frames() throws {
        var spec = MarqueeSpec(text: "Bonne soirée ✨ on se voit à minuit", font: .systemBold, glowRadius: 6, speed: 150, spacing: 0.4, fps: 30)
        // Tune the speed so the loop lands near 200 frames.
        while MarqueeRenderer.summary(spec, font: font).frames > 205 { spec.speed += 5 }
        var scratch = RLE16Scratch()
        var payload = 0
        let enc = CreationEncoder()
        var frames: [RGBA8Image] = []
        let start = Date()
        let s = try MarqueeRenderer.render(spec, font: font) { _, f, _ in frames.append(f) }
        let renderMs = Date().timeIntervalSince(start) * 1000
        var previews: [CGImage] = []
        for f in frames {
            let out = enc.process(f)
            payload += CreationEncoder.rleSize(out.frame, scratch: &scratch)
            if let p = out.preview { previews.append(p) }
        }
        let ms = Date().timeIntervalSince(start) * 1000
        #if os(iOS)
        let platform = "iOS simulator"
        #else
        let platform = "macOS"
        #endif
        print(String(format: "MARQUEE_TIMING %@: %d frames, render %.0f ms, total with pipeline+RLE+previews %.0f ms (%.1f ms/frame), %@ encoded", platform, s.frames, renderMs, ms, ms / Double(s.frames),
                     ByteCountFormatter.string(fromByteCount: Int64(CreationEncoder.fileSize(frames: s.frames, payloadBytes: payload)), countStyle: .file)))
        XCTAssertGreaterThan(s.frames, 150)
        XCTAssertEqual(previews.count, s.frames)
    }
}


final class GradientRLETests: XCTestCase {
    /// Gradients are drawn as flat bands: every row of a vertical gradient is a single colour, so the
    /// greeting card's sky costs a few bytes per row instead of literals.
    func testVerticalGradientRowsAreFlat() {
        let img = Raster.draw(width: 536, height: 240) { ctx in
            Raster.fillGradient(ctx, in: CGRect(x: 0, y: 0, width: 536, height: 240), from: RGBAColor(hex: 0x2B0F4C), to: .black, vertical: true)
        }
        let f = CreationEncoder().quantize(img)
        for y in 0..<240 { XCTAssertEqual(Set(f.pixels[(y * 536)..<((y + 1) * 536)]).count, 1, "row \(y)") }
        XCTAssertLessThan(HCAEncoder.rle16(f.pixels).count, 240 * 8)
    }
}
