import XCTest
@testable import PixelClipKit

/// Counts and acts on the updater's waits.
final class SleepScript: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func next() -> Int { lock.withLock { _count += 1; return _count } }
}

@MainActor
final class EventBox {
    var events: [FirmwareUpdater.Event] = []
    var waits: [Int] { events.compactMap { if case .waitingForPress(let s) = $0 { s } else { nil } } }
    var uploaded: Bool { events.contains { if case .uploading = $0 { true } else { false } } }
}

@MainActor
final class FirmwareUpdateTests: XCTestCase {
    let image = Data(repeating: 0xE9, count: 2000)

    func testUploadsOnceTheButtonIsPressed() async throws {
        let clip = VirtualClipClient(options: .instant)
        let counted = CountingClipClient(clip)
        let script = SleepScript()
        let updater = FirmwareUpdater(client: counted, sleep: { _ in
            if script.next() == 2 { await clip.pressButton() }
        })
        let box = EventBox()
        try await updater.run(image) { box.events.append($0) }
        XCTAssertEqual(box.waits, [60, 60], "\"Press the button\" with the seconds left, polled once a second")
        XCTAssertTrue(box.uploaded)
        let calls = await counted.calls
        XCTAssertEqual(calls, ["POST /ota/ask", "GET /ota", "GET /ota", "POST /ota"])
        let images = await clip.otaImages
        XCTAssertEqual(images, [image])
        let gate = await clip.updateGate
        XCTAssertFalse(gate.allowed, "used up by the upload")
    }

    func testTheWindowRunsOut() async throws {
        let time = ClockBox(Date(timeIntervalSince1970: 1_800_000_000))
        let clip = VirtualClipClient(options: .instant, clock: { time.now })
        let updater = FirmwareUpdater(client: clip, sleep: { _ in time.now = time.now.addingTimeInterval(1) })
        let box = EventBox()
        do {
            try await updater.run(image) { box.events.append($0) }
            XCTFail("expected notPressed")
        } catch let e as FirmwareUpdater.Failure {
            XCTAssertEqual(e, .notPressed)
        }
        XCTAssertEqual(box.waits.first, 60)
        XCTAssertEqual(box.waits.last, 1)
        XCTAssertEqual(box.waits.count, 60)
        XCTAssertFalse(box.uploaded)
        let images = await clip.otaImages
        XCTAssertEqual(images, [], "nothing was sent")
    }

