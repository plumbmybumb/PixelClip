import XCTest
@testable import PixelClipKit

// MARK: - Wizard state machine

final class CalibrationWizardTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_760_100_000)

    /// Feed readings at 4 Hz from `start` for `seconds`; returns the first action.
    @discardableResult
    func feed(_ w: inout CalibrationWizard, _ g: IMUVector, from start: TimeInterval, seconds: TimeInterval,
              wobble: Double = 0.003) -> (CalibrationWizard.Action, TimeInterval)? {
        var t = start
        var i = 0
        while t < start + seconds + 0.0001 {
            let n = (i % 2 == 0 ? wobble : -wobble)
            if let a = w.ingest(IMUVector(g.x + n, g.y - n, g.z + n), at: t0.addingTimeInterval(t)) { return (a, t) }
            t += 0.25
            i += 1
        }
        return nil
    }

    func testHappyPathCountsDownAndCapturesBothPoses() throws {
        var w = CalibrationWizard()
        let previous = IMUReading(g: IMUVector(1, 0, 0), calibrated: false, axisMap: .identity)
        w.begin(previous: previous)
        XCTAssertEqual(w.step, .upright)
        XCTAssertEqual(w.phase, .holding)
        XCTAssertEqual(w.previousMap, .identity)
        // A second of readings: still → counting 3, 2…
        XCTAssertNil(feed(&w, .upright, from: 0, seconds: 1.0))
        guard case .counting(let n) = w.phase else { return XCTFail("\(w.phase)") }
        XCTAssertTrue((2...3).contains(n), "\(n)")
        // …and the capture once it has been still for 3 s.
        let (action, at) = try XCTUnwrap(feed(&w, .upright, from: 1.25, seconds: 4))
        XCTAssertEqual(action, .capture(.upright))
        XCTAssertGreaterThanOrEqual(at, 3.0)
        XCTAssertLessThan(at, 4.5)
        XCTAssertEqual(w.phase, .measuring)
        // Readings during the capture don't start another.
        XCTAssertNil(w.ingest(.upright, at: t0.addingTimeInterval(at + 0.25)))
        w.captured(IMUCalibrationResult(step: .upright, raw: IMUVector(1, 0, 0), next: .faceup, calibrated: false))
        XCTAssertEqual(w.step, .faceUp)
        XCTAssertEqual(w.phase, .holding)
        // Step 2.
        let (a2, _) = try XCTUnwrap(feed(&w, .faceUp, from: 10, seconds: 5))
        XCTAssertEqual(a2, .capture(.faceup))
        let map = IMUAxisMap([[0, -1, 0], [1, 0, 0], [0, 0, 1]])
        w.captured(IMUCalibrationResult(step: .faceup, raw: IMUVector(0, 0, -1), calibrated: true, axisMap: map))
        XCTAssertEqual(w.step, .done)
        XCTAssertEqual(w.result, map)
        XCTAssertEqual(w.change?.headline, "Down is now down")
        XCTAssertEqual(w.change?.before, .right, "with the old map, sand fell to the right")
        XCTAssertNil(w.ingest(.upright, at: t0.addingTimeInterval(30)))
    }

    func testMovementResetsTheCountdown() {
        var w = CalibrationWizard()
        w.begin(previous: nil)
        feed(&w, .upright, from: 0, seconds: 2)
        guard case .counting = w.phase else { return XCTFail("\(w.phase)") }
        // A jolt: back to holding, and the 3 s start again from the next still stretch.
        XCTAssertNil(w.ingest(IMUVector(0.3, 0.9, 0.1), at: t0.addingTimeInterval(2.25)))
        XCTAssertEqual(w.phase, .holding)
        XCTAssertFalse(w.isStill)
        XCTAssertNil(feed(&w, .upright, from: 2.5, seconds: 2.5), "not yet: the countdown restarted")
        XCTAssertNotNil(feed(&w, .upright, from: 5.25, seconds: 3))
    }

    func testStillInTheFirstPoseDoesNotCountForTheSecond() throws {
        var w = CalibrationWizard()
        w.begin(previous: nil)
        _ = try XCTUnwrap(feed(&w, .upright, from: 0, seconds: 5))
        w.captured(IMUCalibrationResult(step: .upright, next: .faceup, calibrated: false))
        // The person hasn't turned it yet: still and square, but on the same axis → no countdown.
        XCTAssertNil(feed(&w, .upright, from: 6, seconds: 6))
        XCTAssertTrue(w.needsTurning)
        XCTAssertEqual(w.phase, .holding)
        // Turned onto its back: counts and captures.
        let (a, _) = try XCTUnwrap(feed(&w, .faceUp, from: 13, seconds: 5))
        XCTAssertEqual(a, .capture(.faceup))
        XCTAssertFalse(w.needsTurning)
    }

    func testTiltedIsNotSquare() {
        var w = CalibrationWizard()
        w.begin(previous: nil)
        // Still, but leaning ~45°: never counts.
        XCTAssertNil(feed(&w, IMUVector(0.72, 0.72, 0), from: 0, seconds: 6))
        XCTAssertEqual(w.phase, .holding)
        // Wobbling more than 0.06 g: never counts either.
        var shaky = CalibrationWizard()
        shaky.begin(previous: nil)
        XCTAssertNil(feed(&shaky, .upright, from: 0, seconds: 6, wobble: 0.05))
        XCTAssertEqual(shaky.phase, .holding)
    }

    func testProblemsAndRetry() throws {
        var w = CalibrationWizard()
        w.begin(previous: nil)
        _ = try XCTUnwrap(feed(&w, .upright, from: 0, seconds: 5))
        w.failed(ClipError.http(status: 422, envelope: ErrorEnvelope(error: "not_still", message: "")))
        XCTAssertEqual(w.problem, .notStill)
        XCTAssertEqual(w.step, .upright)
        XCTAssertNil(w.ingest(.upright, at: t0.addingTimeInterval(9)), "paused on the problem")
        w.retry()
        XCTAssertEqual(w.phase, .holding)
        // Second pose, then calibration_failed: both captures discarded, back to step 1.
        _ = try XCTUnwrap(feed(&w, .upright, from: 10, seconds: 5))
        w.captured(IMUCalibrationResult(step: .upright, next: .faceup, calibrated: false))
        _ = try XCTUnwrap(feed(&w, .faceUp, from: 20, seconds: 5))
        w.failed(ClipError.http(status: 422, envelope: ErrorEnvelope(error: "calibration_failed", message: "")))
        XCTAssertEqual(w.problem, .calibrationFailed)
        XCTAssertEqual(w.step, .upright)
        XCTAssertEqual(w.problem?.retryLabel, "Start Over")
        w.retry()
        XCTAssertEqual(w.step, .upright)
        XCTAssertEqual(w.phase, .holding)
    }

    func testNoIMUIsFinal() {
        var w = CalibrationWizard()
        w.begin(previous: IMUReading(present: false, g: .upright, axisMap: .identity, addr: nil))
        XCTAssertEqual(w.problem, .noIMU)
        w.retry()
        XCTAssertEqual(w.problem, .noIMU, "nothing to retry")
        var w2 = CalibrationWizard()
        w2.begin(previous: nil)
        w2.failed(ClipError.http(status: 409, envelope: ErrorEnvelope(error: "no_imu", message: "")))
        XCTAssertEqual(w2.problem, .noIMU)
        XCTAssertTrue(w2.problem?.isFinal == true)
    }

    func testTheClipCanAskForTheOtherPose() {
        // The clip lost the upright capture (it rebooted): after face-up it asks for upright again.
        var w = CalibrationWizard()
        w.begin(previous: nil)
        w.captured(IMUCalibrationResult(step: .upright, next: .faceup, calibrated: false))
        XCTAssertEqual(w.step, .faceUp)
        w.captured(IMUCalibrationResult(step: .faceup, next: .upright, calibrated: true))   // an older map is stored, no new one
        XCTAssertEqual(w.step, .upright, "calibrated:true with `next` is not the end")
    }
}

