import XCTest
@testable import PixelClipKit

/// Show-now carries a strip's scroll; the virtual clip scrolls a shown strip; the PixelClip pack and the
/// live-scene palettes the Library offers.
final class NowShowTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_791_655_200)

    func stripFrame(width: Int) -> RGB565Frame {
        frame(width, 240) { x, _ in UInt16(truncatingIfNeeded: x &* 37 &+ 1) | 1 }
    }

    // MARK: Show now

    func testVirtualClipScrollsAShownStrip() async throws {
        let clock = ClockBox(base)
        let clip = VirtualClipClient(options: .instant, clock: { clock.now })
        _ = try await clip.putAsset(id: "marquee", data: try HCAEncoder.encodeStrip(stripFrame(width: 1500)), progress: nil)
        let scroll = PlaylistItem.Scroll(pxPerS: 100, direction: .left, gapPx: 50)
        try await SyncEngine(client: clip).showNow(LocalAsset(id: "marquee", data: try HCAEncoder.encodeStrip(stripFrame(width: 1500))), scroll: scroll)
        try await clip.endSession()

        clock.now = base + 1
        let a = await clip.display()
        clock.now = base + 3
        let b = await clip.display()
        XCTAssertEqual(a.currentID, "marquee")
        XCTAssertEqual(a.content, .strip(id: "marquee", copies: [436]), "100 px in after 1 s, entering from the right")
        XCTAssertEqual(b.content, .strip(id: "marquee", copies: [236]))
        XCTAssertNotEqual(a.frame, b.frame, "the frame changes over time: it scrolls")
    }

    func testShownStripFallsBackToItsPlaylistScrollThenDefaults() async throws {
        let clock = ClockBox(base)
        let clip = VirtualClipClient(options: .instant, clock: { clock.now })
        let data = try HCAEncoder.encodeStrip(stripFrame(width: 1200))
        _ = try await clip.putAsset(id: "marquee", data: data, progress: nil)
        _ = try await clip.putAsset(id: "pic", data: try clipAsset(0x07E0), progress: nil)
        // No scroll in the body: the playlist item's (without its pass count: a show lasts 60 s).
        let itemScroll = PlaylistItem.Scroll(pxPerS: 200, direction: .left, gapPx: 0, loops: 1)
        try await clip.putPlaylist(Playlist(items: [.asset("pic", durationMs: 5000),
                                                    PlaylistItem(type: .asset, id: "marquee", durationMs: 0, scroll: itemScroll)]))
        try await clip.show(id: "marquee", durationMs: nil)
        try await clip.endSession()
        clock.now = base + 1
        var d = await clip.display()
        XCTAssertEqual(d.content, .strip(id: "marquee", copies: [336]), "200 px/s from the playlist item")
        clock.now = base + 30
        d = await clip.display()
        if case .strip = d.content {} else { XCTFail("still scrolling after one pass: \(d.content)") }

        // Neither: the firmware's defaults (80 px/s, left).
        try await clip.putPlaylist(Playlist(items: [.asset("pic", durationMs: 5000)]))
        try await clip.show(id: "marquee", durationMs: nil)
        try await clip.endSession()
        clock.now = base + 31
        d = await clip.display()
        XCTAssertEqual(d.content, .strip(id: "marquee", copies: [456]))
        // A still shows as a still.
        try await clip.show(id: "pic", durationMs: nil)
        d = await clip.display()
        XCTAssertEqual(d.content, .asset(id: "pic", frame: 0))
    }

    func testShowScrollMatchesThePlaylistItem() {
        let rot = PlaylistItem.Scroll(pxPerS: 140, direction: .right, gapPx: 90, loops: 3)
        let lib = PlaylistItem.Scroll(pxPerS: 80)
        let pl = Playlist(items: [PlaylistItem(type: .asset, id: "m", durationMs: 0, scroll: rot)])
        XCTAssertEqual(pl.showScroll(for: "m", fallback: lib), PlaylistItem.Scroll(pxPerS: 140, direction: .right, gapPx: 90))
        XCTAssertEqual(pl.showScroll(for: "other", fallback: lib), lib)
        XCTAssertNil(pl.showScroll(for: "other"))
        let q = Playlist(items: [], queue: [QueueEntry(id: "t", at: 1, type: .asset, asset: "m", scroll: rot)])
        XCTAssertEqual(q.showScroll(for: "m")?.pxPerS, 140)
    }

    func testHTTPShowBodyCarriesScroll() async throws {
        let client = HTTPClipClient(baseURL: URL(string: "http://clip.test")!, protocolClasses: [CaptureProtocol.self])
        CaptureProtocol.reset()
        try await client.show(id: "marquee", durationMs: nil, scroll: PlaylistItem.Scroll(pxPerS: 90, direction: .left, gapPx: 120))
        let req = try XCTUnwrap(CaptureProtocol.requests.last)
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/show/marquee")
        XCTAssertEqual(try jsonObject(req.body), try jsonObject(#"{"scroll":{"px_per_s":90,"direction":"left","gap_px":120}}"#))
        // Without scroll (a still): the body is as before.
        try await client.show(id: "pic", durationMs: 5000)
        XCTAssertEqual(try jsonObject(try XCTUnwrap(CaptureProtocol.requests.last).body), try jsonObject(#"{"duration_ms":5000}"#))
    }

    // MARK: PixelClip pack

    func testStarterPackManifestAndFiles() throws {
        let dir = Paths.iosDir.appendingPathComponent("Sources/Resources/Starter")
        let pieces = try StarterPack.pieces(manifest: Data(contentsOf: dir.appendingPathComponent("starter.json")))
        XCTAssertEqual(pieces.count, 20)
        XCTAssertEqual(Set(pieces.map(\.slug)).count, 20)
        var total = 0
        for p in pieces {
            XCTAssertTrue(HCA.isValidAssetID(p.assetID), p.assetID)
            XCTAssertFalse(p.title.isEmpty)
            XCTAssertFalse(p.description.isEmpty, p.slug)
            let data = try Data(contentsOf: dir.appendingPathComponent(p.file))
            XCTAssertEqual(data.count, p.bytes, p.slug)
            let info = try StarterPack.info(data)
            XCTAssertGreaterThanOrEqual(info.frameCount, 1)
            XCTAssertEqual(info.width, ClipCanvas.width, p.slug)
            XCTAssertFalse(info.isStrip)
            if info.frameCount > 1 { XCTAssertGreaterThan(info.durationMs, 0, p.slug) }
            XCTAssertFalse(ClipBudget.isOverLimit(bytes: data.count, frames: info.frameCount, isStrip: false), p.slug)
            total += data.count
        }
        XCTAssertLessThan(total, 8_000_000, "about 7.2 MB (Reaction Mitosis alone is 1.2 MB since it rewinds)")
        XCTAssertThrowsError(try StarterPack.info(Data("nope".utf8)))
    }

    // MARK: Live scenes

    func testScenePalettesFollowTheFirmware() {
        XCTAssertEqual(SceneLook.palettes(for: "fire"), ["classic", "blue", "emerald"])
        XCTAssertEqual(SceneLook.palettes(for: "sand"), ["amber", "ocean", "forest", "candy", "mono", "ember"])
        XCTAssertEqual(SceneLook.defaultPalette(for: "water"), "ocean")
        XCTAssertEqual(SceneLook.palette("amber", for: "fire"), "classic", "fire has its own ramps")
        XCTAssertEqual(SceneLook.params(scene: "balls", palette: nil), ["palette": .string("candy")])
        for scene in SceneCatalog.enabledIDs {
            for p in SceneLook.palettes(for: scene) {
                XCTAssertNotNil(SceneLook.ramps[p], p)
                let black = SceneLook.color(p, at: 0), top = SceneLook.color(p, at: 1)
                XCTAssertEqual(black.r + black.g + black.b, 0, accuracy: 0.001)
                XCTAssertGreaterThan(top.r + top.g + top.b, 1.5, p)
            }
        }
        let amberTop = SceneLook.color("amber", at: 220.0 / 255)
        XCTAssertEqual(amberTop.r, 1, accuracy: 0.01)
        XCTAssertEqual(amberTop.g, Double(0xBE) / 255, accuracy: 0.01)
    }
}

/// Captures requests to a fake clip and answers `{"ok":true}`.
final class CaptureProtocol: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable { var method: String; var path: String; var body: Data }
    nonisolated(unsafe) private static var store: [Captured] = []
    private static let lock = NSLock()
    static var requests: [Captured] { lock.withLock { store } }
    static func reset() { lock.withLock { store = [] } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "clip.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        let c = Captured(method: request.httpMethod ?? "", path: request.url?.path ?? "", body: body)
        Self.lock.withLock { Self.store.append(c) }
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
