import XCTest
@testable import PixelClipKit

// MARK: - Contract (status struct, info, UUIDs vs the firmware header)

final class PixelClipBLETests: XCTestCase {

    func testStatusGoldenBytes() throws {
        // 3870 mV, 64 %, session + clock + playing, scene, protocol 1, last wake accepted.
        let golden: [UInt8] = [0x1E, 0x0F, 0x40, 0x0D, 0x03, 0x01, 0x01]
        let s = try XCTUnwrap(PixelClipBLEStatus(data: Data(golden)))
        XCTAssertEqual(s.millivolts, 3870)
        XCTAssertEqual(s.percent, 64)
        XCTAssertTrue(s.sessionActive)
        XCTAssertFalse(s.usbPresent)
        XCTAssertTrue(s.clockOK)
        XCTAssertTrue(s.playing)
        XCTAssertFalse(s.alwaysOn)
        XCTAssertEqual(s.itemKind, .scene)
        XCTAssertEqual(s.protocolVersion, 1)
        XCTAssertEqual(s.lastWake, .accepted)
        XCTAssertFalse(s.tooLowToWake)
        XCTAssertEqual([UInt8](s.data), golden, "encodes back to the same bytes")
        XCTAssertEqual(PixelClipBLEStatus.byteCount, golden.count)
        XCTAssertEqual(s.battery, ClipStatus.Battery(mv: 3870, pct: 64, charging: false, usbPresent: false))
    }

    func testStatusLowBatteryUSBAndUnknownFields() throws {
        // 3452 mV, 2 %, low-battery flag, idle, protocol 1, last wake refused for low battery.
        let low = try XCTUnwrap(PixelClipBLEStatus(data: Data([0x7C, 0x0D, 0x02, 0x10, 0x00, 0x01, 0x02])))
        XCTAssertEqual(low.millivolts, 3452)
        XCTAssertTrue(low.tooLowToWake)
        XCTAssertEqual(low.itemKind, PixelClipBLEItemKind.none)
        XCTAssertEqual(low.lastWake, .lowBattery)
        // On USB under the floor without the flag: the firmware would accept (it charges).
        let usb = try XCTUnwrap(PixelClipBLEStatus(data: Data([0x48, 0x0D, 0x00, 0x02 | 0x20, 0x01, 0x01, 0x00])))
        XCTAssertTrue(usb.usbPresent)
        XCTAssertTrue(usb.alwaysOn)
        XCTAssertFalse(usb.tooLowToWake)
        XCTAssertEqual(usb.itemKind, .asset)
        // 0 mV = unknown; an unknown kind from a newer firmware is kept raw.
        let unknown = try XCTUnwrap(PixelClipBLEStatus(data: Data([0x00, 0x00, 0x32, 0x00, 0x09, 0x01, 0x00])))
        XCTAssertNil(unknown.battery.mv)
        XCTAssertFalse(unknown.tooLowToWake)
        XCTAssertNil(unknown.itemKind)
        XCTAssertEqual(unknown.itemKindRaw, 9)
        // Longer values are accepted (appended fields), shorter ones aren't.
        XCTAssertEqual(PixelClipBLEStatus(data: Data([0x1E, 0x0F, 0x40, 0x0D, 0x02, 0x01, 0x01, 0xAA, 0xBB]))?.percent, 64)
        XCTAssertNil(PixelClipBLEStatus(data: Data([0x1E, 0x0F, 0x40, 0x0D, 0x02])))
        XCTAssertNil(PixelClipBLEStatus(data: Data()))
        // Percent is clamped.
        XCTAssertEqual(PixelClipBLEStatus(data: Data([0x68, 0x10, 0xFF, 0x00, 0x00, 0x01, 0x00]))?.percent, 100)
    }

    func testInfo() throws {
        let i = try XCTUnwrap(PixelClipBLEInfo(data: Data("3f2a;0.1.0".utf8)))
        XCTAssertEqual(i, PixelClipBLEInfo(deviceID: "3f2a", firmware: "0.1.0"))
        XCTAssertEqual(PixelClipBLEInfo(data: Data("3f2a;0.2.0;more;fields".utf8))?.firmware, "0.2.0")
        XCTAssertEqual(PixelClipBLEInfo(data: Data("3f2a;0.1.0\0".utf8))?.deviceID, "3f2a")
        XCTAssertNil(PixelClipBLEInfo(data: Data("nope".utf8)))
        XCTAssertNil(PixelClipBLEInfo(data: Data(";0.1.0".utf8)))
        XCTAssertEqual(PixelClipBLEInfo(data: i.data), i)
    }

    func testMatching() {
        XCTAssertTrue(PixelClipBLE.matches(name: nil, serviceUUIDs: [PixelClipBLE.serviceUUID.lowercased()]))
        XCTAssertTrue(PixelClipBLE.matches(name: "PixelClip-3F2A", serviceUUIDs: []))
        XCTAssertFalse(PixelClipBLE.matches(name: "AirPods", serviceUUIDs: ["180F"]))
        XCTAssertFalse(PixelClipBLE.matches(name: nil, serviceUUIDs: []))
    }

