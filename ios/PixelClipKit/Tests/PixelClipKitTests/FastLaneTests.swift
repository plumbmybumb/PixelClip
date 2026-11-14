import Foundation
import XCTest
@testable import PixelClipKit

// MARK: - Framing (BLEFrameCodec) against firmware/scripts/ble_api.py

final class BLEFrameCodecTests: XCTestCase {

    /// The vectors `ble_api.py --selftest` asserts (the same as firmware/test_host/test_frame.c), copied.
    static let requestVector = (payload: Data(#"POST /brightness\#n{"value":200}"#.utf8), frame: 10,
                                hex: ["80504f5354202f627269", "016768746e6573730a7b", "022276616c7565223a32", "4330307d"])
    static let responseVector = (payload: Data("200 \n{\"ok\":true}".utf8), frame: 8, hex: ["80323030200a7b22", "016f6b223a747275", "42657d"])

    func hex(_ frames: [Data]) -> [String] { frames.map { $0.map { String(format: "%02x", $0) }.joined() } }

    func testGoldenVectors() {
        XCTAssertEqual(FastLaneRequest("POST", "/brightness", body: Data(#"{"value":200}"#.utf8)).encoded, Self.requestVector.payload)
        XCTAssertEqual(hex(BLEFrameCodec.frames(Self.requestVector.payload, maxFrame: Self.requestVector.frame)), Self.requestVector.hex)
        XCTAssertEqual(hex(BLEFrameCodec.frames(Self.responseVector.payload, maxFrame: Self.responseVector.frame)), Self.responseVector.hex)
        XCTAssertEqual(BLEFrameCodec.frames(Data(), maxFrame: 20), [Data([PixelClipBLE.frameFirst | PixelClipBLE.frameLast])])
    }

    /// Reads `ble_api.py` itself, so this app can't drift from the reference client: its request
    /// line, frame sizes and expected hex frames must equal what `BLEFrameCodec` produces.
    func testGoldenVectorsFromTheReferenceScript() throws {
        let url = Paths.repoRoot.appendingPathComponent("firmware/scripts/ble_api.py")
        guard let script = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("ble_api.py not reachable from here") }
        func groups(_ pattern: String) throws -> [String] {
            let re = try NSRegularExpression(pattern: pattern)
            let ns = script as NSString
            let m = try XCTUnwrap(re.firstMatch(in: script, range: NSRange(location: 0, length: ns.length)), "no match for \(pattern)")
            return (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
        }
        func hexList(_ s: String) throws -> [String] {
            let re = try NSRegularExpression(pattern: #""([0-9a-f]+)""#)
            let ns = s as NSString
            return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        }
        /// A Python bytes literal's text (b'…') → bytes (the escapes the script uses).
        func pyBytes(_ s: String) -> Data {
            Data(s.replacingOccurrences(of: #"\n"#, with: "\n").replacingOccurrences(of: #"\'"#, with: "'").utf8)
        }

        // req = build_request("POST", "/brightness", b'{"value":200}'); assert req == b'…'; frames(req, 10) == golden
        let request = pyBytes(try groups(#"assert req == b'([^']*)'"#)[0])
        let size = try XCTUnwrap(Int(try groups(#"f = frames\(req, (\d+)\)"#)[0]))
        let golden = try hexList(try groups(#"golden = \[([^\]]*)\]"#)[0])
        XCTAssertEqual(request, FastLaneRequest("POST", "/brightness", body: Data(#"{"value":200}"#.utf8)).encoded)
        XCTAssertEqual(hex(BLEFrameCodec.frames(request, maxFrame: size)), golden)
        XCTAssertEqual(golden, Self.requestVector.hex)

        // frames(b'200 \n{"ok":true}', 8) == [...]
        let r = try groups(#"frames\(b'([^']*)', (\d+)\)\] == \[([^\]]*)\]"#)
        let response = pyBytes(r[0])
        XCTAssertEqual(hex(BLEFrameCodec.frames(response, maxFrame: try XCTUnwrap(Int(r[1])))), try hexList(r[2]))
        XCTAssertEqual(try hexList(r[2]), Self.responseVector.hex)

        // frames(b"", 20) == [bytes([FIRST | LAST])]
        let empty = try XCTUnwrap(Int(try groups(#"frames\(b"", (\d+)\) == \[bytes\(\[FIRST \| LAST\]\)\]"#)[0]))
        XCTAssertEqual(BLEFrameCodec.frames(Data(), maxFrame: empty), [Data([0xC0])])

        // parse_response vectors.
        XCTAssertTrue(script.contains(#"parse_response(b"400 \nbad_frame") == (400, b"bad_frame")"#))
        XCTAssertEqual(try FastLaneResponse(decoding: Data("400 \nbad_frame".utf8)), FastLaneResponse(status: 400, body: Data("bad_frame".utf8)))
        XCTAssertEqual(try FastLaneResponse(decoding: Data("200 \n{\"ok\":true}".utf8)), FastLaneResponse(status: 200, body: Data("{\"ok\":true}".utf8)))
    }

    /// `ble_api.py --selftest`'s round trips: every size × length reassembles to the same bytes.
    func testRoundTrips() throws {
        for size in [2, 3, 20, 182, 509, 514] {
            for n in [0, 1, size - 1, size, 5000, PixelClipBLE.apiMaxBytes] {
                let message = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) })
                let frames = BLEFrameCodec.frames(message, maxFrame: size)
                XCTAssertTrue(frames.allSatisfy { $0.count <= size })
                XCTAssertNotEqual(frames.first![0] & PixelClipBLE.frameFirst, 0)
                XCTAssertNotEqual(frames.last![0] & PixelClipBLE.frameLast, 0)
                var r = BLEFrameReassembler()
                var out: Data?
                for (i, f) in frames.enumerated() {
                    out = try r.push(f)
                    if i < frames.count - 1 { XCTAssertNil(out) }
                }
                XCTAssertEqual(out, message, "size \(size), \(n) bytes")
            }
        }
    }

    func testSequenceWrapsAfter63() throws {
        let big = Data((0..<6).flatMap { _ in (0...255).map { UInt8($0) } })
        let frames = BLEFrameCodec.frames(big, maxFrame: 20)
        XCTAssertGreaterThan(frames.count, 64)
        XCTAssertEqual(frames[63][0] & PixelClipBLE.frameSequenceMask, 63)
        XCTAssertEqual(frames[64][0] & PixelClipBLE.frameSequenceMask, 0)
        var r = BLEFrameReassembler()
        for f in frames.dropLast() { XCTAssertNil(try r.push(f)) }
        XCTAssertEqual(try r.push(frames.last!), big)
    }

    func testGapsStraysAndRestarts() throws {
        let frames = BLEFrameCodec.frames(Data(repeating: 0x41, count: 100), maxFrame: 20)
        var r = BLEFrameReassembler()
        XCTAssertNil(try r.push(frames[0]))
        XCTAssertThrowsError(try r.push(frames[2])) { XCTAssertEqual($0 as? BLEFrameError, .sequenceGap(got: 2, expected: 1)) }
        XCTAssertFalse(r.isOpen)
        // After a gap, continuations are refused until the next first frame.
        XCTAssertThrowsError(try r.push(frames[3])) { XCTAssertEqual($0 as? BLEFrameError, .strayContinuation(header: frames[3][0])) }
        var fresh = BLEFrameReassembler()
        XCTAssertThrowsError(try fresh.push(frames[1])) { XCTAssertEqual($0 as? BLEFrameError, .strayContinuation(header: 0x01)) }
        XCTAssertThrowsError(try fresh.push(Data())) { XCTAssertEqual($0 as? BLEFrameError, .emptyFrame) }
        // A new first frame drops an incomplete message and starts over.
        XCTAssertNil(try r.push(frames[0]))
        XCTAssertNil(try r.push(frames[1]))
        let other = BLEFrameCodec.frames(Data("hello".utf8), maxFrame: 20)
        XCTAssertEqual(try r.push(other[0]), Data("hello".utf8))
        // Too large for the buffer.
        var small = BLEFrameReassembler(maxBytes: 30)
        let long = BLEFrameCodec.frames(Data(repeating: 1, count: 40), maxFrame: 20)
        XCTAssertNil(try small.push(long[0]))
        XCTAssertThrowsError(try small.push(long[1]))
    }

    func testRequestAndResponseMessages() throws {
        let r = FastLaneRequest("put", "/playlist", body: Data("{}".utf8))
        XCTAssertEqual(r.encoded, Data("PUT /playlist\n{}".utf8))
        XCTAssertEqual(FastLaneRequest(decoding: r.encoded), r)
        XCTAssertEqual(FastLaneRequest(decoding: Data("GET /status".utf8)), FastLaneRequest("GET", "/status"))
        XCTAssertEqual(FastLaneRequest(decoding: Data("GET /status\r\n".utf8)), FastLaneRequest("GET", "/status"))
        XCTAssertNil(FastLaneRequest(decoding: Data("GARBAGE".utf8)))
        XCTAssertNil(FastLaneRequest(decoding: Data("GET status\n".utf8)))
        XCTAssertEqual(FastLaneResponse(status: 200, body: Data("{\"ok\":true}".utf8)).encoded, Data("200 \n{\"ok\":true}".utf8))
        XCTAssertThrowsError(try FastLaneResponse(decoding: Data("200".utf8)))
    }

    func testRouteEligibility() {
        let bulk = [("PUT", "/assets/abc"), ("PUT", "/texts/t1"), ("POST", "/ota"), ("GET", "/screenshot"), ("GET", "/assets/abc"), ("GET", "/batlog")]
        for (m, p) in bulk { XCTAssertTrue(FastLaneRoute(m, p).isBulk, "\(m) \(p)") }
        let small = [("GET", "/status"), ("GET", "/assets"), ("DELETE", "/assets/abc"), ("PUT", "/playlist"),
                     ("PUT", "/config"), ("POST", "/time"), ("POST", "/show/abc"), ("POST", "/next"),
                     ("POST", "/brightness"), ("POST", "/session/end"), ("POST", "/reader"), ("DELETE", "/batlog"), ("PUT", "/fonts/f1"),
                     ("GET", "/scenes"), ("DELETE", "/texts/t1")]
        for (m, p) in small { XCTAssertTrue(FastLaneRoute(m, p).isEligible, "\(m) \(p)") }
        XCTAssertFalse(FastLaneRoute("POST", "/next").isIdempotent)
        XCTAssertTrue(FastLaneRoute("PUT", "/playlist").isIdempotent)
        XCTAssertTrue(FastLaneRoute("POST", "/brightness").isIdempotent)
    }
}

// MARK: - A scripted link

/// A clip end that answers each reassembled request from a script, with write-without-response
/// flow control (`canSend` false after every `burst` writes until `readyToSend`).
@MainActor
final class ScriptedLink: FastLaneLink {
    var onEvent: ((FastLaneLinkEvent) -> Void)?
    var maximumWriteLength = 20
    var burst = 3
    var isConnected = true
    private(set) var isSubscribed = false
    private(set) var canSendWriteWithoutResponse = true
    /// Answers for the requests in order (nil: never answer).
    var answers: [FastLaneResponse?] = []
    var fallback: FastLaneResponse? = FastLaneResponse(status: 200, body: Data("{\"ok\":true}".utf8))
    private(set) var requests: [FastLaneRequest] = []
    private(set) var writes = 0
    private(set) var stalls = 0
    private var rx = BLEFrameReassembler()
    private var inBurst = 0

    func subscribe() { isSubscribed = true; post(.subscribed(true)) }

    func write(_ frame: Data) {
        XCTAssertTrue(canSendWriteWithoutResponse, "wrote while the queue was full")
        XCTAssertLessThanOrEqual(frame.count, maximumWriteLength)
        writes += 1
        inBurst += 1
        if inBurst >= burst {
            canSendWriteWithoutResponse = false
            stalls += 1
            Task { @MainActor in
                await Task.yield()
                self.inBurst = 0
                self.canSendWriteWithoutResponse = true
                self.onEvent?(.readyToSend)
            }
        }
        guard let m = try? rx.push(frame), let r = FastLaneRequest(decoding: m) else { return }
        requests.append(r)
        let answer = answers.isEmpty ? fallback : answers.removeFirst()
        if let answer { notify(answer) }
    }

    /// Sends a response now (e.g. a late one after a timeout).
    func notify(_ response: FastLaneResponse) {
        for f in BLEFrameCodec.frames(response.encoded, maxFrame: maximumWriteLength) { post(.notified(f)) }
    }

    func drop() { isConnected = false; post(.disconnected) }

    private func post(_ e: FastLaneLinkEvent) { Task { @MainActor in self.onEvent?(e) } }
}

func ok(_ json: String = #"{"ok":true}"#, status: Int = 200) -> FastLaneResponse { FastLaneResponse(status: status, body: Data(json.utf8)) }

// MARK: - Transport

@MainActor
final class BLETransportTests: XCTestCase {

    func testExchangeWithBackpressureAndOneAtATime() async throws {
        let link = ScriptedLink()
        let t = BLETransport(link: link)
        let body = Data(repeating: 0x7B, count: 200)   // 11 frames of 20 bytes
        link.answers = [ok(#"{"ok":true,"n":1}"#), ok(#"{"ok":true,"n":2}"#)]
        async let a = t.send(FastLaneRequest("PUT", "/playlist", body: body))
        async let b = t.send(FastLaneRequest("GET", "/status"))
        let (ra, rb) = try await (a, b)
        XCTAssertEqual(link.requests.count, 2)
        XCTAssertEqual(Set([ra.body, rb.body]), [Data(#"{"ok":true,"n":1}"#.utf8), Data(#"{"ok":true,"n":2}"#.utf8)])
        XCTAssertGreaterThan(link.stalls, 2, "paced on canSendWriteWithoutResponse")
        XCTAssertTrue(link.isSubscribed)
        XCTAssertEqual(t.lastExchange?.frameSize, 20)
    }

    func testBusyIsRetriedOnceAfter300ms() async throws {
        let link = ScriptedLink()
        let t = BLETransport(link: link)
        link.answers = [ok(#"{"ok":false,"error":"busy","message":"x"}"#, status: 429), ok()]
        let start = Date()
        let r = try await t.send(FastLaneRequest("POST", "/next"))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(link.requests.count, 2)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.29)
        XCTAssertEqual(t.lastExchange?.attempts, 2)

        // 503 twice: the second answer stands, and the client maps it like HTTP.
        link.answers = [ok(#"{"ok":false,"error":"busy","message":"upload"}"#, status: 503), ok(#"{"ok":false,"error":"busy","message":"upload"}"#, status: 503)]
        let client = FastLaneClipClient(transport: t)
        do {
            try await client.next()
            XCTFail("expected 503")
        } catch let e as ClipError {
            XCTAssertEqual(e, .http(status: 503, envelope: ErrorEnvelope(error: "busy", message: "upload")))
        }
        XCTAssertEqual(link.requests.count, 4, "one retry only")
    }

    func testTimeoutResetsCleanlyAndDropsTheLateAnswer() async throws {
        let link = ScriptedLink()
        let t = BLETransport(link: link, timings: .init(response: .milliseconds(150)))
        link.answers = [nil]
        do {
            _ = try await t.send(FastLaneRequest("GET", "/status"))
            XCTFail("expected a timeout")
        } catch let e as FastLaneError {
            XCTAssertEqual(e, .timeout)
        }
        XCTAssertEqual(t.resets, 1)
        // The abandoned answer arrives late: ignored, and the next request gets its own answer.
        link.notify(ok(#"{"late":true}"#))
        try await Task.sleep(for: .milliseconds(20))
        link.answers = [ok(#"{"fresh":true}"#)]
        let r = try await t.send(FastLaneRequest("GET", "/config"))
        XCTAssertEqual(r.body, Data(#"{"fresh":true}"#.utf8))
    }

    func testDropMidRequestAndUnavailableLink() async throws {
        let link = ScriptedLink()
        let t = BLETransport(link: link, timings: .init(response: .seconds(2)))
        link.answers = [nil]
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            link.drop()
        }
        do {
            _ = try await t.send(FastLaneRequest("GET", "/status"))
            XCTFail("expected a drop")
        } catch let e as FastLaneError { XCTAssertEqual(e, .disconnected) }
        do {
            _ = try await t.send(FastLaneRequest("GET", "/status"))
            XCTFail("expected unavailable")
        } catch let e as FastLaneError { XCTAssertEqual(e, .unavailable) }
    }

    func testClientMapsStatusesLikeHTTP() async throws {
        let link = ScriptedLink()
        let client = FastLaneClipClient(transport: BLETransport(link: link))
        link.answers = [ok(#"{"ok":false,"error":"unknown_asset","message":"Upload it first."}"#, status: 422)]
        do {
            try await client.putPlaylist(Playlist(items: [.asset("nope", durationMs: 1000)]))
            XCTFail("expected 422")
        } catch let e as ClipError {
            XCTAssertEqual(e, .http(status: 422, envelope: ErrorEnvelope(error: "unknown_asset", message: "Upload it first.")))
            XCTAssertEqual(e.code, "unknown_asset")
        }
        link.answers = [ok(#"{"ok":false,"error":"use_wifi","message":"over 16 KB"}"#, status: 413)]
        do { _ = try await client.assets(); XCTFail("expected needsWiFi") } catch let e as FastLaneError { XCTAssertEqual(e, .needsWiFi) }
        link.answers = [FastLaneResponse(status: 400, body: Data("bad_frame".utf8))]
        do { try await client.next(); XCTFail("expected 400") } catch let e as ClipError { XCTAssertEqual(e.code, "bad_frame") }
        // Bulk routes never touch the link.
        let before = link.requests.count
        do { _ = try await client.screenshot(); XCTFail() } catch let e as FastLaneError { XCTAssertEqual(e, .needsWiFi) }
        do { _ = try await client.putAsset(id: "a", data: Data([1]), progress: nil); XCTFail() } catch let e as FastLaneError { XCTAssertEqual(e, .needsWiFi) }
        XCTAssertEqual(link.requests.count, before)
        // The body sent is the HTTP body.
        link.answers = [ok()]
        try await client.setBrightness(200)
        XCTAssertEqual(link.requests.last, FastLaneRequest("POST", "/brightness", body: Data(#"{"value":200}"#.utf8)))
    }
}

// MARK: - Routing (SmartClipClient)

/// Counts every request that reaches it (then forwards).
actor CountingClipClient: ClipClient {
    let inner: any ClipClient
    private(set) var calls: [String] = []
    init(_ inner: any ClipClient) { self.inner = inner }
    private func hit(_ s: String) { calls.append(s) }

    func status() async throws -> ClipStatus { hit("GET /status"); return try await inner.status() }
    func assets() async throws -> [ClipAsset] { hit("GET /assets"); return try await inner.assets() }
    func putAsset(id: String, data: Data, progress: ProgressHandler?) async throws -> AssetPutResult { hit("PUT /assets/\(id)"); return try await inner.putAsset(id: id, data: data, progress: progress) }
    func deleteAsset(id: String) async throws { hit("DELETE /assets/\(id)"); try await inner.deleteAsset(id: id) }
    func getAsset(id: String) async throws -> Data { hit("GET /assets/\(id)"); return try await inner.getAsset(id: id) }
    func playlist() async throws -> Playlist { hit("GET /playlist"); return try await inner.playlist() }
    func putPlaylist(_ playlist: Playlist) async throws { hit("PUT /playlist"); try await inner.putPlaylist(playlist) }
    func config() async throws -> ClipConfig { hit("GET /config"); return try await inner.config() }
    func putConfig(_ patch: ClipConfig) async throws -> ClipConfig { hit("PUT /config"); return try await inner.putConfig(patch) }
    func setTime(_ time: TimeSync) async throws { hit("POST /time"); try await inner.setTime(time) }
    func show(id: String, durationMs: Int?, scroll: PlaylistItem.Scroll?) async throws { hit("POST /show/\(id)"); try await inner.show(id: id, durationMs: durationMs, scroll: scroll) }
    func next() async throws { hit("POST /next"); try await inner.next() }
    func previous() async throws { hit("POST /prev"); try await inner.previous() }
    func setBrightness(_ value: Int) async throws { hit("POST /brightness"); try await inner.setBrightness(value) }
    func screenshot() async throws -> RGB565Frame { hit("GET /screenshot"); return try await inner.screenshot() }
    func ota(firmware: Data, progress: ProgressHandler?) async throws { hit("POST /ota"); try await inner.ota(firmware: firmware, progress: progress) }
    func endSession() async throws { hit("POST /session/end"); try await inner.endSession() }
    func scenes() async throws -> SceneCatalog { hit("GET /scenes"); return try await inner.scenes() }
    func batteryLog() async throws -> String { hit("GET /batlog"); return try await inner.batteryLog() }
    func clearBatteryLog() async throws { hit("DELETE /batlog"); try await inner.clearBatteryLog() }
    func texts() async throws -> [ClipText] { hit("GET /texts"); return try await inner.texts() }
    func putText(id: String, data: Data) async throws -> AssetPutResult { hit("PUT /texts/\(id)"); return try await inner.putText(id: id, data: data) }
    func deleteText(id: String) async throws { hit("DELETE /texts/\(id)"); try await inner.deleteText(id: id) }
    func putFont(id: String, _ font: ReaderFontDocument) async throws { hit("PUT /fonts/\(id)"); try await inner.putFont(id: id, font) }
    func font(id: String) async throws -> ReaderFontDocument { hit("GET /fonts/\(id)"); return try await inner.font(id: id) }
    func reader() async throws -> ReaderStatus { hit("GET /reader"); return try await inner.reader() }
    func readerControl(_ command: ReaderCommand) async throws { hit("POST /reader"); try await inner.readerControl(command) }
    func oracleDraw(cards: [Int]?) async throws { hit("POST /oracle/draw"); try await inner.oracleDraw(cards: cards) }
    func oracleBack() async throws { hit("POST /oracle/back"); try await inner.oracleBack() }
    func oracleTurn() async throws { hit("POST /oracle/turn"); try await inner.oracleTurn() }
    func imu() async throws -> IMUReading { hit("GET /imu"); return try await inner.imu() }
    func calibrateIMU(_ step: IMUCalibrationStep) async throws -> IMUCalibrationResult { hit("POST /imu/calibrate"); return try await inner.calibrateIMU(step) }
}

/// The app's side of the routing, scripted.
@MainActor
final class FakeLinks: ClipLinks {
    var wifiOpen = false
    var lane: (any ClipClient)?
    var wifiFails = false
    private(set) var laneAsks = 0
    private(set) var wifiOpens = 0
    private(set) var records: [ClipRouteRecord] = []

    init(lane: (any ClipClient)? = nil) { self.lane = lane }

    func fastLane() async -> (any ClipClient)? { laneAsks += 1; return lane }
    func openWiFi() async throws {
        wifiOpens += 1
        if wifiFails { throw ClipError.unreachable("no hotspot") }
        wifiOpen = true
    }
    func routed(_ record: ClipRouteRecord) { records.append(record) }
}

/// A fast lane that fails every request the same way.
struct FailingLane: FastLaneTransporting {
    let error: FastLaneError
    func send(_ request: FastLaneRequest) async throws -> FastLaneResponse { throw error }
}

@MainActor
final class SmartRoutingTests: XCTestCase {

    func makeVirtual() async throws -> (VirtualClipClient, VirtualFastLane) {
        let clip = VirtualClipClient(options: .instant)
        let lane = VirtualFastLane(clip: clip, timing: .instant)
        lane.setConnected(true)
        return (clip, lane)
    }

    func testEligibleGoesOverBluetoothWhileWiFiIsClosed() async throws {
        let (clip, link) = try await makeVirtual()
        let http = CountingClipClient(clip)
        let links = FakeLinks(lane: FastLaneClipClient(transport: BLETransport(link: link)))
        let smart = SmartClipClient(http: http, links: links)
        _ = try await smart.status()
        try await smart.setBrightness(90)
        let calls = await http.calls
        XCTAssertEqual(calls, [])
        XCTAssertEqual(links.records.map(\.transport), [.bluetooth, .bluetooth])
        XCTAssertEqual(links.wifiOpens, 0)
        let log = await clip.fastLaneLog
        XCTAssertEqual(log, ["GET /status", "POST /brightness"])
    }

    func testBulkOpensWiFiAndThenEverythingGoesOverHTTP() async throws {
        let (clip, link) = try await makeVirtual()
        let http = CountingClipClient(clip)
        let links = FakeLinks(lane: FastLaneClipClient(transport: BLETransport(link: link)))
        let smart = SmartClipClient(http: http, links: links)
        let tiny = try HCAEncoder.encode(frames: [.init(pixels: RGB565Frame(width: 536, height: 240, fill: 0x1234), durationMs: 0)])
        _ = try await smart.assets()                                       // Bluetooth
        _ = try await smart.putAsset(id: "pic", data: tiny, progress: nil) // needs Wi‑Fi
        try await smart.show(id: "pic", durationMs: nil)                  // Wi‑Fi is up: HTTP
        let calls = await http.calls
        XCTAssertEqual(calls, ["PUT /assets/pic", "POST /show/pic"])
        XCTAssertEqual(links.wifiOpens, 1)
        XCTAssertEqual(links.laneAsks, 1, "bulk routes don't even ask for the fast lane; open Wi‑Fi skips it")
        XCTAssertEqual(links.records.map(\.transport), [.bluetooth, .wifi, .wifi])
    }

    func testWiFiOpenUsesHTTPAndNoLaneFallsBack() async throws {
        let (clip, link) = try await makeVirtual()
        let http = CountingClipClient(clip)
        let links = FakeLinks(lane: FastLaneClipClient(transport: BLETransport(link: link)))
        links.wifiOpen = true
        _ = try await SmartClipClient(http: http, links: links).status()
        XCTAssertEqual(links.laneAsks, 0)
        let noLane = FakeLinks(lane: nil)
        _ = try await SmartClipClient(http: http, links: noLane).config()
        XCTAssertEqual(noLane.wifiOpens, 1)
        let calls = await http.calls
        XCTAssertEqual(calls, ["GET /status", "GET /config"])
    }

    func testUseWiFiAnswerAndBrokenExchanges() async throws {
        let clip = VirtualClipClient(options: .instant)
        let http = CountingClipClient(clip)
        // The clip answers 413 use_wifi (e.g. a long asset list): Wi‑Fi, same request.
        let link = ScriptedLink()
        link.answers = [ok(#"{"ok":false,"error":"use_wifi","message":"big"}"#, status: 413)]
        let links = FakeLinks(lane: FastLaneClipClient(transport: BLETransport(link: link)))
        _ = try await SmartClipClient(http: http, links: links).assets()
        XCTAssertEqual(links.records.last, ClipRouteRecord(route: FastLaneRoute("GET", "/assets"), transport: .wifi, seconds: links.records.last!.seconds, fellBack: true))

        // A timeout on an idempotent route falls back; on POST /next it doesn't (it may have stepped).
        let flaky = FakeLinks(lane: FastLaneClipClient(transport: FailingLane(error: .timeout)))
        _ = try await SmartClipClient(http: http, links: flaky).playlist()
        XCTAssertEqual(flaky.wifiOpens, 1)
        let flaky2 = FakeLinks(lane: FastLaneClipClient(transport: FailingLane(error: .timeout)))
        do {
            try await SmartClipClient(http: http, links: flaky2).next()
            XCTFail("expected unreachable")
        } catch let e as ClipError { XCTAssertTrue(e.isUnreachable) }
        XCTAssertEqual(flaky2.wifiOpens, 0)

        // Wi‑Fi can't be opened either: the hotspot path's error.
        let none = FakeLinks(lane: nil)
        none.wifiFails = true
        do { _ = try await SmartClipClient(http: http, links: none).status(); XCTFail() } catch let e as ClipError { XCTAssertTrue(e.isUnreachable) }
    }

    func testVirtualLaneAnswersLikeTheFirmware() async throws {
        let clip = VirtualClipClient(options: .instant)
        func ask(_ m: String, _ p: String, _ body: String = "") async -> FastLaneResponse {
            await VirtualFastLane.respond(to: FastLaneRequest(m, p, body: Data(body.utf8)), clip: clip)
        }
        let shot = await ask("GET", "/screenshot")
        XCTAssertEqual(shot.status, 413)
        XCTAssertTrue(String(decoding: shot.body, as: UTF8.self).contains("use_wifi"))
        let missing = await ask("GET", "/nope")
        XCTAssertEqual(missing.status, 404)
        let wrong = await ask("DELETE", "/status")
        XCTAssertEqual(wrong.status, 405)
        let bad = await ask("PUT", "/config", "not json")
        XCTAssertEqual(bad.status, 400)
        let unknown = await ask("POST", "/show/ghost")
        XCTAssertEqual(unknown.status, 404)
        let malformed = await VirtualFastLane.respond(to: nil, clip: clip)
        XCTAssertEqual(malformed.status, 400)
        // Out of range / ble_wake off: not heard.
        await clip.setBluetoothPresent(false)
        let gone = await ask("GET", "/status")
        XCTAssertEqual(gone.status, 503)
    }

    func testVirtualLaneOverFramesWithAGap() async throws {
        let (_, link) = try await makeVirtual()
        var seen: [Data] = []
        link.onEvent = { if case .notified(let d) = $0 { seen.append(d) } }
        link.subscribe()
        try await Task.sleep(for: .milliseconds(10))
        let frames = BLEFrameCodec.frames(FastLaneRequest("PUT", "/playlist", body: Data(repeating: 0x20, count: 400)).encoded, maxFrame: link.maximumWriteLength)
        link.write(frames[0])
        link.write(frames[2])   // gap
        for _ in 0..<20 where seen.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        var r = BLEFrameReassembler()
        let message = try seen.compactMap { try r.push($0) }.first
        XCTAssertEqual(try FastLaneResponse(decoding: XCTUnwrap(message)), FastLaneResponse(status: 400, body: Data("bad_frame".utf8)))
    }

    func testDoorbellHandsOutTheFastLaneLink() async throws {
        // PixelClipDoorbell: links (scan, connect) on demand, then reuses the link without scanning.
        let radio = FakeRadio()
        let lane = ScriptedLink()
        radio.lane = lane
        let bell = PixelClipDoorbell(radio: radio, timings: .fast)
        let link = await bell.fastLaneLink()
        XCTAssertTrue(link === lane)
        XCTAssertTrue(bell.fastLaneLinked)
        XCTAssertEqual(radio.count("scan"), 1)
        _ = await bell.fastLaneLink()
        XCTAssertEqual(radio.count("scan"), 1, "reuses the link")
        bell.release()
        XCTAssertFalse(bell.fastLaneLinked)
        // Firmware without the fast lane.
        let old = FakeRadio()
        let oldBell = PixelClipDoorbell(radio: old, timings: .fast)
        let none = await oldBell.fastLaneLink()
        XCTAssertNil(none)
        // The virtual doorbell: not heard → nil.
        let clip = VirtualClipClient(options: .instant)
        await clip.setBluetoothPresent(false)
        let vbell = VirtualDoorbell(clip: clip, fastLaneTiming: .instant)
        let vnone = await vbell.fastLaneLink()
        XCTAssertNil(vnone)
    }
}

