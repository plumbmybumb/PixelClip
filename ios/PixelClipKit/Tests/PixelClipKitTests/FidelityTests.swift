import XCTest
@testable import PixelClipKit

/// The virtual clip and the playback engine behave like the firmware (PROTOCOL §4 normative
/// scheduling details).
final class FidelityTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_760_100_000)
    func timing(_ id: String) -> PlaybackEngine.AssetTiming? { .init(frameDurationsMs: [100]) }

    private func engine(_ queue: [QueueEntry], synced: Bool = true) -> PlaybackEngine {
        var e = PlaybackEngine(now: t0)
        e.clockSynced = synced
        e.setPlaylist(Playlist(items: [.asset("loop", durationMs: 4000, transition: .cut)], queue: queue), now: t0)
        return e
    }

    private func at(_ s: Int) -> Int { Int(t0.timeIntervalSince1970) + s }

    func testQueueEntriesPlayOneAtATimeForTheirFullDuration() {
        // b comes due while a plays: it waits, then plays all of its 60 s.
        var e = engine([QueueEntry(id: "a", at: at(10), type: .asset, asset: "A", durationMs: 30_000),
                        QueueEntry(id: "b", at: at(20), type: .asset, asset: "B", durationMs: 60_000)])
        XCTAssertEqual(e.state(at: t0 + 5, timing: timing).currentID, "loop")
        XCTAssertEqual(e.state(at: t0 + 25, timing: timing).queueID, "a", "a keeps the screen; b waits")
        XCTAssertEqual(e.state(at: t0 + 41, timing: timing).queueID, "b", "b starts when a ends (t+40)")
        XCTAssertEqual(e.state(at: t0 + 99, timing: timing).queueID, "b", "…and plays its full 60 s, to t+100")
        let after = e.state(at: t0 + 100.5, timing: timing)
        XCTAssertNil(after.queueID)
        XCTAssertEqual(after.currentID, "loop", "the rotation resumes")
        XCTAssertEqual(e.doneQueueIDs, ["a", "b"])
    }

    func testEntryThatWouldStartMoreThan600sLateIsSkipped() {
        // a runs 15 min; b is due 1 min in, so it would start 14 min late → skipped; c (due during a,
        // starts 5 min late) still plays.
        var e = engine([QueueEntry(id: "a", at: at(0), type: .asset, asset: "A", durationMs: 900_000),
                        QueueEntry(id: "b", at: at(60), type: .asset, asset: "B", durationMs: 30_000),
                        QueueEntry(id: "c", at: at(600), type: .asset, asset: "C", durationMs: 30_000)])
        XCTAssertEqual(e.state(at: t0 + 1, timing: timing).queueID, "a")
        let s = e.state(at: t0 + 901, timing: timing)
        XCTAssertEqual(s.queueID, "c")
        XCTAssertTrue(e.doneQueueIDs.contains("b"), "b would have started 840 s late")
        // Lazily evaluated (nobody looked in between) gives the same answer.
        var lazy = engine([QueueEntry(id: "a", at: at(0), type: .asset, asset: "A", durationMs: 900_000),
                           QueueEntry(id: "b", at: at(60), type: .asset, asset: "B", durationMs: 30_000),
                           QueueEntry(id: "c", at: at(600), type: .asset, asset: "C", durationMs: 30_000)])
        XCTAssertEqual(lazy.state(at: t0 + 901, timing: timing).queueID, "c")
        XCTAssertEqual(lazy.doneQueueIDs, ["a", "b"])
    }

    func testNothingFiresWhileUnsyncedOrDuringASession() {
        var e = engine([QueueEntry(id: "a", at: at(10), type: .scene, scene: "fire", durationMs: 20_000)], synced: false)
        XCTAssertNil(e.state(at: t0 + 15, timing: timing).queueID, "unsynced: nothing fires")
        e.setClockSynced(now: t0 + 15)
        XCTAssertEqual(e.state(at: t0 + 16, timing: timing).queueID, "a", "5 s late is fine")
        XCTAssertEqual(e.state(at: t0 + 34.5, timing: timing).queueID, "a", "plays 20 s from when it started (t+15)")

        // Due during an upload session: fires when the session ends if still within 600 s…
        var s = engine([QueueEntry(id: "q", at: at(30), type: .scene, scene: "fire", durationMs: 10_000)])
        s.setOutput(false, now: t0 + 20)
        XCTAssertNil(s.state(at: t0 + 40, timing: timing).queueID)
        s.setOutput(true, now: t0 + 300)
        let fired = s.state(at: t0 + 301, timing: timing)
        XCTAssertEqual(fired.queueID, "q")
        XCTAssertEqual(fired.content, .scene("fire"))
        // …else it's skipped.
        var late = engine([QueueEntry(id: "q", at: at(30), type: .scene, scene: "fire", durationMs: 10_000)])
        late.setOutput(false, now: t0 + 20)
        _ = late.state(at: t0 + 100, timing: timing)
        late.setOutput(true, now: t0 + 700)
        XCTAssertNil(late.state(at: t0 + 701, timing: timing).queueID)
        XCTAssertTrue(late.doneQueueIDs.contains("q"))
    }

    func testQueueDefaultsToFadeAndSixtySeconds() {
        let q = QueueEntry(id: "q", at: at(0), type: .scene, scene: "snow")
        XCTAssertEqual(q.asPlaylistItem.transition, .fade)
        XCTAssertEqual(q.asPlaylistItem.durationMs, 60_000)
        var e = engine([q])
        XCTAssertEqual(e.state(at: t0 + 0.125, timing: timing).fade, 0.5, accuracy: 0.01)
        XCTAssertEqual(e.state(at: t0 + 59, timing: timing).queueID, "q")
    }

    func testShowDuringAQueueEntryWaitsForIt() {
        var e = engine([QueueEntry(id: "q", at: at(10), type: .scene, scene: "lava", durationMs: 20_000)])
        XCTAssertEqual(e.state(at: t0 + 11, timing: timing).queueID, "q")
        e.show(.asset("pic", durationMs: 5000, transition: .cut), now: t0 + 12)
        XCTAssertEqual(e.state(at: t0 + 20, timing: timing).queueID, "q", "a queue entry wins")
        XCTAssertEqual(e.state(at: t0 + 31, timing: timing).currentID, "pic", "the show starts when it ends")
        XCTAssertEqual(e.state(at: t0 + 36, timing: timing).currentID, "loop")
    }

    func testWindowsAreInactiveWhileUnsynced() {
        var e = PlaybackEngine(now: t0)
        e.setPlaylist(Playlist(items: [.asset("loop", durationMs: 1000),
                                       PlaylistItem(type: .scene, durationMs: 1000, scene: "fire", from: TimeOfDay(hour: 0, minute: 0), until: .endOfDay)]), now: t0)
        for k in 0..<6 { XCTAssertEqual(e.state(at: t0 + Double(k) * 0.5, timing: timing).currentID, "loop") }
        e.clockSynced = true
        let contents = (0..<6).map { e.state(at: t0 + 3 + Double($0) * 0.5, timing: timing).content }
        XCTAssertTrue(contents.contains(.scene("fire")))
    }

    func testTimeOfDayAccepts2400AsUntilOnly() throws {
        XCTAssertEqual(TimeOfDay("24:00"), .endOfDay)
        XCTAssertNil(TimeOfDay("24:01"))
        XCTAssertNil(TimeOfDay("25:00"))
        XCTAssertNil(TimeOfDay("9:30"))
        XCTAssertEqual(TimeOfDay.endOfDay.string, "24:00")
        let item = try ClipJSON.decoder().decode(PlaylistItem.self, from: Data(#"{"type":"scene","scene":"fire","duration_ms":0,"from":"22:00","until":"24:00"}"#.utf8))
        XCTAssertEqual(item.until, .endOfDay)
        XCTAssertTrue(item.isActive(atMinuteOfDay: 23 * 60 + 59))
        XCTAssertFalse(item.isActive(atMinuteOfDay: 0))
        XCTAssertEqual(String(data: try ClipJSON.encoder().encode(item), encoding: .utf8)?.contains(#""until":"24:00""#), true)
        XCTAssertThrowsError(try ClipJSON.decoder().decode(PlaylistItem.self, from: Data(#"{"type":"scene","scene":"fire","duration_ms":0,"from":"24:00"}"#.utf8)))
        // One missing bound means 00:00 / 24:00 (firmware rule).
        XCTAssertTrue(TimeOfDay.window(from: nil, until: TimeOfDay(hour: 1, minute: 0), contains: 30))
        XCTAssertTrue(TimeOfDay.window(from: TimeOfDay(hour: 23, minute: 0), until: nil, contains: 23 * 60 + 30))
        // The planner refuses from == until; the virtual clip does too.
        var plan = TonightPlan(slots: [RotationSlot(id: "m", item: .scene("fire", durationMs: 30_000), title: "Fire")])
        XCTAssertThrowsError(try plan.setWindow(slotID: "m", from: TimeOfDay(hour: 3, minute: 0), until: TimeOfDay(hour: 3, minute: 0)))
        XCTAssertNoThrow(try plan.setWindow(slotID: "m", from: TimeOfDay(hour: 22, minute: 0), until: .endOfDay))
    }

    func testVirtualClipRejectsEmptyWindowsAndBadQueues() async throws {
        let clip = VirtualClipClient(options: .instant)
        await expectHTTP(422, "invalid_playlist") {
            try await clip.putPlaylist(Playlist(items: [PlaylistItem(type: .scene, durationMs: 0, scene: "fire", from: TimeOfDay(hour: 1, minute: 0),
                                                                     until: TimeOfDay(hour: 1, minute: 0))]))
        }
        let tooMany = (0..<65).map { QueueEntry(id: "q\($0)", at: 1_800_000_000 + $0, type: .scene, scene: "fire") }
        await expectHTTP(422, "invalid_playlist") { try await clip.putPlaylist(Playlist(items: [], queue: tooMany)) }
        await expectHTTP(422, "invalid_playlist") {
            try await clip.putPlaylist(Playlist(items: [], queue: [QueueEntry(id: String(repeating: "x", count: 41), at: 5, type: .scene, scene: "fire")]))
        }
        await expectHTTP(422, "invalid_playlist") {
            try await clip.putPlaylist(Playlist(items: [], queue: [QueueEntry(id: "c", at: 5, type: .clock)]))
        }
    }
}