    /// The app's constants are copied from `firmware/components/ble/include/pixelclip_ble_uuids.h`; they
    /// must stay identical.
    func testConstantsMatchFirmwareHeader() throws {
        let url = Paths.repoRoot.appendingPathComponent("firmware/components/ble/include/pixelclip_ble_uuids.h")
        guard let header = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("firmware header not reachable from here")
        }
        var defines: [String: String] = [:]
        for line in header.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 3, parts[0] == "#define" else { continue }
            defines[String(parts[1])] = String(parts[2]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        func int(_ k: String) -> Int? {
            guard let v = defines[k] else { return nil }
            return v.hasPrefix("0x") ? Int(v.dropFirst(2), radix: 16) : Int(v)
        }
        XCTAssertEqual(defines["PIXELCLIP_BLE_SERVICE_UUID"], PixelClipBLE.serviceUUID)
        XCTAssertEqual(defines["PIXELCLIP_BLE_CHR_WAKE_UUID"], PixelClipBLE.wakeCharacteristicUUID)
        XCTAssertEqual(defines["PIXELCLIP_BLE_CHR_STATUS_UUID"], PixelClipBLE.statusCharacteristicUUID)
        XCTAssertEqual(defines["PIXELCLIP_BLE_CHR_INFO_UUID"], PixelClipBLE.infoCharacteristicUUID)
        // The fast lane (PROTOCOL §3b).
        XCTAssertEqual(defines["PIXELCLIP_BLE_CHR_REQ_UUID"], PixelClipBLE.requestCharacteristicUUID)
        XCTAssertEqual(defines["PIXELCLIP_BLE_CHR_RSP_UUID"], PixelClipBLE.responseCharacteristicUUID)
        XCTAssertEqual(int("PIXELCLIP_BLE_FRAME_FIRST"), Int(PixelClipBLE.frameFirst))
        XCTAssertEqual(int("PIXELCLIP_BLE_FRAME_LAST"), Int(PixelClipBLE.frameLast))
        XCTAssertEqual(int("PIXELCLIP_BLE_FRAME_SEQ_MASK"), Int(PixelClipBLE.frameSequenceMask))
        XCTAssertEqual(int("PIXELCLIP_BLE_API_MAX_BYTES"), PixelClipBLE.apiMaxBytes)
        XCTAssertEqual(int("PIXELCLIP_BLE_PREFERRED_MTU"), PixelClipBLE.preferredMTU)
        XCTAssertEqual(int("PIXELCLIP_BLE_CMD_WAKE"), Int(PixelClipBLE.wakeCommand))
        XCTAssertEqual(int("PIXELCLIP_BLE_CMD_END"), Int(PixelClipBLE.endCommand))
        XCTAssertEqual(int("PIXELCLIP_BLE_ATT_ERR_LOW_BATTERY"), PixelClipBLE.attErrorLowBattery)
        XCTAssertEqual(int("PIXELCLIP_BLE_STATUS_LEN"), PixelClipBLEStatus.byteCount)
        XCTAssertEqual(int("PIXELCLIP_BLE_FLAG_SESSION_ACTIVE"), Int(PixelClipBLEStatus.Flags.sessionActive.rawValue))
        XCTAssertEqual(int("PIXELCLIP_BLE_FLAG_USB_PRESENT"), Int(PixelClipBLEStatus.Flags.usbPresent.rawValue))
        XCTAssertEqual(int("PIXELCLIP_BLE_FLAG_CLOCK_OK"), Int(PixelClipBLEStatus.Flags.clockOK.rawValue))
        XCTAssertEqual(int("PIXELCLIP_BLE_FLAG_PLAYING"), Int(PixelClipBLEStatus.Flags.playing.rawValue))
        XCTAssertEqual(int("PIXELCLIP_BLE_FLAG_LOW_BATTERY"), Int(PixelClipBLEStatus.Flags.lowBattery.rawValue))
        XCTAssertEqual(int("PIXELCLIP_BLE_FLAG_ALWAYS_ON"), Int(PixelClipBLEStatus.Flags.alwaysOn.rawValue))
        XCTAssertEqual(int("PIXELCLIP_BLE_KIND_NONE"), Int(PixelClipBLEItemKind.none.rawValue))
        XCTAssertEqual(int("PIXELCLIP_BLE_KIND_ASSET"), Int(PixelClipBLEItemKind.asset.rawValue))
        XCTAssertEqual(int("PIXELCLIP_BLE_KIND_SCENE"), Int(PixelClipBLEItemKind.scene.rawValue))
        XCTAssertEqual(int("PIXELCLIP_BLE_KIND_READER"), Int(PixelClipBLEItemKind.reader.rawValue))
        XCTAssertEqual(int("PIXELCLIP_BLE_RESULT_NONE"), Int(PixelClipBLEWakeResult.none.rawValue))
        XCTAssertEqual(int("PIXELCLIP_BLE_RESULT_ACCEPTED"), Int(PixelClipBLEWakeResult.accepted.rawValue))
        XCTAssertEqual(int("PIXELCLIP_BLE_RESULT_LOW_BATTERY"), Int(PixelClipBLEWakeResult.lowBattery.rawValue))
        XCTAssertEqual(int("PIXELCLIP_BLE_RESULT_INVALID"), Int(PixelClipBLEWakeResult.invalid.rawValue))
    }
}

// MARK: - A fake peripheral

