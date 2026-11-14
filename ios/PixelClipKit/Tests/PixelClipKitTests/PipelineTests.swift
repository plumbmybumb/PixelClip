import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PixelClipKit

final class PipelineTests: XCTestCase {

    func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, w: Int = 536, h: Int = 240) -> RGBA8Image {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) { bytes[i * 4] = r; bytes[i * 4 + 1] = g; bytes[i * 4 + 2] = b }
        return RGBA8Image(width: w, height: h, bytes: bytes)
    }

    func gradient(w: Int = 536, h: Int = 240) -> RGBA8Image {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                bytes[o] = UInt8(x * 255 / (w - 1)); bytes[o + 1] = UInt8(y * 255 / (h - 1)); bytes[o + 2] = UInt8((x + y) % 256)
            }
        }
        return RGBA8Image(width: w, height: h, bytes: bytes)
    }

    func testBlackAndWhiteSurviveDithering() {
        for mode in [ClipRenderer.DitherMode.none, .flatAware, .all] {
            XCTAssertTrue(ClipRenderer.quantize(solid(0, 0, 0), mode: mode).pixels.allSatisfy { $0 == 0 }, "\(mode)")
            XCTAssertTrue(ClipRenderer.quantize(solid(255, 255, 255), mode: mode).pixels.allSatisfy { $0 == 0xFFFF }, "\(mode)")
        }
    }

    func testDitherIsDeterministicAndOrdered() {
        let g = gradient()
        let a = ClipRenderer.quantize(g, mode: .all)
        let b = ClipRenderer.quantize(g, mode: .all)
        XCTAssertEqual(a, b)
        // A mid grey that isn't representable dithers into a fixed 4×4 pattern.
        let grey = ClipRenderer.quantize(solid(100, 100, 100, w: 8, h: 8), mode: .all)
        for y in 0..<8 { for x in 0..<8 {
            XCTAssertEqual(grey.pixels[y * 8 + x], grey.pixels[(y % 4) * 8 + (x % 4)])
        } }
        XCTAssertGreaterThan(Set(grey.pixels).count, 1)
    }

    func testFlatAreasAreNotDithered() {
        let flat = ClipRenderer.quantize(solid(100, 100, 100), mode: .flatAware)
        XCTAssertEqual(Set(flat.pixels).count, 1)
        // …so they stay tiny after RLE (PROTOCOL §5 encoder note).
        XCTAssertEqual(HCAEncoder.rle16(flat.pixels).count, 16)
    }

    func testRoundingMatchesReferenceFormula() {
        // hcaenc: q = (v * maxv * 32 + 16 * 255) / (255 * 32)
        for v in 0...255 {
            let px = ClipRenderer.quantize(solid(UInt8(v), UInt8(v), UInt8(v), w: 1, h: 1), mode: .none).pixels[0]
            let r5 = (v * 31 * 32 + 16 * 255) / 8160, g6 = (v * 63 * 32 + 16 * 255) / 8160
            XCTAssertEqual(px, UInt16(r5 << 11 | g6 << 5 | r5))
        }
    }

    func testAmoledCurveCrushesNearBlackKeepsHighlights() {
        var dark = solid(8, 8, 8, w: 4, h: 4)
        ClipRenderer.apply(ImageAdjustments(amoledDark: true), to: &dark)
        XCTAssertTrue(dark.bytes.enumerated().allSatisfy { $0.offset % 4 == 3 || $0.element == 0 })
        var bright = solid(200, 120, 40, w: 4, h: 4)
        ClipRenderer.apply(ImageAdjustments(amoledDark: true), to: &bright)
        XCTAssertEqual(Array(bright.bytes[0..<3]), [200, 120, 40])
    }

    func testNeutralAdjustmentsAreIdentityAndSaturationZeroIsGrey() {
        var img = gradient(w: 32, h: 16)
        let before = img.bytes
        ClipRenderer.apply(.neutral, to: &img)
        XCTAssertEqual(img.bytes, before)

        var grey = solid(220, 40, 90, w: 2, h: 2)
        ClipRenderer.apply(ImageAdjustments(saturation: 0, amoledDark: false, dither: false), to: &grey)
        XCTAssertEqual(grey.bytes[0], grey.bytes[1])
        XCTAssertEqual(grey.bytes[1], grey.bytes[2])

        var lifted = solid(100, 100, 100, w: 1, h: 1)
        ClipRenderer.apply(ImageAdjustments(brightness: 0.5, amoledDark: false), to: &lifted)
        XCTAssertGreaterThan(lifted.bytes[0], 100)
    }

    func testRasterizeFillAndRotation() throws {
        // A 100×50 image, left half red / right half blue.
        let ctx = CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 400,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 50, y: 0, width: 50, height: 50))
        let img = ctx.makeImage()!
        let fill = ClipRenderer.rasterize(img, transform: .fill(CGSize(width: 100, height: 50)))
        func px(_ r: RGBA8Image, _ x: Int, _ y: Int) -> [UInt8] { Array(r.bytes[(y * r.width + x) * 4..<(y * r.width + x) * 4 + 3]) }
        XCTAssertEqual(px(fill, 10, 120), [255, 0, 0])
        XCTAssertEqual(px(fill, 525, 120), [0, 0, 255])
        // Rotated 180°: sides swap.
        var t = CropTransform.fill(CGSize(width: 100, height: 50)); t.rotation = .pi
        let rot = ClipRenderer.rasterize(img, transform: t)
        XCTAssertEqual(px(rot, 10, 120), [0, 0, 255])
        // Offset moves content right (y-down screen space).
        var o = CropTransform.fit(CGSize(width: 100, height: 50)); o.offsetX = 100
        let moved = ClipRenderer.rasterize(img, transform: o)
        XCTAssertEqual(px(moved, 20, 120), [0, 0, 0])
    }

    func testPreviewImageExpandsBits() throws {
        let f = RGB565Frame(width: 2, height: 1, pixels: [0xFFFF, 0xF800])
        let cg = try XCTUnwrap(ClipRenderer.makeCGImage(f))
        XCTAssertEqual(cg.width, 2)
    }

    #if os(macOS)
    /// Bit-for-bit parity with the C reference encoder: same pixels → identical .hca bytes.
    func testMatchesReferenceEncoderBitForBit() throws {
        guard let hcaenc = Paths.cTool("hcaenc") else { throw XCTSkip("build/core/tools/hcaenc not built") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelclip-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Mix of flat UI-like areas and gradients so both dither branches run.
        var img = gradient()
        for y in 60..<180 { for x in 100..<300 { let o = (y * 536 + x) * 4; img.bytes[o] = 90; img.bytes[o + 1] = 37; img.bytes[o + 2] = 201 } }
        let png = dir.appendingPathComponent("in.png")
        try writePNG(img, to: png)

        for (flag, mode) in [("", ClipRenderer.DitherMode.flatAware), ("--no-dither", .none), ("--dither-all", .all)] {
            let out = dir.appendingPathComponent("c\(flag).hca")
            let args = [out.path, "--durations", "120", "-q"] + (flag.isEmpty ? [] : [flag]) + [png.path]
            let r = try runTool(hcaenc, args)
            XCTAssertEqual(r.status, 0, r.output)
            let cBytes = try Data(contentsOf: out)
            let swift = try HCAEncoder.encode(frames: [.init(pixels: ClipRenderer.quantize(img, mode: mode), durationMs: 120)])
            XCTAssertEqual(swift, cBytes, "mode \(mode)")
        }
    }

    func writePNG(_ img: RGBA8Image, to url: URL) throws {
        let provider = CGDataProvider(data: Data(img.bytes) as CFData)!
        let cg = CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.width * 4,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
    #endif
}
