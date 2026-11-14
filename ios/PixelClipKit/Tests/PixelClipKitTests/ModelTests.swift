import XCTest
@testable import PixelClipKit

/// Sample documents copied from docs/PROTOCOL.md §4–§5. Comparisons are on parsed JSON, not strings.
final class ModelTests: XCTestCase {

    let statusJSON = """
    {"ok":true,
     "device":{"name":"PixelClip","id":"a1b2","fw":"0.1.0","hw":"ws-amoled-1.91","protocol":1},
     "battery":{"mv":3870,"pct":64,"charging":false},
     "storage":{"total":12582912,"used":1048576,"free":11534336},
     "playlist":{"count":4,"index":1,"current":"sunset-7f3a"},
     "time":{"epoch":1760100000,"tz_offset_s":7200,"synced":true},
     "session":{"idle_s":12,"timeout_s":120},
     "orientation":{"mode":"auto","flipped":false},
     "uptime_s":5400}
    """

    let playlistJSON = """
    {"version":1,
     "items":[
       {"type":"asset","id":"sunset-7f3a","duration_ms":10000,"transition":"fade"},
       {"type":"asset","id":"cat-anim-2c1d","duration_ms":0,"loops":3,"transition":"cut"},
       {"type":"scene","scene":"snow","duration_ms":30000,"transition":"fade"}
     ]}
    """

    let configJSON = """
    {"name":"PixelClip","brightness":160,"upload_timeout_s":120,"ap_password":"pixelclip-2026",
     "low_battery_pct":8,"default_transition":"fade","tz_offset_s":7200}
    """

    let assetsJSON = """
    {"ok":true,"assets":[{"id":"sunset-7f3a","size":4096,"sha256":"ab12","width":536,"height":240,"frames":1,"atlas":false},
                         {"id":"reader-font-1a2b3c4d-n","size":900,"sha256":"cd34","width":40,"height":64,"frames":12,"atlas":true}]}
    """

    let scheduledJSON = """
    {"version":1,
     "items":[
       {"type":"asset","id":"sunset-7f3a","duration_ms":10000,"transition":"fade"},
       {"type":"scene","scene":"snow","duration_ms":30000,"from":"21:30","until":"01:00"}
     ],
     "queue":[
       {"id":"q-1","at":1760140800,"type":"asset","asset":"happy-bday-3c9a","duration_ms":45000,"transition":"fade"},
       {"id":"q-2","at":1760144400,"type":"scene","scene":"balls","params":{"palette":"candy"},"duration_ms":60000}
     ]}
    """

    let sceneItemJSON = """
    {"type":"scene","scene":"sand","params":{"palette":"amber","density":60},"duration_ms":60000,"transition":"fade"}
    """

    let scenesJSON = """
    {"ok":true,"scenes":[{"id":"sand","params":{"palette":["amber","ocean","forest","candy","mono"],"density":[10,100]}}]}
    """

    func testSchedulingDocument() throws {
        let p = try roundTrip(Playlist.self, scheduledJSON)
        XCTAssertEqual(p.items[1].from, TimeOfDay(hour: 21, minute: 30))
        XCTAssertEqual(p.items[1].until?.string, "01:00")
        XCTAssertEqual(p.queue?.count, 2)
        XCTAssertEqual(p.queue?[0].asset, "happy-bday-3c9a")
        XCTAssertEqual(p.queue?[1].params?["palette"], .string("candy"))
        XCTAssertEqual(p.assetIDs, ["sunset-7f3a", "happy-bday-3c9a"])
        // Windows cross midnight.
        XCTAssertTrue(p.items[1].isActive(atMinuteOfDay: 23 * 60))
        XCTAssertTrue(p.items[1].isActive(atMinuteOfDay: 30))
        XCTAssertFalse(p.items[1].isActive(atMinuteOfDay: 12 * 60))
        XCTAssertTrue(p.items[0].isActive(atMinuteOfDay: 12 * 60))
        // A playlist without a queue still encodes without the key.
        XCTAssertEqual(try jsonObject(ClipJSON.encoder().encode(Playlist(items: []))), try jsonObject("{\"version\":1,\"items\":[]}"))
        XCTAssertNil(TimeOfDay("25:00"))
        XCTAssertNil(TimeOfDay("9:30"))
    }

    func testSceneItemAndCatalog() throws {
        let item = try roundTrip(PlaylistItem.self, sceneItemJSON)
        XCTAssertEqual(item.type, .scene)
        XCTAssertEqual(item.params?["density"], .number(60))
        let cat = try roundTrip(SceneCatalog.self, scenesJSON)
        XCTAssertEqual(cat.scenes.first?.params["density"], .range(10, 100))
    }

    /// The app-side scene allow-list: lava never reaches a picker, even though the firmware's /scenes
    /// still lists it.
    func testSceneAllowListHidesDeclinedScenes() throws {
        XCTAssertFalse(SceneCatalog.enabledIDs.contains("lava"))
        XCTAssertFalse(SceneCatalog.isEnabled("lava"))
        XCTAssertTrue(Set(SceneCatalog.enabledIDs).isSubset(of: SceneCatalog.knownScenes))
        let firmware = SceneCatalog(scenes: SceneCatalog.knownScenes.map { SceneCatalog.Scene(id: $0, params: [:]) })
        XCTAssertEqual(firmware.enabled.scenes.map(\.id), SceneCatalog.enabledIDs)
    }