/// Scripted radio: answers each call with the events a real PixelClip would send, one at a time on the
/// main actor (never re-entrantly).
@MainActor
final class FakeRadio: DoorbellRadio {
    struct Peripheral {
        var id = UUID()
        var name: String? = "PixelClip-3F2A"
        var rssi = -60
        var services = [PixelClipBLE.serviceUUID]
        var status = PixelClipBLEStatus(millivolts: 3900, percent: 64, flags: [.clockOK, .playing], itemKind: .asset)
        var info = PixelClipBLEInfo(deviceID: "3f2a", firmware: "0.2.0")
        var hasDoorbell = true
        /// ATT error for a wake write (nil = accepted).
        var wakeError: Int?
        /// Notifies session_active after an accepted wake.
        var notifiesAfterWake = true
        /// Drops the Bluetooth link as its Wi‑Fi starts.
        var dropsAfterWake = false
    }

    var onEvent: ((DoorbellEvent) -> Void)?
    var authorization: DoorbellAuthorization = .allowed
    var power: DoorbellRadioState = .poweredOn
    var peripherals: [Peripheral]
    /// The fast-lane link a connected peripheral offers (nil: firmware without `req`/`rsp`).
    var lane: (any FastLaneLink)?
    /// Status reads go unanswered (a dead link iOS still reports as connected).
    var mutedStatus = false
    private(set) var log: [String] = []
    private var subscribed: Set<UUID> = []
    private var queue: [DoorbellEvent] = []
    private var pumping = false

    init(_ peripherals: [Peripheral] = [Peripheral()]) { self.peripherals = peripherals }

    func count(_ entry: String) -> Int { log.filter { $0 == entry }.count }

    private func later(_ e: DoorbellEvent) {
        queue.append(e)
        guard !pumping else { return }
        pumping = true
        Task { @MainActor in
            while !queue.isEmpty {
                let next = queue.removeFirst()
                onEvent?(next)
                await Task.yield()
            }
            pumping = false
        }
    }

    private func index(_ id: UUID) -> Int? { peripherals.firstIndex { $0.id == id } }

    func activate() { log.append("activate"); later(.radio(power)) }
    func scan() {
        log.append("scan")
        for p in peripherals { later(.discovered(id: p.id, name: p.name, rssi: p.rssi, serviceUUIDs: p.services)) }
    }
    func stopScan() { log.append("stopScan") }
    func connect(_ id: UUID) {
        log.append("connect")
        guard let i = index(id) else { later(.connectFailed(id)); return }
        later(.connected(id))
        later(peripherals[i].hasDoorbell ? .ready(id) : .missingCharacteristics(id))
    }
    func disconnect(_ id: UUID) { log.append("disconnect"); subscribed.remove(id) }
    func write(_ command: UInt8, to id: UUID) {
        log.append("write \(command)")
        guard let i = index(id) else { return }
        if command == PixelClipBLE.wakeCommand, let e = peripherals[i].wakeError {
            peripherals[i].status.lastWakeRaw = e == PixelClipBLE.attErrorLowBattery ? PixelClipBLEWakeResult.lowBattery.rawValue : PixelClipBLEWakeResult.invalid.rawValue
            later(.wrote(id, command: command, attError: e))
            return
        }
        later(.wrote(id, command: command, attError: nil))
        if command == PixelClipBLE.wakeCommand {
            if peripherals[i].dropsAfterWake { later(.disconnected(id)); return }
            guard peripherals[i].notifiesAfterWake else { return }
            peripherals[i].status.flags.insert(.sessionActive)
        } else {
            peripherals[i].status.flags.remove(.sessionActive)
        }
        if subscribed.contains(id) { later(.status(id, peripherals[i].status.data)) }
    }
    func subscribeStatus(_ id: UUID) { log.append("subscribe"); subscribed.insert(id) }
    func readStatus(_ id: UUID) {
        log.append("readStatus")
        if !mutedStatus, let i = index(id) { later(.status(id, peripherals[i].status.data)) }
    }
    func readInfo(_ id: UUID) {
        log.append("readInfo")
        if let i = index(id) { later(.info(id, peripherals[i].info.data)) }
    }
    func fastLaneLink(for id: UUID) -> (any FastLaneLink)? { index(id) == nil ? nil : lane }
}

extension DoorbellTimings {
    static let fast = DoorbellTimings(scan: .milliseconds(150), peekScan: .milliseconds(100), connect: .milliseconds(150),
                                      firstStatus: .milliseconds(100), confirm: .milliseconds(150), radio: .milliseconds(300),
                                      endWrite: .milliseconds(150))
}

@MainActor
func states(_ stream: AsyncStream<DoorbellState>) async -> [DoorbellState] {
    var out: [DoorbellState] = []
    for await s in stream { out.append(s) }
    return out
}

// MARK: - State machine

@MainActor
final class DoorbellStateMachineTests: XCTestCase {

    func bell(_ radio: FakeRadio) -> PixelClipDoorbell { PixelClipDoorbell(radio: radio, timings: .fast) }

    /// Rings a fresh doorbell (kept alive until the stream ends) and collects its states.
    func ring(_ radio: FakeRadio) async -> [DoorbellState] {
        let d = bell(radio)
        let out = await states(d.wake())
        _ = d.state   // keep it alive until the stream has ended
        return out
    }