// MARK: - Error mapping

final class CalibrationProblemTests: XCTestCase {
    func env(_ status: Int, _ code: String) -> ClipError { .http(status: status, envelope: ErrorEnvelope(error: code, message: "m")) }

    func testMapping() {
        XCTAssertEqual(CalibrationProblem(env(422, "not_still")), .notStill)
        XCTAssertEqual(CalibrationProblem(env(422, "ambiguous_pose")), .ambiguousPose)
        XCTAssertEqual(CalibrationProblem(env(422, "calibration_failed")), .calibrationFailed)
        XCTAssertEqual(CalibrationProblem(env(409, "no_imu")), .noIMU)
        XCTAssertEqual(CalibrationProblem(ClipError.http(status: 409, envelope: nil)), .noIMU)
        XCTAssertEqual(CalibrationProblem(env(404, "not_found")), .unsupported)
        XCTAssertEqual(CalibrationProblem(env(422, "invalid_step")), .other)
        XCTAssertEqual(CalibrationProblem(env(500, "imu_timeout")), .other)
        XCTAssertEqual(CalibrationProblem(ClipError.unreachable("gone")), .lostConnection)
        XCTAssertEqual(CalibrationProblem(URLError(.timedOut)), .lostConnection)
        XCTAssertEqual(CalibrationProblem(CocoaError(.fileNoSuchFile)), .other)
    }

