import XCTest
@testable import PixelClipKit

final class HCATests: XCTestCase {

    // MARK: Header layout

    func testHeaderAndTableBytesMatchHandWrittenLayout() throws {
        let a = RGB565Frame(width: 3, height: 2, fill: 0xF800)
        let b = RGB565Frame(width: 3, height: 2, pixels: [1, 2, 3, 4, 5, 6])
        let data = try HCAEncoder.encode(frames: [.init(pixels: a, durationMs: 100), .init(pixels: b, durationMs: 0)],
                                         loopCount: 5)
        let expected: [UInt8] = [
            // header
            0x48, 0x43, 0x41, 0x31,             // "HCA1"
            0x03, 0x00,                         // width 3
            0x02, 0x00,                         // height 2
            0x02, 0x00,                         // frame_count 2
            0x00,                               // pixel_format RGB565BE
            0x01,                               // compression RLE16
            0x05, 0x00,                         // loop_count 5
            0x00, 0x00,                         // flags
            0x20, 0x00, 0x00, 0x00,             // frame_table_off 32
            0x4A, 0x00, 0x00, 0x00,             // data_size 74
            0, 0, 0, 0, 0, 0, 0, 0,             // reserved
            // frame table
            0x38, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, // @56, 4 B, 100 ms
            0x3C, 0x00, 0x00, 0x00, 0x0E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // @60, 14 B, 0 ms
            // frame 0: repeat 6 × 0xF800
            0x05, 0x80, 0xF8, 0x00,
            // frame 1: literal 6
            0x05, 0x00, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00, 0x05, 0x00, 0x06,
        ]
        XCTAssertEqual(Array(data), expected)

        let file = try HCAFile(data: data)
        XCTAssertEqual(file.header, HCAHeader(width: 3, height: 2, frameCount: 2, compression: 1, loopCount: 5,
                                              flags: 0, frameTableOffset: 32, dataSize: 74))
        XCTAssertEqual(file.frames[0], HCAFrameInfo(offset: 56, length: 4, durationMs: 100))
        XCTAssertEqual(file.frames[1].effectiveDurationMs(), 100)
        XCTAssertEqual(try file.decodeFrame(0), a)
        XCTAssertEqual(try file.decodeFrame(1), b)
    }

    func testGlyphAtlasFlag() throws {
        let glyphs = (0..<13).map { i in HCAEncoder.Frame(pixels: RGB565Frame(width: 20, height: 32, fill: UInt16(i)), durationMs: 0) }
        let data = try HCAEncoder.encode(frames: glyphs, glyphAtlas: true)
        XCTAssertEqual(data[14], 0x01)
        XCTAssertEqual(data[15], 0x00)
        let file = try HCAFile(data: data)
        XCTAssertTrue(file.isGlyphAtlas)
        XCTAssertEqual(file.frameCount, 13)
        XCTAssertEqual(file.width, 20)

        let plain = try HCAFile(data: HCAEncoder.encode(frames: [glyphs[0]]))
        XCTAssertFalse(plain.isGlyphAtlas)
    }

    func testRawCompressionRoundTrip() throws {
        var rng = SeededRNG(7)
        let f = frame(536, 240) { _, _ in UInt16.random(in: 0...UInt16.max, using: &rng) }
        let data = try HCAEncoder.encode(frames: [.init(pixels: f, durationMs: 0)], compression: .raw)
        XCTAssertEqual(data.count, 32 + 12 + 536 * 240 * 2)
        XCTAssertEqual(try HCAFile(data: data).decodeFrame(0), f)
    }

    // MARK: Round trips

    func testRoundTripBlackFrame() throws {
        let f = RGB565Frame(width: 536, height: 240)
        let data = try HCAEncoder.encode(frames: [.init(pixels: f, durationMs: 0)])
        // 128,640 px = 3 full repeat runs + 1 partial → 4 runs × 4 bytes.
        XCTAssertEqual(data.count, 32 + 12 + 16)
        XCTAssertEqual(try HCAFile(data: data).decodeFrame(0), f)
    }