    func testWakeHappyPath() async {
        let radio = FakeRadio()
        let d = bell(radio)
        XCTAssertEqual(d.state, .idle)
        let seen = await states(d.wake())
        XCTAssertEqual(seen, [.scanning, .found(name: "PixelClip-3F2A", rssi: -60), .waking, .accepted, .hotspotUp])
        XCTAssertEqual(d.state, .hotspotUp)
        XCTAssertEqual(radio.count("write 1"), 1)
        XCTAssertEqual(radio.log.prefix(3), ["activate", "scan", "stopScan"])
        XCTAssertTrue(radio.log.contains("subscribe"))
        // Bluetooth is dropped once the hotspot is up.
        XCTAssertEqual(radio.log.last(where: { $0 == "disconnect" }), "disconnect")
        XCTAssertEqual(d.nearby?.linked, false)
        XCTAssertEqual(d.nearby?.info, PixelClipBLEInfo(deviceID: "3f2a", firmware: "0.2.0"))
        XCTAssertEqual(d.nearby?.status?.sessionActive, true)
    }

    func testAlreadyAwakeSkipsTheWrite() async {
        var p = FakeRadio.Peripheral()
        p.status.flags.insert(.sessionActive)
        let radio = FakeRadio([p])
        let seen = await ring(radio)
        XCTAssertEqual(seen, [.scanning, .found(name: "PixelClip-3F2A", rssi: -60), .hotspotUp])
        XCTAssertEqual(radio.count("write 1"), 0)
    }

    func testNothingNearbyTimesOut() async {
        let radio = FakeRadio([])
        let seen = await ring(radio)
        XCTAssertEqual(seen, [.scanning, .failed(.notFound)])
        XCTAssertEqual(radio.count("stopScan"), 1)
    }

    func testIgnoresOtherPeripheralsButMatchesTheNamePrefix() async {
        var other = FakeRadio.Peripheral()
        other.name = "AirPods"; other.services = ["180F"]
        let none = await ring(FakeRadio([other]))
        XCTAssertEqual(none.last, .failed(.notFound))
        var nameOnly = FakeRadio.Peripheral()
        nameOnly.name = "PixelClip-1B2C"; nameOnly.services = []
        let seen = await ring(FakeRadio([other, nameOnly]))
        XCTAssertEqual(seen, [.scanning, .found(name: "PixelClip-1B2C", rssi: -60), .waking, .accepted, .hotspotUp])
    }

    func testBluetoothOffAndUnsupported() async {
        for power in [DoorbellRadioState.poweredOff, .unsupported] {
            let radio = FakeRadio()
            radio.power = power
            let seen = await ring(radio)
            XCTAssertEqual(seen, [.failed(.bluetoothOff)], "\(power)")
            XCTAssertEqual(radio.count("scan"), 0)
        }
    }

    func testUnauthorized() async {
        // Denied earlier: no radio, no prompt.
        let denied = FakeRadio()
        denied.authorization = .denied
        let a = await ring(denied)
        XCTAssertEqual(a, [.failed(.unauthorized)])
        XCTAssertEqual(denied.count("activate"), 0)
        // First use, the person taps Don't Allow on the prompt.
        let declined = FakeRadio()
        declined.authorization = .notDetermined
        declined.power = .unauthorized
        let b = await ring(declined)
        XCTAssertEqual(b, [.failed(.unauthorized)])
        XCTAssertEqual(declined.count("activate"), 1)
    }

    func testLowBatteryFromStatusDoesNotWrite() async {
        var p = FakeRadio.Peripheral()
        p.status = PixelClipBLEStatus(millivolts: 3452, percent: 2, flags: [.lowBattery], itemKind: .none)
        let radio = FakeRadio([p])
        let seen = await ring(radio)
        XCTAssertEqual(seen.last, .failed(.lowBattery))
        XCTAssertFalse(seen.contains(.waking))
        XCTAssertEqual(radio.count("write 1"), 0)
        XCTAssertEqual(radio.count("disconnect"), 1)
    }

    func testRefusedWrites() async {
        var low = FakeRadio.Peripheral()
        low.wakeError = PixelClipBLE.attErrorLowBattery
        let a = await ring(FakeRadio([low]))
        XCTAssertEqual(a.suffix(2), [.waking, .failed(.lowBattery)])
        var invalid = FakeRadio.Peripheral()
        invalid.wakeError = 0x13
        let b = await ring(FakeRadio([invalid]))
        XCTAssertEqual(b.last, .failed(.writeFailed))
        var stranger = FakeRadio.Peripheral()
        stranger.hasDoorbell = false
        let c = await ring(FakeRadio([stranger]))
        XCTAssertEqual(c.last, .failed(.writeFailed))
    }

    func testLinkDroppedAfterAnAcceptedWakeIsSuccess() async {
        var p = FakeRadio.Peripheral()
        p.dropsAfterWake = true
        let seen = await ring(FakeRadio([p]))
        XCTAssertEqual(seen.last, .hotspotUp)
    }

    func testNoConfirmationTrustsTheAcceptedWrite() async {
        var p = FakeRadio.Peripheral()
        p.notifiesAfterWake = false
        let seen = await ring(FakeRadio([p]))
        XCTAssertEqual(seen.last, .hotspotUp, "the join step verifies")
    }