    func testCopyNamesTheFix() {
        XCTAssertTrue(CalibrationProblem.ambiguousPose.message(for: .upright).contains("straight up"))
        XCTAssertTrue(CalibrationProblem.ambiguousPose.message(for: .faceUp).contains("flat"))
        XCTAssertTrue(CalibrationProblem.notStill.message(for: .upright).contains("still"))
        XCTAssertEqual(CalibrationProblem.lostConnection.retryLabel, "Reconnect")
        XCTAssertFalse(CalibrationProblem.notStill.isFinal)
        XCTAssertTrue(CalibrationProblem.unsupported.isFinal)
        for p in [CalibrationProblem.notStill, .ambiguousPose, .calibrationFailed, .noIMU, .unsupported, .lostConnection, .other] {
            XCTAssertFalse(p.title.isEmpty)
            XCTAssertFalse(p.message(for: .upright).contains("_"), "no raw codes on screen")
        }
    }
}

// MARK: - Axis maps

final class AxisMapTests: XCTestCase {
    func testCalibrateMatchesTheFirmwareDerivation() throws {
        // scripts/mock_clip.py's pretend chip: upright reads +X, face up +Z.
        let map = try XCTUnwrap(IMUAxisMap.calibrate(upright: IMUVector(0.991, 0.013, -0.021), faceUp: IMUVector(0.011, -0.006, 0.996)))
        XCTAssertEqual(map, IMUAxisMap([[0, 1, 0], [1, 0, 0], [0, 0, -1]]))
        XCTAssertTrue(map.isSignedPermutation)
        // Through the new map the poses read as the display frame expects.
        XCTAssertEqual(ClipDirection(map.apply(IMUVector(0.991, 0.013, -0.021))), .down)
        XCTAssertEqual(ClipDirection(map.apply(IMUVector(0.011, -0.006, 0.996))), .awayFromYou)
        XCTAssertNil(IMUAxisMap.calibrate(upright: IMUVector(0, 1, 0), faceUp: IMUVector(0, -1, 0)), "same chip axis")
        XCTAssertFalse(IMUAxisMap([[1, 0, 0], [1, 0, 0], [0, 0, 1]]).isSignedPermutation)
        // inverse ∘ apply = identity.
        let v = IMUVector(0.2, -0.5, 0.8)
        XCTAssertEqual(map.inverse(map.apply(v)), v)
    }

    func testPlainWords() {
        let fixed = IMUAxisMap([[0, -1, 0], [1, 0, 0], [0, 0, 1]])
        let change = AxisMapChange(old: .identity, new: fixed)
        XCTAssertEqual(change.after, .down)
        XCTAssertEqual(change.before, .right)
        XCTAssertTrue(change.changed)
        XCTAssertEqual(change.headline, "Down is now down")
        XCTAssertEqual(change.detail, "Before, sand fell to the right. Now it falls toward the floor when PixelClip is in your hair.")
        let same = AxisMapChange(old: fixed, new: fixed)
        XCTAssertFalse(same.changed)
        XCTAssertEqual(same.detail, "It was already right: nothing changed.")
        let upsideDown = AxisMapChange(old: IMUAxisMap([[1, 0, 0], [0, -1, 0], [0, 0, -1]]), new: .identity)
        XCTAssertEqual(upsideDown.before, .up)
        XCTAssertNil(AxisMapChange(old: nil, new: .identity).before)
    }

