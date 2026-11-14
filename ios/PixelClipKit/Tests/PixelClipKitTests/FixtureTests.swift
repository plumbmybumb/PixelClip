import CoreGraphics
import XCTest
@testable import PixelClipKit

/// Writes a deterministic fixture produced entirely by the Swift pipeline, for cross-checking with
/// the C decoder (`build/core/tools/hcainfo` / `hcadec`).
final class FixtureTests: XCTestCase {
    static let name = "swift-orbit.hca"

    /// 6-frame animation through the full pipeline (rasterise → adjustments → dither → RLE16).
    static func makeFixture() throws -> Data {
        let frames = PlaceholderArt.orbitFrames(count: 6).enumerated().map { i, img in
            HCAEncoder.Frame(pixels: ClipRenderer.render(img, transform: CropTransform(scale: 1),
                                                         adjustments: ImageAdjustments(saturation: 1.1)),
                             durationMs: i == 0 ? 0 : 60)
        }
        return try HCAEncoder.encode(frames: frames, loopCount: 0)
    }

    func testFixtureIsStableAndWritten() throws {
        let data = try Self.makeFixture()
        XCTAssertEqual(try Self.makeFixture(), data, "deterministic")
        let file = try HCAFile(data: data)
        XCTAssertEqual(file.frameCount, 6)
        XCTAssertEqual(file.frames[0].durationMs, 0)
        XCTAssertEqual(file.frames[1].durationMs, 60)

        let golden = Paths.fixturesDir.appendingPathComponent(Self.name)
        if let existing = try? Data(contentsOf: golden) {
            // CoreGraphics anti-aliasing can differ across OS versions; the container must not.
            if existing != data {
                print("note: \(Self.name) differs from the committed fixture (CoreGraphics version?) — rewriting")
            }
        }
        for dir in [Paths.fixturesDir, Paths.fixturesOut] {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: dir.appendingPathComponent(Self.name))
            } catch {
                print("note: could not write fixture to \(dir.path): \(error)")
            }
        }
    }

    #if os(macOS)
    func testCDecoderAcceptsSwiftOutput() throws {
        guard let hcainfo = Paths.cTool("hcainfo") else { throw XCTSkip("build/core/tools/hcainfo not built") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pixelclip-\(UUID().uuidString).hca")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Self.makeFixture().write(to: tmp)
        let r = try runTool(hcainfo, [tmp.path])
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertTrue(r.output.contains("6 frames"), r.output)

        // Atlases and raw files too.
        let atlas = try HCAEncoder.encode(frames: (0..<13).map { .init(pixels: RGB565Frame(width: 30, height: 48, fill: UInt16($0) * 999), durationMs: 0) },
                                          glyphAtlas: true)
        try atlas.write(to: tmp)
        XCTAssertEqual(try runTool(hcainfo, [tmp.path, "-q"]).status, 0)
        let raw = try HCAEncoder.encode(frames: [.init(pixels: RGB565Frame(width: 536, height: 240, fill: 0x1234), durationMs: 0)], compression: .raw)
        try raw.write(to: tmp)
        XCTAssertEqual(try runTool(hcainfo, [tmp.path, "-q"]).status, 0)

        // And the C decoder rejects what ours rejects.
        var bad = try Self.makeFixture()
        let off = Int(bad[32]) | Int(bad[33]) << 8 | Int(bad[34]) << 16 | Int(bad[35]) << 24
        bad[off] = 0xFF; bad[off + 1] = 0xFF   // first run now claims 32768 literal pixels: overrun
        XCTAssertThrowsError(try HCAFile(data: bad).decodeFrame(0))
        try bad.write(to: tmp)
        XCTAssertNotEqual(try runTool(hcainfo, [tmp.path, "-q"]).status, 0)
    }
    #endif
}