    func testPeekKeepsTheLinkThenEndsTheSession() async {
        var p = FakeRadio.Peripheral()
        p.status.flags.insert(.sessionActive)   // e.g. the button was pressed
        let radio = FakeRadio([p])
        let d = bell(radio)
        await d.peek()
        XCTAssertEqual(d.nearby?.name, "PixelClip-3F2A")
        XCTAssertEqual(d.nearby?.status?.percent, 64)
        XCTAssertEqual(d.nearby?.linked, true)
        XCTAssertEqual(d.nearby?.info?.firmware, "0.2.0")
        XCTAssertEqual(d.state, .idle, "a peek isn't a wake")
        let ended = await d.endSession()
        XCTAssertTrue(ended)
        XCTAssertEqual(radio.count("write 2"), 1)
        XCTAssertEqual(d.nearby?.status?.sessionActive, false)
        d.release()
        XCTAssertEqual(d.nearby?.linked, false)
        XCTAssertEqual(radio.count("disconnect"), 1)
        let noLink = await d.endSession()
        XCTAssertFalse(noLink, "no link: the caller uses HTTP /session/end")
    }

    func testPeekNeverPromptsAndForgetsAClipThatLeft() async {
        let unasked = FakeRadio()
        unasked.authorization = .notDetermined
        let d = bell(unasked)
        await d.peek()
        XCTAssertTrue(unasked.log.isEmpty)
        XCTAssertNil(d.nearby)
        // Seen once, then gone on the next look.
        let radio = FakeRadio()
        let e = bell(radio)
        await e.peek()
        XCTAssertNotNil(e.nearby)
        e.release()
        radio.peripherals = []
        await e.peek()
        XCTAssertNil(e.nearby)
    }

    /// A look on a link that no longer answers drops it and scans again (it used to trust the link
    /// forever, so no later look ever scanned).
    func testPeekChecksAnOldLinkAndRescansWhenItIsDead() async {
        let radio = FakeRadio()
        let d = bell(radio)
        var lines: [String] = []
        d.onLog = { lines.append($0) }
        await d.peek()
        XCTAssertEqual(radio.count("scan"), 1)
        await d.peek()
        XCTAssertEqual(radio.count("scan"), 1, "a live link answers: no scan")
        XCTAssertTrue(lines.contains { $0.contains("the link answers") })
        radio.mutedStatus = true
        await d.peek()
        XCTAssertEqual(radio.count("disconnect"), 1, "the dead link is dropped")
        XCTAssertEqual(radio.count("scan"), 2, "and the clip looked for again")
        XCTAssertEqual(d.nearby?.linked, true)
        XCTAssertTrue(lines.contains { $0.contains("doesn’t answer") })
        XCTAssertTrue(lines.contains { $0.contains("heard PixelClip-3F2A") })
    }

    func testWakeReusesAPeekLink() async {
        let radio = FakeRadio()
        let d = bell(radio)
        await d.peek()
        let reads = radio.count("readStatus")
        let seen = await states(d.wake())
        XCTAssertEqual(seen, [.found(name: "PixelClip-3F2A", rssi: -60), .waking, .accepted, .hotspotUp])
        XCTAssertEqual(radio.count("scan"), 1, "no new scan")
        XCTAssertEqual(radio.count("connect"), 1, "no new connect")
        XCTAssertEqual(radio.count("readStatus"), reads, "the notified status is used: the write goes out at once")
        XCTAssertEqual(radio.log.last(where: { $0.hasPrefix("write") }), "write 1")
    }

    func testLinkedWakeReReadsACachedSessionFlag() async {
        // The Nearby poll last heard "session active"; that may be stale, so it's read again.
        var p = FakeRadio.Peripheral()
        p.status.flags.insert(.sessionActive)
        let radio = FakeRadio([p])
        let d = bell(radio)
        await d.peek()
        radio.peripherals[0].status.flags.remove(.sessionActive)   // the session ended since
        let reads = radio.count("readStatus")
        let seen = await states(d.wake())
        XCTAssertEqual(radio.count("readStatus"), reads + 1)
        XCTAssertEqual(seen.suffix(3), [.waking, .accepted, .hotspotUp])
        XCTAssertEqual(radio.count("write 1"), 1)
    }

    func testScanStopsAtTheFirstMatch() async {
        var second = FakeRadio.Peripheral()
        second.name = "PixelClip-9999"
        let radio = FakeRadio([FakeRadio.Peripheral(), second])
        let seen = await ring(radio)
        XCTAssertEqual(seen[1], .found(name: "PixelClip-3F2A", rssi: -60))
        XCTAssertEqual(radio.count("connect"), 1, "the second advertiser is ignored")
        XCTAssertEqual(Array(radio.log.prefix(3)), ["activate", "scan", "stopScan"])
    }
}

// MARK: - Fallback and the joiner

/// The clip's Wi‑Fi as the joiner sees it: the access point comes up when the doorbell's wake is
/// acknowledged (or the button was pressed), a join only works while it's up, and the probe answers
/// once the phone is on it. State-based, so the probe running alongside the ring can't make a test
/// depend on which of them asks first.
final class FakeClipWiFi: @unchecked Sendable {
    private let lock = NSLock()
    private var _apUp: Bool
    private var _joined: Bool
    private(set) var joinCalls: [(remember: Bool, apUp: Bool)] = []
    /// Refuse remembered configurations (`HotspotJoinError.refused`).
    var refuseRemembered = false
    private(set) var forgotten = 0

