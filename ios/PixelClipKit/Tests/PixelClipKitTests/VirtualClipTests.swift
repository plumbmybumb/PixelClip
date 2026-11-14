import XCTest
@testable import PixelClipKit

func clipAsset(_ color: UInt16, frames: Int = 1) throws -> Data {
    try HCAEncoder.encode(frames: (0..<frames).map { i in
        .init(pixels: RGB565Frame(width: 536, height: 240, fill: color &+ UInt16(i)), durationMs: 80)
    })
}

func atlasAsset(_ seed: UInt16) throws -> Data {
    try HCAEncoder.encode(frames: (0..<13).map { .init(pixels: RGB565Frame(width: 30, height: 48, fill: seed &+ UInt16($0)), durationMs: 0) },
                          glyphAtlas: true)
}

func expectHTTP(_ status: Int, _ code: String, file: StaticString = #filePath, line: UInt = #line,
                _ body: () async throws -> Void) async {
    do {
        try await body()
        XCTFail("expected \(status) \(code)", file: file, line: line)
    } catch let ClipError.http(s, env) {
        XCTAssertEqual(s, status, file: file, line: line)
        XCTAssertEqual(env?.error, code, file: file, line: line)
    } catch {
        XCTFail("unexpected \(error)", file: file, line: line)
    }
}

final class VirtualClipTests: XCTestCase {

    func testAssetLifecycle() async throws {
        let clip = VirtualClipClient(options: .instant)
        let data = try clipAsset(0x1234)
        let r = try await clip.putAsset(id: "sunset-7f3a", data: data, progress: nil)
        XCTAssertEqual(r, .created(AssetPutResponse(id: "sunset-7f3a", size: data.count, sha256: Hashing.sha256Hex(data))))
        // Same id, same content → 409, which the client surfaces as success.
        let again = try await clip.putAsset(id: "sunset-7f3a", data: data, progress: nil)
        XCTAssertEqual(again, .alreadyPresent)
        // Same content under another id is stored again.
        if case .alreadyPresent = try await clip.putAsset(id: "copy", data: data, progress: nil) { XCTFail() }
        let list = try await clip.assets()
        XCTAssertEqual(list.map(\.id), ["copy", "sunset-7f3a"])
        XCTAssertEqual(list[1].frames, 1)
        XCTAssertEqual(list[1].width, 536)
        let back = try await clip.getAsset(id: "sunset-7f3a")
        XCTAssertEqual(back, data)
        let status = try await clip.status()
        XCTAssertEqual(status.storage.used, data.count * 2)
        try await clip.deleteAsset(id: "copy")
        await expectHTTP(404, "not_found") { try await clip.deleteAsset(id: "copy") }
    }

    func testUploadValidation() async throws {
        let clip = VirtualClipClient(options: VirtualClipClient.Options(latency: .zero, bytesPerSecond: 0, storageTotal: 100_000, maxAssets: 2))
        await expectHTTP(400, "invalid_id") { _ = try await clip.putAsset(id: "Bad_ID", data: try clipAsset(1), progress: nil) }
        await expectHTTP(422, "malformed") { _ = try await clip.putAsset(id: "junk", data: Data("nope".utf8), progress: nil) }
        let small = try HCAEncoder.encode(frames: [.init(pixels: RGB565Frame(width: 10, height: 10), durationMs: 0)])
        await expectHTTP(422, "malformed") { _ = try await clip.putAsset(id: "small", data: small, progress: nil) }
        // Glyph atlases may be any size.
        _ = try await clip.putAsset(id: "atlas", data: try atlasAsset(3), progress: nil)
        var rng = SeededRNG(9)
        let noisy = try HCAEncoder.encode(frames: [.init(pixels: frame(536, 240) { _, _ in UInt16.random(in: 0...UInt16.max, using: &rng) }, durationMs: 0)])
        await expectHTTP(413, "no_space") { _ = try await clip.putAsset(id: "big", data: noisy, progress: nil) }
        _ = try await clip.putAsset(id: "one", data: try clipAsset(5), progress: nil)
        await expectHTTP(413, "too_many_assets") { _ = try await clip.putAsset(id: "two", data: try clipAsset(6), progress: nil) }
    }

