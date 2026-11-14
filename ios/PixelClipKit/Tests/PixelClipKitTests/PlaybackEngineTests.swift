import XCTest
@testable import PixelClipKit

final class PlaybackEngineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_760_100_000)
    let timings: [String: PlaybackEngine.AssetTiming] = [
        "still": .init(frameDurationsMs: [0].map { _ in 100 }),
        "anim": .init(frameDurationsMs: [100, 100, 200]),
    ]
    func timing(_ id: String) -> PlaybackEngine.AssetTiming? { timings[id] }

    func testDurationsFollowProtocolRules() {
        XCTAssertEqual(PlaybackEngine.durationMs(of: .asset("still", durationMs: 0), timing: timings["still"]), 5000)
        XCTAssertEqual(PlaybackEngine.durationMs(of: .asset("anim", durationMs: 0, loops: 3), timing: timings["anim"]), 1200)
        XCTAssertEqual(PlaybackEngine.durationMs(of: .asset("anim", durationMs: 0, loops: 0), timing: timings["anim"]), 400)
        XCTAssertEqual(PlaybackEngine.durationMs(of: .asset("anim", durationMs: 2500), timing: timings["anim"]), 2500)
        XCTAssertEqual(PlaybackEngine.durationMs(of: .scene("sand", durationMs: 0), timing: nil), 60_000)
    }

    func testAdvancesAndLoops() {
        var e = PlaybackEngine(now: t0)
        e.setPlaylist(Playlist(items: [.asset("anim", durationMs: 0, loops: 2, transition: .cut),
                                       .asset("still", durationMs: 1000, transition: .cut)]), now: t0)
        XCTAssertEqual(e.state(at: t0, timing: timing).content, .asset(id: "anim", frame: 0))
        XCTAssertEqual(e.state(at: t0 + 0.15, timing: timing).content, .asset(id: "anim", frame: 1))
        XCTAssertEqual(e.state(at: t0 + 0.25, timing: timing).content, .asset(id: "anim", frame: 2))
        XCTAssertEqual(e.state(at: t0 + 0.45, timing: timing).content, .asset(id: "anim", frame: 0))
        XCTAssertEqual(e.state(at: t0 + 0.85, timing: timing).currentID, "still")
        XCTAssertEqual(e.state(at: t0 + 1.85, timing: timing).currentID, "anim")
        // Far in the future still resolves.
        _ = e.state(at: t0 + 86_400, timing: timing)
    }

    func testFadeRamps() {
        var e = PlaybackEngine(now: t0)
        e.setPlaylist(Playlist(items: [.asset("still", durationMs: 2000, transition: .fade), .asset("anim", durationMs: 2000)]), now: t0)
        XCTAssertEqual(e.state(at: t0 + 0.125, timing: timing).fade, 0.5, accuracy: 0.01)
        XCTAssertEqual(e.state(at: t0 + 1.0, timing: timing).fade, 1)
        XCTAssertEqual(e.state(at: t0 + 1.875, timing: timing).fade, 0.5, accuracy: 0.01)
        // The only item in the rotation plays on: no fade-out between its loops (firmware `single`).
        var one = PlaybackEngine(now: t0)
        one.setPlaylist(Playlist(items: [.asset("still", durationMs: 2000, transition: .fade)]), now: t0)
        XCTAssertEqual(one.state(at: t0 + 1.875, timing: timing).fade, 1)
        XCTAssertEqual(one.state(at: t0 + 2.1, timing: timing).fade, 1)
    }

    func testShowOverrideDefaultsTo60sThenResumes() {
        var e = PlaybackEngine(now: t0)
        e.setPlaylist(Playlist(items: [.asset("still", durationMs: 100_000, transition: .cut)]), now: t0)
        e.show(.asset("anim", durationMs: 0, transition: .cut), now: t0 + 1)
        XCTAssertEqual(e.state(at: t0 + 30, timing: timing).currentID, "anim")
        XCTAssertNil(e.state(at: t0 + 30, timing: timing).playlistIndex)
        XCTAssertEqual(e.state(at: t0 + 62, timing: timing).currentID, "still")
    }

    func testClockAndTextAreSkippedAndEmptyIsIdle() {
        var e = PlaybackEngine(now: t0)
        e.setPlaylist(Playlist(items: [PlaylistItem(type: .clock, durationMs: 5000)]), now: t0)
        XCTAssertEqual(e.state(at: t0 + 1, timing: timing).content, .idle)
        e.setPlaylist(Playlist(items: [PlaylistItem(type: .text, durationMs: 0), .asset("still", durationMs: 1000)]), now: t0)
        XCTAssertEqual(e.state(at: t0 + 0.5, timing: timing).currentID, "still")
        e.setPlaylist(.empty, now: t0)
        XCTAssertEqual(e.state(at: t0, timing: timing).content, .idle)
    }

    func testNextPrevious() {
        var e = PlaybackEngine(now: t0)
        e.setPlaylist(Playlist(items: [.asset("still", durationMs: 9000), .asset("anim", durationMs: 9000)]), now: t0)
        e.next(now: t0 + 1)
        XCTAssertEqual(e.state(at: t0 + 1, timing: timing).currentID, "anim")
        e.previous(now: t0 + 2)
        e.previous(now: t0 + 2)
        XCTAssertEqual(e.state(at: t0 + 2, timing: timing).currentID, "anim")
    }

    func testTimeWindowsAndQueue() {
        // t0 = 2025-10-10 12:40 UTC. tz +2h → 14:40 local.
        var e = PlaybackEngine(now: t0)
        e.tzOffsetS = 7200
        e.setPlaylist(Playlist(items: [
            .asset("still", durationMs: 1000, transition: .cut),
            PlaylistItem(type: .scene, durationMs: 1000, transition: .cut, scene: "fire", from: TimeOfDay("21:30"), until: TimeOfDay("01:00")),
        ], queue: [
            QueueEntry(id: "q-1", at: Int(t0.timeIntervalSince1970) + 60, type: .asset, asset: "anim", durationMs: 2000),
            QueueEntry(id: "late", at: Int(t0.timeIntervalSince1970) - 3600, type: .scene, scene: "sand"),
        ]), now: t0)
        // The scene is outside its window: rotation only ever shows the still.
        for k in 0..<5 { XCTAssertEqual(e.state(at: t0 + Double(k) * 0.7, timing: timing).currentID, "still") }
        // Queue doesn't fire until the clock is synced.
        XCTAssertEqual(e.state(at: t0 + 61, timing: timing).queueID, nil)
        e.clockSynced = true
        let s = e.state(at: t0 + 61, timing: timing)
        XCTAssertEqual(s.queueID, "q-1")
        XCTAssertEqual(s.currentID, "anim")
        XCTAssertTrue(e.doneQueueIDs.contains("late"), "an hour late → skipped")
        _ = e.state(at: t0 + 63, timing: timing)
        XCTAssertTrue(e.doneQueueIDs.contains("q-1"))
        XCTAssertEqual(e.state(at: t0 + 63.1, timing: timing).currentID, "still")
        XCTAssertTrue(e.pendingQueue().isEmpty)

        // At 22:00 local the scene joins the rotation.
        var night = PlaybackEngine(now: t0)
        night.clockSynced = true   // windowed items are inactive while the clock is unsynced
        night.tzOffsetS = 7200 + 7 * 3600 + 20 * 60   // shifts local time to 22:00
        night.setPlaylist(Playlist(items: [PlaylistItem(type: .scene, durationMs: 1000, scene: "fire", from: TimeOfDay("21:30"), until: TimeOfDay("01:00"))]), now: t0)
        XCTAssertEqual(night.state(at: t0, timing: timing).content, .scene("fire"))
    }

    func testSceneItems() {
        var e = PlaybackEngine(now: t0)
        e.setPlaylist(Playlist(items: [.scene("fire", durationMs: 0)]), now: t0)
        XCTAssertEqual(e.state(at: t0 + 30, timing: timing).content, .scene("fire"))
        XCTAssertEqual(PlaybackEngine.durationMs(of: .scene("fire", durationMs: 0), timing: nil), 60_000)
    }
}