    init(apUp: Bool = false, joined: Bool = false) { _apUp = apUp; _joined = joined }

    var apUp: Bool {
        get { lock.withLock { _apUp } }
        set { lock.withLock { _apUp = newValue } }
    }
    var reachable: Bool { lock.withLock { _apUp && _joined } }
    var calls: Int { lock.withLock { joinCalls.count } }
    var remembers: [Bool] { lock.withLock { joinCalls.map(\.remember) } }
    var callsBeforeTheAccessPoint: Int { lock.withLock { joinCalls.filter { !$0.apUp }.count } }

    fileprivate func join(remember: Bool) throws {
        try lock.withLock {
            joinCalls.append((remember, _apUp))
            if remember && refuseRemembered { throw HotspotJoinError.refused("system configuration") }
            guard _apUp else { throw HotspotJoinError.unavailable("not found") }
            _joined = true
        }
    }

    fileprivate func forget() { lock.withLock { forgotten += 1; _joined = false } }
}

struct FakeConfigurator: HotspotConfiguring {
    let wifi: FakeClipWiFi
    func join(ssidPrefix: String, passphrase: String, remember: Bool) async throws { try wifi.join(remember: remember) }
    func forget(ssidPrefix: String) async { wifi.forget() }
}

/// A doorbell that plays scripted states (with optional pauses) and raises the access point on
/// `.accepted` / `.hotspotUp`, like the clip does.
@MainActor
final class ScriptedDoorbell: DoorbellRinging {
    var script: [(DoorbellState, Duration)]
    let wifi: FakeClipWiFi?
    private(set) var rings = 0
    private(set) var releases = 0
    /// When each state was emitted.
    private(set) var emitted: [(DoorbellState, ContinuousClock.Instant)] = []
    var state: DoorbellState = .idle
    var nearby: DoorbellNearby?
    var canScanSilently = true
    var onLog: (@MainActor (String) -> Void)?

    init(_ final: DoorbellState, wifi: FakeClipWiFi? = nil, confirmAfter: Duration = .zero) {
        var s: [(DoorbellState, Duration)] = [(.scanning, .zero)]
        if final == .hotspotUp {
            s += [(.found(name: "PixelClip-3F2A", rssi: -50), .zero), (.waking, .zero), (.accepted, .zero)]
        }
        s.append((final, confirmAfter))
        script = s
        self.wifi = wifi
    }

    init(script: [(DoorbellState, Duration)], wifi: FakeClipWiFi?) {
        self.script = script
        self.wifi = wifi
    }

    func wake() -> AsyncStream<DoorbellState> {
        rings += 1
        let (stream, c) = AsyncStream.makeStream(of: DoorbellState.self)
        let script = script
        Task { @MainActor in
            for (s, pause) in script {
                if pause > .zero { try? await Task.sleep(for: pause) }
                if s == .accepted || s == .hotspotUp { wifi?.apUp = true }
                state = s
                emitted.append((s, .now))
                c.yield(s)
            }
            c.finish()
        }
        return stream
    }
    func peek() async {}
    func endSession() async -> Bool { false }
    func release() { releases += 1 }

    func time(of s: DoorbellState) -> ContinuousClock.Instant? { emitted.first { $0.0 == s }?.1 }
}

/// Fails the first `failures` joins with "network not found", then joins.
final class FlakyConfigurator: HotspotConfiguring, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private(set) var calls = 0
    init(failures: Int) { remaining = failures }
    func join(ssidPrefix: String, passphrase: String, remember: Bool) async throws {
        if step() { throw HotspotJoinError.unavailable("not found") }
    }
    private func step() -> Bool {
        lock.withLock {
            calls += 1
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }
}

@MainActor
final class DoorbellFallbackTests: XCTestCase {

    func testDecision() {
        XCTAssertEqual(DoorbellOutcome.from(.hotspotUp), .woke)
        XCTAssertEqual(DoorbellOutcome.from(.failed(.notFound)), .fallBack(.notFound))
        XCTAssertEqual(DoorbellOutcome.from(.failed(.bluetoothOff)), .fallBack(.bluetoothOff))
        XCTAssertEqual(DoorbellOutcome.from(.failed(.unauthorized)), .fallBack(.unauthorized))
        XCTAssertEqual(DoorbellOutcome.from(.failed(.writeFailed)), .fallBack(.writeFailed))
        XCTAssertEqual(DoorbellOutcome.from(.failed(.lowBattery)), .blocked(.lowBattery))
        XCTAssertEqual(DoorbellOutcome.from(.scanning), .fallBack(.notFound), "a stream that ended early")
        for o in [DoorbellOutcome.fallBack(.notFound), .fallBack(.bluetoothOff), .fallBack(.unauthorized)] {
            XCTAssertTrue(o.shouldJoin)
            XCTAssertTrue(o.usesButton)
            XCTAssertTrue(o.line.contains("button"), o.line)
        }
        XCTAssertFalse(DoorbellOutcome.blocked(.lowBattery).shouldJoin)
        XCTAssertFalse(DoorbellOutcome.woke.usesButton)
        XCTAssertEqual(SendProblem(join: .lowBattery), .tooLowToWake)
        XCTAssertFalse(SendProblem.tooLowToWake.needsButtonPress)
    }

