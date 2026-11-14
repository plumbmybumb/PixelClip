import XCTest
@testable import PixelClipKit

/// PROTOCOL §4 Orientation (2026-10-16): config `orientation` ∈ auto | normal | flipped, `/status`
/// `"orientation":{"mode","flipped"}`, `GET /imu` `"flipped"`.
final class OrientationModelTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try ClipJSON.decoder().decode(T.self, from: Data(json.utf8))
    }

    private func object(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func testConfigWireNamesAndValues() throws {
        for mode in ClipOrientationMode.allCases {
            let body = try ClipJSON.encoder().encode(ClipConfig(orientation: mode))
            XCTAssertEqual(try object(body), ["orientation": mode.rawValue], "a PUT patch carries only the key")
            XCTAssertEqual(try decode(ClipConfig.self, #"{"orientation":"\#(mode.rawValue)"}"#).orientation, mode)
        }
        XCTAssertEqual(ClipOrientationMode.allCases.map(\.rawValue), ["auto", "normal", "flipped"])
        XCTAssertEqual(ClipConfig.deviceDefaults.orientation, .auto, "firmware default")
        // The §4 sample with the key.
        let full = try decode(ClipConfig.self, #"{"name":"PixelClip","brightness":160,"upload_timeout_s":120,"ap_password":"pixelclip-2026","low_battery_pct":8,"default_transition":"fade","tz_offset_s":7200,"orientation":"auto"}"#)
        XCTAssertEqual(full.orientation, .auto)
        XCTAssertEqual(full.brightness, 160)
    }

    func testConfigFromOlderFirmwareAndUnknownValue() throws {
        // Firmware before the flip: no key, and nothing is sent back for it.
        let old = try decode(ClipConfig.self, #"{"name":"PixelClip","brightness":160}"#)
        XCTAssertNil(old.orientation)
        XCTAssertNil(try object(ClipJSON.encoder().encode(old))["orientation"])
        // A mode this app doesn't know reads as the default.
        XCTAssertEqual(try decode(ClipConfig.self, #"{"orientation":"sideways"}"#).orientation, .auto)
        XCTAssertEqual(try decode(ClipConfig.self, #"{"orientation":"FLIPPED"}"#).orientation, .auto)
        // Wrong type still fails loudly (a contract break, not a new mode).
        XCTAssertThrowsError(try decode(ClipConfig.self, #"{"orientation":1}"#))
    }

    func testMergeKeepsOrChangesOrientation() {
        let base = ClipConfig.deviceDefaults
        XCTAssertEqual(base.merging(ClipConfig(brightness: 10)).orientation, .auto)
        XCTAssertEqual(base.merging(ClipConfig(orientation: .flipped)).orientation, .flipped)
        XCTAssertEqual(base.merging(ClipConfig(orientation: .normal)).brightness, 160)
        XCTAssertNil(ClipConfig(orientation: .flipped).validationProblem)
    }

    func testStatusOrientation() throws {
        let base = #"{"ok":true,"device":{"name":"PixelClip","id":"a1b2","fw":"0.1.0","hw":"ws-amoled-1.91","protocol":1},"storage":{"total":10,"used":0,"free":10},"playlist":{"count":0,"index":-1,"current":null},"time":{"epoch":1760100000,"tz_offset_s":0,"synced":true},"uptime_s":5"#
        let flipped = try decode(ClipStatus.self, base + #","orientation":{"mode":"auto","flipped":true}}"#)
        XCTAssertEqual(flipped.orientation, .init(mode: .auto, flipped: true))
        XCTAssertTrue(flipped.isFlipped)
        let forced = try decode(ClipStatus.self, base + #","orientation":{"mode":"flipped","flipped":true}}"#)
        XCTAssertEqual(forced.orientation?.mode, .flipped)
        let normal = try decode(ClipStatus.self, base + #","orientation":{"mode":"normal","flipped":false}}"#)
        XCTAssertEqual(normal.orientation, .init(mode: .normal, flipped: false))
        XCTAssertFalse(normal.isFlipped)
        // Older firmware: no key at all.
        let old = try decode(ClipStatus.self, base + "}")
        XCTAssertNil(old.orientation)
        XCTAssertFalse(old.isFlipped)
        // Unknown mode / missing flag: tolerated.
        let odd = try decode(ClipStatus.self, base + #","orientation":{"mode":"tilted"}}"#)
        XCTAssertEqual(odd.orientation, .init(mode: .auto, flipped: false))
        // Round trip with the wire names.
        let encoded = try object(ClipJSON.encoder().encode(flipped))
        XCTAssertEqual(encoded["orientation"] as? NSDictionary, ["mode": "auto", "flipped": true])
    }
}

final class OrientationVirtualClipTests: XCTestCase {

    func testVirtualClipHonoursTheConfig() async throws {
        let clip = VirtualClipClient(options: .instant)
        // Factory: auto, and the virtual clip (never worn) stays the right way up.
        var cfg = try await clip.config()
        XCTAssertEqual(cfg.orientation, .auto)
        var st = try await clip.status()
        XCTAssertEqual(st.orientation, .init(mode: .auto, flipped: false))
        var shown = await clip.display()
        XCTAssertFalse(shown.flipped)
        var imu = try await clip.imu()
        XCTAssertEqual(imu.flipped, false)

        // Forced flipped: status, panel and /imu all say so; the merge keeps the other keys.
        cfg = try await clip.putConfig(ClipConfig(orientation: .flipped))
        XCTAssertEqual(cfg.orientation, .flipped)
        XCTAssertEqual(cfg.brightness, 160)
        let got = try await clip.config()
        XCTAssertEqual(got, cfg)
        st = try await clip.status()
        XCTAssertEqual(st.orientation, .init(mode: .flipped, flipped: true))
        shown = await clip.display()
        XCTAssertTrue(shown.flipped)
        imu = try await clip.imu()
        XCTAssertEqual(imu.flipped, true)

        // Other keys don't touch it.
        _ = try await clip.putConfig(ClipConfig(brightness: 90))
        st = try await clip.status()
        XCTAssertTrue(st.isFlipped)

        // Normal, then back to auto.
        _ = try await clip.putConfig(ClipConfig(orientation: .normal))
        st = try await clip.status()
        XCTAssertEqual(st.orientation, .init(mode: .normal, flipped: false))
        _ = try await clip.putConfig(ClipConfig(orientation: .auto))
        st = try await clip.status()
        XCTAssertEqual(st.orientation, .init(mode: .auto, flipped: false))
        shown = await clip.display()
        XCTAssertFalse(shown.flipped)

        // Reset is factory again.
        _ = try await clip.putConfig(ClipConfig(orientation: .flipped))
        await clip.reset()
        let after = try await clip.config()
        XCTAssertEqual(after.orientation, .auto)
    }

    /// The frame itself is never turned (PROTOCOL: the framebuffer stays upright).
    func testScreenshotIsNotFlipped() async throws {
        let clip = VirtualClipClient(options: .instant)
        let before = try await clip.screenshot()
        _ = try await clip.putConfig(ClipConfig(orientation: .flipped))
        let after = try await clip.screenshot()
        XCTAssertEqual(before, after)
    }
}

@MainActor
final class OrientationRoutingTests: XCTestCase {

    /// Settings ▸ Auto-Rotate / Flip Screen goes over the Bluetooth fast lane when no Wi‑Fi session is
    /// open, and the answer round-trips the key.
    func testOrientationPutGoesOverTheFastLane() async throws {
        let clip = VirtualClipClient(options: .instant)
        let lane = VirtualFastLane(clip: clip, timing: .instant)
        lane.setConnected(true)
        let http = CountingClipClient(clip)
        let links = FakeLinks(lane: FastLaneClipClient(transport: BLETransport(link: lane)))
        let smart = SmartClipClient(http: http, links: links)

        let cfg = try await smart.putConfig(ClipConfig(orientation: .flipped))
        XCTAssertEqual(cfg.orientation, .flipped)
        let st = try await smart.status()
        XCTAssertEqual(st.orientation, .init(mode: .flipped, flipped: true))
        let imu = try await smart.imu()
        XCTAssertEqual(imu.flipped, true)

        let calls = await http.calls
        XCTAssertEqual(calls, [], "no Wi‑Fi")
        XCTAssertEqual(links.wifiOpens, 0)
        let log = await clip.fastLaneLog
        XCTAssertEqual(log, ["PUT /config", "GET /status", "GET /imu"])
    }
}