    func testCancelWhileWaiting() async throws {
        let clip = VirtualClipClient(options: .instant)
        let updater = FirmwareUpdater(client: clip, sleep: { _ in try await Task.sleep(for: .seconds(30)) })
        let box = EventBox()
        let image = image
        let task = Task { @MainActor in try await updater.run(image) { box.events.append($0) } }
        for _ in 0..<200 where box.waits.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(box.waits, [60])
        task.cancel()
        do {
            try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {}
        XCTAssertFalse(box.uploaded)
        let images = await clip.otaImages
        XCTAssertEqual(images, [])
    }

    func testOlderFirmwareUploadsAtOnce() async throws {
        let clip = VirtualClipClient(options: .init(latency: .zero, bytesPerSecond: 0, legacyFirmware: true))
        let counted = CountingClipClient(clip)
        let updater = FirmwareUpdater(client: counted, sleep: { _ in XCTFail("no wait without the gate") })
        let box = EventBox()
        try await updater.run(image) { box.events.append($0) }
        XCTAssertEqual(box.waits, [])
        let calls = await counted.calls
        XCTAssertEqual(calls, ["POST /ota/ask", "POST /ota"])
        let images = await clip.otaImages
        XCTAssertEqual(images, [image])
    }

    func testPressButtonFromTheUploadWaitsAgain() async throws {
        let time = ClockBox(Date(timeIntervalSince1970: 1_800_000_000))
        let clip = VirtualClipClient(options: .instant, clock: { time.now })
        let counted = CountingClipClient(clip)
        // The allowance runs out just before the upload: the clip answers 403 press_button and asks again.
        await counted.setBeforeOTA { time.now = time.now.addingTimeInterval(VirtualClipClient.otaAllowSeconds + 5) }
        let script = SleepScript()
        let updater = FirmwareUpdater(client: counted, sleep: { _ in
            time.now = time.now.addingTimeInterval(1)
            let n = script.next()
            if n == 1 || n == 3 { await clip.pressButton() }
        })
        let box = EventBox()
        try await updater.run(image) { box.events.append($0) }
        let calls = await counted.calls
        XCTAssertEqual(calls.filter { $0 == "POST /ota" }.count, 2)
        XCTAssertEqual(box.waits.count, 3, "the press-the-button guidance again, not an error")
        let images = await clip.otaImages
        XCTAssertEqual(images, [image])

        // No second press: the same guidance, then the window runs out.
        let clip2 = VirtualClipClient(options: .instant, clock: { time.now })
        let counted2 = CountingClipClient(clip2)
        await counted2.setBeforeOTA { time.now = time.now.addingTimeInterval(VirtualClipClient.otaAllowSeconds + 5) }
        let script2 = SleepScript()
        let once = FirmwareUpdater(client: counted2, sleep: { _ in
            time.now = time.now.addingTimeInterval(1)
            if script2.next() == 1 { await clip2.pressButton() }
        })
        do {
            try await once.run(image) { _ in }
            XCTFail("expected notPressed")
        } catch let e as FirmwareUpdater.Failure { XCTAssertEqual(e, .notPressed) }
        XCTAssertTrue(ClipError.http(status: 403, envelope: ErrorEnvelope(error: "press_button", message: "")).isPressButton)
    }

    // MARK: The virtual clip's gate

    nonisolated func testVirtualClipGate() async throws {
        let time = ClockBox(Date(timeIntervalSince1970: 1_800_000_000))
        let clip = VirtualClipClient(options: .instant, clock: { time.now })
        // Not asked: refused before the body, and the clip starts asking.
        await expectHTTP(403, "press_button") { try await clip.ota(firmware: Data([1]), progress: nil) }
        var gate = try await clip.otaState()
        XCTAssertEqual(gate, OTAState(allowed: false, asking: true, secondsLeft: 60))
        // A press during the window allows it for 120 s.
        await clip.pressButton()
        gate = try await clip.otaState()
        XCTAssertEqual(gate, OTAState(allowed: true, asking: false, secondsLeft: 120))
        time.now = time.now.addingTimeInterval(121)
        gate = try await clip.otaState()
        XCTAssertFalse(gate.allowed, "the allowance runs out")
        // An ask runs out after 60 s.
        _ = try await clip.askOTA()
        time.now = time.now.addingTimeInterval(59)
        gate = try await clip.otaState()
        XCTAssertEqual(gate, OTAState(allowed: false, asking: true, secondsLeft: 1))
        time.now = time.now.addingTimeInterval(2)
        gate = try await clip.otaState()
        XCTAssertEqual(gate, OTAState(allowed: false, asking: false, secondsLeft: 0))
        // A press while not asking is the ordinary press (nothing allowed).
        await clip.pressButton()
        gate = await clip.updateGate
        XCTAssertFalse(gate.allowed)

        // Over Bluetooth: the state yes, the ask no.
        let state = await VirtualFastLane.respond(to: FastLaneRequest("GET", "/ota", body: Data()), clip: clip)
        XCTAssertEqual(state.status, 200)
        XCTAssertEqual(try ClipJSON.decoder().decode(OTAState.self, from: state.body).asking, false)
        let ask = await VirtualFastLane.respond(to: FastLaneRequest("POST", "/ota/ask", body: Data()), clip: clip)
        XCTAssertEqual(ask.status, 413)
        XCTAssertTrue(String(decoding: ask.body, as: UTF8.self).contains("use_wifi"))
        XCTAssertFalse(FastLaneRoute("POST", "/ota/ask").isEligible)
        XCTAssertTrue(FastLaneRoute("GET", "/ota").isEligible)

        // The demo presses by itself a moment after the clip asks.
        await clip.setAutoPressForUpdate(after: .seconds(3))
        _ = try await clip.askOTA()
        time.now = time.now.addingTimeInterval(2)
        gate = try await clip.otaState()
        XCTAssertFalse(gate.allowed)
        time.now = time.now.addingTimeInterval(2)
        gate = try await clip.otaState()
        XCTAssertTrue(gate.allowed)

        // Older firmware: 404 on the gate, uploads taken directly.
        let old = VirtualClipClient(options: .init(latency: .zero, bytesPerSecond: 0, legacyFirmware: true))
        await expectHTTP(404, "not_found") { _ = try await old.otaState() }
        await expectHTTP(404, "not_found") { _ = try await old.askOTA() }
        try await old.ota(firmware: Data([1]), progress: nil)
    }

    func testSmartClientRoutesTheGate() async throws {
        let clip = VirtualClipClient(options: .instant)
        let lane = VirtualFastLane(clip: clip, timing: .instant)
        lane.setConnected(true)
        let http = CountingClipClient(clip)
        let links = FakeLinks(lane: FastLaneClipClient(transport: BLETransport(link: lane)))
        let smart = SmartClipClient(http: http, links: links)
        _ = try await smart.otaState()
        XCTAssertEqual(links.records.last?.transport, .bluetooth, "GET /ota works over the fast lane")
        _ = try await smart.askOTA()
        XCTAssertEqual(links.wifiOpens, 1, "the ask opens the clip's Wi‑Fi")
        let calls = await http.calls
        XCTAssertEqual(calls, ["POST /ota/ask"])
    }
}