    func joiner(_ bell: ScriptedDoorbell?, wifi: FakeClipWiFi, window: Duration = .milliseconds(300)) -> HotspotJoiner {
        HotspotJoiner(configurator: FakeConfigurator(wifi: wifi), probeAttempts: 2, probeInterval: .milliseconds(1),
                      doorbell: bell, joinRetryInterval: .milliseconds(5), wakeJoinWindow: window,
                      probe: { wifi.reachable })
    }

    func testWokeThenJoins() async {
        let wifi = FakeClipWiFi()
        let bell = ScriptedDoorbell(.hotspotUp, wifi: wifi)
        let j = joiner(bell, wifi: wifi)
        var seen: [DoorbellState] = []
        let outcome = await j.wake { seen.append($0) }
        XCTAssertEqual(outcome, .woke)
        XCTAssertEqual(seen, [.scanning, .found(name: "PixelClip-3F2A", rssi: -50), .waking, .accepted, .hotspotUp])
        XCTAssertEqual(j.state, .notJoined)
        let s = await j.join(probeFirst: false, retryFor: .seconds(1))
        XCTAssertEqual(s, .joined)
    }

    func testConnectRingsFirst() async {
        let wifi = FakeClipWiFi()
        let bell = ScriptedDoorbell(.hotspotUp, wifi: wifi)
        let j = joiner(bell, wifi: wifi)
        let s = await j.connect()
        XCTAssertEqual(s, .joined)
        XCTAssertEqual(bell.rings, 1)
        XCTAssertEqual(j.lastWake, .woke)
        XCTAssertGreaterThanOrEqual(wifi.calls, 1)
    }

    func testFallsBackToTheButtonPath() async {
        // Bluetooth off, but the person had pressed the button: the join still works.
        let pressedWiFi = FakeClipWiFi(apUp: true)
        let pressed = joiner(ScriptedDoorbell(.failed(.bluetoothOff)), wifi: pressedWiFi)
        let a = await pressed.connect()
        XCTAssertEqual(a, .joined)
        XCTAssertEqual(pressed.lastWake, .fallBack(.bluetoothOff))
        // Not found and no Wi‑Fi either: the usual "hold the button" problem (one try, no retry window).
        let awayWiFi = FakeClipWiFi()
        let away = joiner(ScriptedDoorbell(.failed(.notFound)), wifi: awayWiFi)
        let b = await away.connect()
        guard case .unreachable = b else { return XCTFail("\(b)") }
        XCTAssertEqual(awayWiFi.calls, 1)
        XCTAssertEqual(away.failure, .notFound)
        XCTAssertEqual(SendProblem(join: away.failure), .clipNotFound)
        XCTAssertTrue(SendProblem(join: away.failure).needsButtonPress)
    }

    func testLowBatteryStopsBeforeJoining() async {
        let wifi = FakeClipWiFi()
        let j = joiner(ScriptedDoorbell(.failed(.lowBattery), wifi: wifi), wifi: wifi)
        let s = await j.connect()
        guard case .unreachable = s else { return XCTFail("\(s)") }
        XCTAssertEqual(j.failure, .lowBattery)
        XCTAssertEqual(wifi.calls, 0, "never asks iOS to join")
    }

    func testAlreadyReachableAndDisabled() async {
        // Already on the clip's Wi‑Fi: the probe running alongside the ring says so and ends it.
        let onWiFi = FakeClipWiFi(apUp: true, joined: true)
        let quietBell = ScriptedDoorbell(script: [(.scanning, .zero), (.failed(.notFound), .milliseconds(200))], wifi: nil)
        let on = joiner(quietBell, wifi: onWiFi)
        let a = await on.connect()
        XCTAssertEqual(a, .joined)
        XCTAssertEqual(on.lastWake, .alreadyAwake)
        XCTAssertEqual(quietBell.releases, 1, "the probe hit ends the ring")
        XCTAssertEqual(onWiFi.calls, 0, "no join prompt")
        // Bluetooth wake off: no ring, plain join.
        let wifi = FakeClipWiFi(apUp: true)
        let bell = ScriptedDoorbell(.hotspotUp, wifi: wifi)
        let off = joiner(bell, wifi: wifi)
        off.bluetoothWake = false
        let b = await off.connect()
        XCTAssertEqual(b, .joined)
        XCTAssertEqual(bell.rings, 0)
        XCTAssertNil(off.lastWake)
    }
}

// MARK: - The virtual clip

@MainActor
final class VirtualDoorbellTests: XCTestCase {