    func testRoundTripNoiseNeverMuchWorseThanRaw() throws {
        var rng = SeededRNG(42)
        let f = frame(536, 240) { _, _ in UInt16.random(in: 0...UInt16.max, using: &rng) }
        let rle = HCAEncoder.rle16(f.pixels)
        // Literal chunking costs 2 bytes per 32768 pixels (0.006%).
        XCTAssertLessThanOrEqual(rle.count, f.pixels.count * 2 + 2 * ((f.pixels.count + 32767) / 32768))
        let data = try HCAEncoder.encode(frames: [.init(pixels: f, durationMs: 0)])
        XCTAssertEqual(try HCAFile(data: data).decodeFrame(0), f)
    }

    func testRoundTripRandomAnimations() throws {
        var rng = SeededRNG(1234)
        for _ in 0..<20 {
            let w = Int.random(in: 1...64, using: &rng), h = Int.random(in: 1...64, using: &rng)
            let n = Int.random(in: 1...6, using: &rng)
            // A small palette produces a realistic mix of short and long runs.
            let palette = (0..<Int.random(in: 1...5, using: &rng)).map { _ in UInt16.random(in: 0...UInt16.max, using: &rng) }
            let frames = (0..<n).map { _ in
                HCAEncoder.Frame(pixels: frame(w, h) { _, _ in palette.randomElement(using: &rng)! },
                                 durationMs: Int.random(in: 0...500, using: &rng))
            }
            let data = try HCAEncoder.encode(frames: frames)
            let file = try HCAFile(data: data)
            XCTAssertEqual(file.frameCount, n)
            for (i, f) in frames.enumerated() {
                XCTAssertEqual(try file.decodeFrame(i), f.pixels)
                XCTAssertEqual(Int(file.frames[i].durationMs), f.durationMs)
            }
        }
    }

    func testRunBoundaries() throws {
        let a: UInt16 = 0x1111, b: UInt16 = 0x2222
        func check(_ px: [UInt16], expectedBytes: Int? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
            let rle = HCAEncoder.rle16(px)
            if let expectedBytes { XCTAssertEqual(rle.count, expectedBytes, file: file, line: line) }
            XCTAssertEqual(try HCADecoder.decodeRLE16(rle, pixelCount: px.count), px, file: file, line: line)
        }
        try check([a], expectedBytes: 4)                         // literal 1
        try check([a, a], expectedBytes: 6)                      // run of 2 stays literal
        try check([a, a, a], expectedBytes: 4)                   // run of 3 → repeat
        try check([a, a, b], expectedBytes: 8)                   // literal 3
        try check([b, a, a, a, b], expectedBytes: 4 + 4 + 4)     // lit1, rep3, lit1
        try check(.init(repeating: a, count: 32_768), expectedBytes: 4)
        try check(.init(repeating: a, count: 32_769), expectedBytes: 8)       // rep 32768 + lit 1
        try check(.init(repeating: a, count: 32_770), expectedBytes: 4 + 6)   // rep 32768 + lit 2
        try check(.init(repeating: a, count: 32_771), expectedBytes: 8)       // rep 32768 + rep 3
        try check(.init(repeating: a, count: 65_536 + 5), expectedBytes: 12)
        // A literal longer than 32768 is split into two literal runs.
        let alternating = (0..<40_000).map { UInt16($0 & 1) }
        try check(alternating, expectedBytes: 2 + 32_768 * 2 + 2 + (40_000 - 32_768) * 2)
        // Runs crossing row boundaries in a 536-wide frame.
        var rows = [UInt16](repeating: a, count: 536 * 3)
        rows[535] = b; rows[536] = b; rows[537] = b
        try check(rows)

        // The exact control words for a repeat of 32768.
        let rle = HCAEncoder.rle16(.init(repeating: 0xABCD, count: 32_768))
        XCTAssertEqual(Array(rle), [0xFF, 0xFF, 0xAB, 0xCD])
    }

    // MARK: Rejection (mirrors core/ exactness rules)