    func testStatusQueueAndClock() throws {
        let json = statusJSON.replacingOccurrences(of: "\"uptime_s\":5400}", with: "\"uptime_s\":5400,\"queue\":{\"pending\":2,\"next_at\":1760140800,\"done\":1},\"clock_ok\":true}")
        let s = try roundTrip(ClipStatus.self, json)
        XCTAssertEqual(s.queue, .init(pending: 2, nextAt: 1_760_140_800, done: 1))
        XCTAssertEqual(s.clockOk, true)
    }

    func roundTrip<T: Codable>(_ type: T.Type, _ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let value = try ClipJSON.decoder().decode(T.self, from: Data(json.utf8))
        let encoded = try ClipJSON.encoder().encode(value)
        XCTAssertEqual(try jsonObject(encoded), try jsonObject(json), file: file, line: line)
        return value
    }

    func testStatus() throws {
        let s = try roundTrip(ClipStatus.self, statusJSON)
        XCTAssertEqual(s.device.protocolVersion, 1)
        XCTAssertEqual(s.device.name, "PixelClip")
        XCTAssertEqual(s.battery?.pct, 64)
        XCTAssertEqual(s.time.tzOffsetS, 7200)
        XCTAssertEqual(s.session?.timeoutS, 120)
        XCTAssertEqual(s.uptimeS, 5400)
        XCTAssertEqual(s.ssid, "PixelClip-A1B2")
        XCTAssertEqual(s.orientation, .init(mode: .auto, flipped: false))
        XCTAssertFalse(s.isFlipped)
        XCTAssertNoThrow(try s.checkProtocol())
    }

    func testStatusFirmwareExtensions() throws {
        // battery.usb_present, index -1 / current null on an empty playlist.
        let json = statusJSON
            .replacingOccurrences(of: "\"charging\":false", with: "\"charging\":false,\"usb_present\":true")
            .replacingOccurrences(of: "{\"count\":4,\"index\":1,\"current\":\"sunset-7f3a\"}", with: "{\"count\":0,\"index\":-1,\"current\":null}")
        let s = try ClipJSON.decoder().decode(ClipStatus.self, from: Data(json.utf8))
        XCTAssertEqual(s.battery?.usbPresent, true)
        XCTAssertEqual(s.playlist.index, -1)
        XCTAssertNil(s.playlist.current)
    }

    func testProtocolTooNew() throws {
        let s = try ClipJSON.decoder().decode(ClipStatus.self, from: Data(statusJSON.replacingOccurrences(of: "\"protocol\":1", with: "\"protocol\":2").utf8))
        XCTAssertThrowsError(try s.checkProtocol()) { XCTAssertEqual($0 as? ClipError, .protocolTooNew(2)) }
    }

    func testPlaylist() throws {
        let p = try roundTrip(Playlist.self, playlistJSON)
        XCTAssertEqual(p.items.count, 3)
        XCTAssertEqual(p.items[1].loops, 3)
        XCTAssertEqual(p.items[2].type, .scene)
        XCTAssertNil(p.items[2].id)
        XCTAssertEqual(p.assetIDs, ["sunset-7f3a", "cat-anim-2c1d"])
        // Firmware adds "ok":true to document GETs; it must be ignored.
        let withOK = playlistJSON.replacingOccurrences(of: "{\"version\":1,", with: "{\"ok\":true,\"version\":1,")
        XCTAssertEqual(try ClipJSON.decoder().decode(Playlist.self, from: Data(withOK.utf8)), p)
    }

    func testConfigFullAndPartial() throws {
        let c = try roundTrip(ClipConfig.self, configJSON)
        // The §4 sample predates the §3 session keys (older firmware omits them).
        var expected = ClipConfig.deviceDefaults.merging(ClipConfig(tzOffsetS: 7200))
        expected.bleWake = nil; expected.displayDuringUpload = nil; expected.wifiAlwaysOn = nil; expected.orientation = nil
        XCTAssertEqual(c, expected)
        XCTAssertTrue(c.screenStaysOn, "absent = the firmware default (screen on)")
        // A partial PUT encodes only the keys that are set.
        let patch = try ClipJSON.encoder().encode(ClipConfig(brightness: 90))
        XCTAssertEqual(try jsonObject(patch), try jsonObject("{\"brightness\":90}"))
        XCTAssertNil(c.validationProblem)
        XCTAssertNotNil(ClipConfig(uploadTimeoutS: 10).validationProblem)
        XCTAssertNotNil(ClipConfig(apPassword: "short").validationProblem)
        XCTAssertNotNil(ClipConfig(name: "").validationProblem)
    }

    func testAssetsAndSmallBodies() throws {
        let list = try roundTrip(AssetList.self, assetsJSON)
        XCTAssertTrue(list.assets[1].atlas)
        _ = try roundTrip(AssetPutResponse.self, "{\"ok\":true,\"id\":\"a\",\"size\":10,\"sha256\":\"ff\"}")
        _ = try roundTrip(TimeSync.self, "{\"epoch\":1760100000,\"tz_offset_s\":7200}")
        _ = try roundTrip(BrightnessRequest.self, "{\"value\":200}")
        _ = try roundTrip(ShowRequest.self, "{\"duration_ms\":5000}")
        XCTAssertEqual(try jsonObject(ClipJSON.encoder().encode(ShowRequest())), try jsonObject("{}"))
        let e = try roundTrip(ErrorEnvelope.self, "{\"ok\":false,\"error\":\"no_space\",\"message\":\"Full\"}")
        XCTAssertEqual(e.error, "no_space")
    }
}