    func testWireFormat() throws {
        let json = #"{"ok":true,"present":true,"g":[0.012,0.998,-0.031],"shake":0.004,"samples":1234,"g_lp":[0.01,0.99,-0.03],"raw":[0.998,0.012,0.031],"calibrated":true,"axis_map":[[0,1,0],[1,0,0],[0,0,-1]],"addr":"0x6B","flipped":true}"#
        let r = try ClipJSON.decoder().decode(IMUReading.self, from: Data(json.utf8))
        XCTAssertTrue(r.present)
        XCTAssertEqual(r.flipped, true, "PROTOCOL §4 Orientation: /imu says whether the screen is turned")
        XCTAssertEqual(r.g, IMUVector(0.012, 0.998, -0.031))
        XCTAssertEqual(r.axisMap, IMUAxisMap([[0, 1, 0], [1, 0, 0], [0, 0, -1]]))
        XCTAssertTrue(r.calibrated)
        XCTAssertEqual(r.samples, 1234)
        // No IMU: present false, no addr.
        let none = try ClipJSON.decoder().decode(IMUReading.self, from: Data(#"{"ok":true,"present":false,"g":[0,1,0],"shake":0,"samples":0,"g_lp":[0,0,0],"raw":[0,0,0],"calibrated":false,"axis_map":[[1,0,0],[0,1,0],[0,0,1]]}"#.utf8))
        XCTAssertFalse(none.present)
        XCTAssertNil(none.addr)
        XCTAssertNil(none.flipped, "firmware before the flip omits it")
        // Calibrate answers.
        let half = try ClipJSON.decoder().decode(IMUCalibrationResult.self, from: Data(#"{"ok":true,"step":"upright","raw":[0.99,0.01,0.02],"next":"faceup","calibrated":false}"#.utf8))
        XCTAssertEqual(half.next, .faceup)
        XCTAssertNil(half.axisMap)
        let full = try ClipJSON.decoder().decode(IMUCalibrationResult.self, from: Data(#"{"ok":true,"step":"faceup","raw":[0,0,1],"calibrated":true,"axis_map":[[0,1,0],[1,0,0],[0,0,-1]],"g":[1,0,0]}"#.utf8))
        XCTAssertTrue(full.calibrated)
        XCTAssertNotNil(full.axisMap)
        let body = try ClipJSON.encoder().encode(IMUCalibrationRequest(step: .faceup))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"step":"faceup"}"#)
    }
}

// MARK: - Client calls

final class IMUVirtualClipTests: XCTestCase {

    func testCalibrationAgainstTheVirtualClip() async throws {
        let clip = VirtualClipClient(options: .instant)
        // Uncalibrated: the pretend chip sits a quarter turn off, so "upright" reads sideways.
        var r = try await clip.imu()
        XCTAssertTrue(r.present)
        XCTAssertFalse(r.calibrated)
        XCTAssertEqual(r.axisMap, .identity)
        XCTAssertEqual(ClipDirection(r.g), .right)
        XCTAssertEqual(r.g.magnitude, 1, accuracy: 0.02)
        let up = try await clip.calibrateIMU(.upright)
        XCTAssertEqual(up.next, .faceup)
        XCTAssertFalse(up.calibrated)
        await clip.setSimulatedPose(.faceUp)
        let face = try await clip.calibrateIMU(.faceup)
        XCTAssertTrue(face.calibrated)
        XCTAssertEqual(face.axisMap, VirtualClipClient.imuMounting)
        // Now down is down.
        await clip.setSimulatedPose(.upright)
        r = try await clip.imu()
        XCTAssertTrue(r.calibrated)
        XCTAssertEqual(ClipDirection(r.g), .down)
        // Reset: the factory map again.
        let reset = try await clip.calibrateIMU(.reset)
        XCTAssertFalse(reset.calibrated)
        r = try await clip.imu()
        XCTAssertEqual(ClipDirection(r.g), .right)
        let log = await clip.requestLog
        XCTAssertEqual(log.filter { $0 == "POST /imu/calibrate" }.count, 3)
        XCTAssertEqual(log.filter { $0 == "GET /imu" }.count, 3)
    }

    func testVirtualErrors() async throws {
        let clip = VirtualClipClient(options: .instant)
        // Same pose twice → calibration_failed (both captures discarded).
        _ = try await clip.calibrateIMU(.upright)
        await expectHTTP(422, "calibration_failed") { _ = try await clip.calibrateIMU(.faceup) }
        // Moving → not_still; tilted → ambiguous_pose.
        await clip.setIMUShaking(true)
        await expectHTTP(422, "not_still") { _ = try await clip.calibrateIMU(.upright) }
        await clip.setIMUShaking(false)
        await clip.setSimulatedPose(IMUVector(0.5, 0.5, 0.5))
        await expectHTTP(422, "ambiguous_pose") { _ = try await clip.calibrateIMU(.upright) }
        // No sensor.
        await clip.setIMUPresent(false)
        await expectHTTP(409, "no_imu") { _ = try await clip.calibrateIMU(.upright) }
        let r = try await clip.imu()
        XCTAssertFalse(r.present)
    }

    func testGravityFollowsASource() async throws {
        let clip = VirtualClipClient(options: .instant)
        _ = try await clip.calibrateIMU(.upright)
        await clip.setSimulatedPose(.faceUp)
        _ = try await clip.calibrateIMU(.faceup)
        // The app feeds the iPhone's tilt: right edge down → +x.
        await clip.setGravitySource { IMUVector(0.5, 0.86, 0) }
        let r = try await clip.imu()
        XCTAssertEqual(r.g.x, 0.5, accuracy: 0.02)
        XCTAssertEqual(r.g.y, 0.86, accuracy: 0.02)
        // No reading from the source: back to the simulated pose.
        await clip.setGravitySource { nil }
        let rest = try await clip.imu()
        XCTAssertEqual(ClipDirection(rest.g), .awayFromYou)
    }
}

/// The real client's requests (paths, method, body) against a stubbed clip.
final class IMUHTTPClientTests: XCTestCase {

    override func setUp() { IMUStub.reset() }

    func testRequests() async throws {
        let client = HTTPClipClient(baseURL: URL(string: "http://imu.test")!, protocolClasses: [IMUStub.self])
        IMUStub.respond("/imu", 200, #"{"ok":true,"present":true,"g":[0,1,0],"calibrated":false,"axis_map":[[1,0,0],[0,1,0],[0,0,1]],"addr":"0x6B"}"#)
        let r = try await client.imu()
        XCTAssertEqual(r.g, .upright)
        IMUStub.respond("/imu/calibrate", 200, #"{"ok":true,"step":"upright","raw":[1,0,0],"next":"faceup","calibrated":false}"#)
        let up = try await client.calibrateIMU(.upright)
        XCTAssertEqual(up.next, .faceup)
        IMUStub.respond("/imu/calibrate", 422, #"{"ok":false,"error":"not_still","message":"the clip moved during the reading: hold it still and retry"}"#)
        do {
            _ = try await client.calibrateIMU(.faceup)
            XCTFail("expected a 422")
        } catch {
            XCTAssertEqual(CalibrationProblem(error), .notStill)
        }
        IMUStub.respond("/imu/calibrate", 409, #"{"ok":false,"error":"no_imu","message":"no accelerometer detected"}"#)
        do {
            _ = try await client.calibrateIMU(.upright)
            XCTFail("expected a 409")
        } catch {
            XCTAssertEqual(CalibrationProblem(error), .noIMU)
        }
        let reqs = IMUStub.requests
        XCTAssertEqual(reqs.map(\.method), ["GET", "POST", "POST", "POST"])
        XCTAssertEqual(reqs.map(\.path), ["/imu", "/imu/calibrate", "/imu/calibrate", "/imu/calibrate"])
        XCTAssertEqual(String(decoding: reqs[1].body, as: UTF8.self), #"{"step":"upright"}"#)
        XCTAssertEqual(String(decoding: reqs[2].body, as: UTF8.self), #"{"step":"faceup"}"#)
    }
}

final class IMUStub: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable { var method: String; var path: String; var body: Data }
    nonisolated(unsafe) private static var store: [Captured] = []
    nonisolated(unsafe) private static var responses: [String: (Int, String)] = [:]
    private static let lock = NSLock()
    static var requests: [Captured] { lock.withLock { store } }
    static func reset() { lock.withLock { store = []; responses = [:] } }
    static func respond(_ path: String, _ status: Int, _ body: String) { lock.withLock { responses[path] = (status, body) } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "imu.test" }
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
        let path = request.url?.path ?? ""
        let c = Captured(method: request.httpMethod ?? "", path: path, body: body)
        let answer = Self.lock.withLock { () -> (Int, String) in
            Self.store.append(c)
            return Self.responses[path] ?? (404, #"{"ok":false,"error":"not_found","message":""}"#)
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: answer.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