    func testDecoderRejectsMalformedStreams() throws {
        let px: [UInt16] = [1, 2, 3, 4, 5, 6]
        let good = HCAEncoder.rle16(px)
        XCTAssertNoThrow(try HCADecoder.decodeRLE16(good, pixelCount: 6))
        // Overrun: repeat of 7 into a 6-pixel frame.
        XCTAssertThrowsError(try HCADecoder.decodeRLE16(Data([0x06, 0x80, 0, 1]), pixelCount: 6)) {
            XCTAssertEqual($0 as? HCAError, .corrupt)
        }
        // Underrun: stream ends early.
        XCTAssertThrowsError(try HCADecoder.decodeRLE16(good.prefix(good.count - 2), pixelCount: 6))
        // Trailing bytes after the last pixel.
        XCTAssertThrowsError(try HCADecoder.decodeRLE16(good + Data([0, 0]), pixelCount: 6))
        // Underrun: too few runs.
        XCTAssertThrowsError(try HCADecoder.decodeRLE16(Data([0x02, 0x80, 0, 1]), pixelCount: 6))
    }

    func testFileValidation() throws {
        let data = try HCAEncoder.encode(frames: [.init(pixels: RGB565Frame(width: 4, height: 4, fill: 7), durationMs: 0)])
        var bad = data; bad[0] = 0x58
        XCTAssertThrowsError(try HCAFile(data: bad)) { XCTAssertEqual($0 as? HCAError, .badMagic) }
        XCTAssertThrowsError(try HCAFile(data: data.prefix(20))) { XCTAssertEqual($0 as? HCAError, .truncated) }
        XCTAssertThrowsError(try HCAFile(data: data + Data([0]))) // data_size != size
        var comp = data; comp[11] = 9
        XCTAssertThrowsError(try HCAFile(data: comp)) { XCTAssertEqual($0 as? HCAError, .unsupported) }
        var zero = data; zero[8] = 0
        XCTAssertThrowsError(try HCAFile(data: zero))
        // A slice that doesn't start at index 0 still parses.
        let padded = Data([9, 9, 9]) + data
        XCTAssertNoThrow(try HCAFile(data: padded[3...]))
    }

    func testAssetIDGrammar() {
        for ok in ["a", "0", "sunset-7f3a", "reader-font-1a2b3c4d-n", String(repeating: "a", count: 32)] {
            XCTAssertTrue(HCA.isValidAssetID(ok), ok)
        }
        for bad in ["", "-a", "A", "a_b", "é", String(repeating: "a", count: 33), "a b"] {
            XCTAssertFalse(HCA.isValidAssetID(bad), bad)
        }
    }

    // MARK: Reference fixtures from core/ (tools/fixtures)

    func testOpensAllReferenceFixtures() throws {
        let dir = Paths.referenceFixtures
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            throw XCTSkip("tools/fixtures not readable from this test host")
        }
        let hcas = names.filter { $0.hasSuffix(".hca") }.sorted()
        XCTAssertGreaterThanOrEqual(hcas.count, 5)
        for name in hcas {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            let file = try HCAFile(data: data)
            let frames = try file.decodeAllFrames()
            XCTAssertEqual(frames.count, file.frameCount, name)
            // Re-encoding the decoded frames reproduces the original byte-for-byte (same RLE rule).
            let re = try HCAEncoder.encode(frames: zip(frames, file.frames).map { .init(pixels: $0, durationMs: Int($1.durationMs)) },
                                           loopCount: Int(file.header.loopCount), glyphAtlas: file.isGlyphAtlas,
                                           compression: HCA.Compression(rawValue: file.header.compression)!)
            XCTAssertEqual(re, data, "\(name) re-encodes identically")
        }
    }

    // MARK: Performance

    func testEncodeTimingForOneFullFrame() throws {
        // A realistic dithered photo frame (worst-ish case for RLE).
        let img = PlaceholderArt.sunsetPhoto()
        let f = ClipRenderer.render(img, transform: .fill(CGSize(width: img.width, height: img.height)), adjustments: .default)
        var scratch = RLE16Scratch()
        _ = scratch.encode(f.pixels)
        let n = 50
        let start = DispatchTime.now().uptimeNanoseconds
        var bytes = 0
        for _ in 0..<n { bytes = scratch.encode(f.pixels).count }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(n)
        print("HCA_TIMING encode 536x240 frame: \(String(format: "%.3f", ms)) ms, \(bytes) bytes")
        #if !DEBUG
        XCTAssertLessThan(ms, 5)
        #endif
    }
}