    func testWakeFlipsTheVirtualClipIntoASession() async throws {
        let clip = VirtualClipClient(options: .instant)
        await clip.setReachable(false)   // Wi‑Fi off, as after a session end
        let d = VirtualDoorbell(clip: clip)
        await d.peek()
        XCTAssertEqual(d.nearby?.linked, true)
        XCTAssertEqual(d.nearby?.status?.sessionActive, false)
        XCTAssertEqual(d.nearby?.info?.deviceID, "7c1e")
        let seen = await states(d.wake())
        XCTAssertEqual(seen, [.scanning, .found(name: "PixelClip-7C1E", rssi: -52), .waking, .accepted, .hotspotUp])
        let inSession = await clip.isInSession
        XCTAssertTrue(inSession)
        XCTAssertEqual(d.nearby?.status?.sessionActive, true)
        XCTAssertEqual(d.nearby?.linked, false, "Bluetooth dropped once the Wi‑Fi is up")
        let status = try await clip.status()   // reachable now
        XCTAssertEqual(status.device.id, "7c1e")
        // A peek link can end the session with 0x02 instead of HTTP.
        await d.peek()
        let ended = await d.endSession()
        XCTAssertTrue(ended)
        let ends = await clip.sessionEndCount
        XCTAssertEqual(ends, 1)
        XCTAssertEqual(d.nearby?.status?.sessionActive, false)
    }

    func testVirtualRefusals() async throws {
        let clip = VirtualClipClient(options: .instant)
        _ = try await clip.putConfig(ClipConfig(bleWake: false))
        _ = try await clip.endSession()
        let off = await states(VirtualDoorbell(clip: clip).wake())
        XCTAssertEqual(off.last, .failed(.notFound), "not advertising with ble_wake off")
        _ = try await clip.putConfig(ClipConfig(bleWake: true))
        try await clip.endSession()
        await clip.setBatteryMillivolts(3420)
        let low = await states(VirtualDoorbell(clip: clip).wake())
        XCTAssertEqual(low.last, .failed(.lowBattery))
        let st = await clip.bleStatus()
        XCTAssertEqual(st?.tooLowToWake, true)
        XCTAssertEqual(st?.lastWake, .lowBattery)
        await clip.setBatteryMillivolts(3900)
        await clip.setBluetoothPresent(false)
        let away = await states(VirtualDoorbell(clip: clip).wake())
        XCTAssertEqual(away.last, .failed(.notFound))
    }

    func testSessionKeysRoundTrip() async throws {
        let clip = VirtualClipClient(options: .instant)
        var cfg = try await clip.config()
        XCTAssertEqual(cfg.bleWake, true)
        XCTAssertEqual(cfg.displayDuringUpload, true)
        XCTAssertEqual(cfg.wifiAlwaysOn, false)
        // Each key round-trips through PUT (merge) and GET.
        cfg = try await clip.putConfig(ClipConfig(bleWake: false))
        XCTAssertEqual(cfg.bleWake, false)
        XCTAssertEqual(cfg.displayDuringUpload, true, "merge keeps the others")
        cfg = try await clip.putConfig(ClipConfig(displayDuringUpload: false))
        XCTAssertEqual(cfg.displayDuringUpload, false)
        cfg = try await clip.putConfig(ClipConfig(wifiAlwaysOn: true))
        let got = try await clip.config()
        XCTAssertEqual(got, cfg)
        XCTAssertEqual(got.bleWake, false)
        XCTAssertEqual(got.displayDuringUpload, false)
        XCTAssertEqual(got.wifiAlwaysOn, true)
        XCTAssertFalse(got.screenStaysOn)
        let s = try await clip.status()
        XCTAssertEqual(s.session?.alwaysOn, true)
        // Wire names (PROTOCOL §3).
        let patch = try ClipJSON.encoder().encode(ClipConfig(bleWake: true, displayDuringUpload: false, wifiAlwaysOn: true))
        let obj = try JSONSerialization.jsonObject(with: patch) as? [String: Bool]
        XCTAssertEqual(obj, ["ble_wake": true, "display_during_upload": false, "wifi_always_on": true])
        let decoded = try ClipJSON.decoder().decode(ClipConfig.self, from: Data(#"{"ble_wake":false,"display_during_upload":true,"wifi_always_on":false}"#.utf8))
        XCTAssertEqual(decoded, ClipConfig(bleWake: false, displayDuringUpload: true, wifiAlwaysOn: false))
        let st = try ClipJSON.decoder().decode(ClipStatus.Session.self, from: Data(#"{"idle_s":3,"timeout_s":120,"always_on":true}"#.utf8))
        XCTAssertEqual(st.alwaysOn, true)
    }

    func testScreenStaysOnDuringASessionUnlessPanelOff() async throws {
        let clip = VirtualClipClient(options: .instant)
        _ = try await clip.putAsset(id: "green", data: try clipAsset(0x07E0), progress: nil)
        try await clip.putPlaylist(Playlist(items: [.asset("green", durationMs: 60_000, transition: .cut)]))
        var d = await clip.display()
        XCTAssertTrue(d.isAwake, "screen on during the session (the default)")
        try await clip.setBrightness(51)
        d = await clip.display()
        XCTAssertEqual(d.level, 0.2, accuracy: 0.001, "brightness is live")
        var ble = await clip.bleStatus()
        XCTAssertEqual(ble?.playing, true)
        XCTAssertEqual(ble?.itemKind, .asset)
        XCTAssertEqual(ble?.sessionActive, true)
        _ = try await clip.putConfig(ClipConfig(displayDuringUpload: false))
        d = await clip.display()
        XCTAssertFalse(d.isAwake, "panel-off mode")
        ble = await clip.bleStatus()
        XCTAssertEqual(ble?.playing, false)
        try await clip.endSession()
        d = await clip.display()
        XCTAssertTrue(d.isAwake)
    }
}