    func testPlaylistValidationAndDeleteRemovesItems() async throws {
        let clip = VirtualClipClient(options: .instant)
        _ = try await clip.putAsset(id: "a", data: try clipAsset(1), progress: nil)
        _ = try await clip.putAsset(id: "atlas", data: try atlasAsset(1), progress: nil)
        await expectHTTP(422, "unknown_asset") { try await clip.putPlaylist(Playlist(items: [.asset("missing", durationMs: 0)])) }
        await expectHTTP(422, "unknown_asset") { try await clip.putPlaylist(Playlist(items: [.asset("atlas", durationMs: 0)])) }
        await expectHTTP(422, "invalid_playlist") { try await clip.putPlaylist(Playlist(version: 2, items: [])) }
        let pl = Playlist(items: [.asset("a", durationMs: 4000), .scene("snow", durationMs: 30_000)])
        try await clip.putPlaylist(pl)
        let got = try await clip.playlist()
        XCTAssertEqual(got, pl)
        try await clip.deleteAsset(id: "a")
        let after = try await clip.playlist()
        XCTAssertEqual(after.items.map(\.type), [.scene])
    }

    func testConfigMergeAndLimits() async throws {
        let clip = VirtualClipClient(options: .instant)
        let full = try await clip.putConfig(ClipConfig(name: "Léa", brightness: 90))
        XCTAssertEqual(full.name, "Léa")
        XCTAssertEqual(full.brightness, 90)
        XCTAssertEqual(full.uploadTimeoutS, 120)
        XCTAssertNil(full.apPassword, "the passphrase is write-only: no answer carries it (PROTOCOL §4)")
        await expectHTTP(422, "invalid_config") { _ = try await clip.putConfig(ClipConfig(uploadTimeoutS: 5)) }
        await expectHTTP(422, "invalid_config") { _ = try await clip.putConfig(ClipConfig(apPassword: "1234567")) }
        let cfg = try await clip.config()
        XCTAssertEqual(cfg.brightness, 90)
    }

    func testTimeShowAndSession() async throws {
        let now = Date(timeIntervalSince1970: 1_760_100_000)
        let clip = VirtualClipClient(options: .instant, clock: { now })
        try await clip.setTime(TimeSync(epoch: 1_760_100_000 + 3600, tzOffsetS: 7200))
        var s = try await clip.status()
        XCTAssertTrue(s.time.synced)
        XCTAssertEqual(s.time.epoch, 1_760_103_600)
        XCTAssertEqual(s.time.tzOffsetS, 7200)
        XCTAssertEqual(s.playlist.index, -1)
        XCTAssertNil(s.playlist.current)

        await expectHTTP(404, "unknown_asset") { try await clip.show(id: "nope", durationMs: nil) }
        _ = try await clip.putAsset(id: "pic", data: try clipAsset(0x07E0), progress: nil)
        try await clip.show(id: "pic", durationMs: nil)
        s = try await clip.status()
        XCTAssertEqual(s.playlist.current, "pic")

        // The panel stays on during a session (PROTOCOL §3); in panel-off mode it rests and the
        // screenshot is what will show on resume.
        var d = await clip.display()
        XCTAssertTrue(d.isAwake)
        _ = try await clip.putConfig(ClipConfig(displayDuringUpload: false))
        d = await clip.display()
        XCTAssertFalse(d.isAwake)
        let shot = try await clip.screenshot()
        XCTAssertEqual(shot.width, 536)
        try await clip.endSession()
        d = await clip.display()
        XCTAssertTrue(d.isAwake)
        let ends = await clip.sessionEndCount
        XCTAssertEqual(ends, 1)
    }

    func testScreenshotShowsCurrentAssetAndBrightness() async throws {
        let clip = VirtualClipClient(options: .instant)
        _ = try await clip.putAsset(id: "green", data: try clipAsset(0x07E0), progress: nil)
        try await clip.putPlaylist(Playlist(items: [.asset("green", durationMs: 60_000, transition: .cut)]))
        let shot = try await clip.screenshot()
        XCTAssertTrue(shot.pixels.allSatisfy { $0 == 0x07E0 })
        try await clip.setBrightness(51)
        let d = await clip.display()
        XCTAssertEqual(d.level, 0.2, accuracy: 0.001)
        await expectHTTP(422, "bad_request") { try await clip.setBrightness(300) }
        try await clip.next()
        try await clip.previous()
    }

    func testSchedulingAndScenes() async throws {
        let base = Date(timeIntervalSince1970: 1_760_100_000)
        let clockBox = ClockBox(base)
        let clip = VirtualClipClient(options: .instant, clock: { clockBox.now })
        _ = try await clip.putAsset(id: "bday", data: try clipAsset(0xF800), progress: nil)
        _ = try await clip.putAsset(id: "loop", data: try clipAsset(0x001F), progress: nil)
        await expectHTTP(422, "unknown_asset") {
            try await clip.putPlaylist(Playlist(items: [], queue: [QueueEntry(id: "q", at: 1, type: .asset, asset: "missing")]))
        }
        await expectHTTP(422, "invalid_playlist") { try await clip.putPlaylist(Playlist(items: [.scene("disco", durationMs: 0)])) }
        await expectHTTP(422, "invalid_playlist") {
            try await clip.putPlaylist(Playlist(items: [], queue: [QueueEntry(id: "a", at: 5, type: .scene, scene: "snow"), QueueEntry(id: "a", at: 6, type: .scene, scene: "snow")]))
        }
        let catalog = try await clip.scenes()
        XCTAssertEqual(catalog.scenes.map(\.id), SceneCatalog.enabledIDs)

        try await clip.putPlaylist(Playlist(items: [.asset("loop", durationMs: 5000, transition: .cut), .scene("sand", durationMs: 5000)],
                                            queue: [QueueEntry(id: "q-1", at: 1_760_100_120, type: .asset, asset: "bday", durationMs: 30_000)]))
        var s = try await clip.status()
        XCTAssertEqual(s.clockOk, false)
        XCTAssertEqual(s.queue, .init(pending: 1, nextAt: 1_760_100_120, done: 0))
        try await clip.setTime(TimeSync(epoch: 1_760_100_000, tzOffsetS: 0))
        // The panel is off (and the queue paused) while the session lasts: end it, then watch the panel.
        try await clip.endSession()
        clockBox.now = base + 6
        var d = await clip.display()
        XCTAssertEqual(d.key, "scene-sand")
        clockBox.now = base + 125
        d = await clip.display()
        XCTAssertEqual(d.currentID, "bday")
        clockBox.now = base + 200
        s = try await clip.status()
        XCTAssertEqual(s.queue, .init(pending: 0, nextAt: nil, done: 1))
        XCTAssertEqual(s.clockOk, true)

        let log = try await clip.batteryLog()
        XCTAssertTrue(log.hasPrefix("t,mv,pct,state,display,brightness\n"))
    }

    func testUnreachableAndLowBattery() async throws {
        let clip = VirtualClipClient(options: .instant)
        await clip.setReachable(false)
        do { _ = try await clip.status(); XCTFail() } catch { XCTAssertTrue((error as? ClipError)?.isUnreachable ?? false) }
        await clip.setReachable(true)
        await clip.setBatteryMillivolts(3400)
        do { _ = try await clip.status(); XCTFail() } catch { XCTAssertTrue((error as? ClipError)?.isUnreachable ?? false) }
    }

    func testOTAProgress() async throws {
        let clip = VirtualClipClient(options: .instant)
        let box = ProgressBox()
        try await clip.ota(firmware: Data(repeating: 0xE9, count: 1000)) { box.add($0) }
        XCTAssertEqual(box.values.last, 1)
        let images = await clip.otaImages
        XCTAssertEqual(images.count, 1)
    }
}

final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ d: Date) { _now = d }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return _now }
        set { lock.lock(); _now = newValue; lock.unlock() }
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []
    func add(_ v: Double) { lock.lock(); _values.append(v); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return _values }
}
