import XCTest
@testable import PixelClipKit

/// End to end: a Tonight plan goes through the SyncEngine (assets, POST /time, one playlist PUT,
/// end session) into the virtual clip, and its panel shows each moment at its time.
final class ScheduleVirtualClipTests: XCTestCase {
    func testPlanSentToVirtualClipFiresOnTime() async throws {
        let base = Date(timeIntervalSince1970: 1_791_655_200)   // 2026-10-10 20:00 at UTC+2
        let clock = ClockBox(base)
        let clip = VirtualClipClient(options: .instant, clock: { clock.now })
        let local = ClipLocalTime(tzOffsetS: 7200)

        var plan = TonightPlan(slots: [
            RotationSlot(id: "loop", item: .asset("loop-1", durationMs: 5000, transition: .cut), title: "Loop"),
            RotationSlot(id: "m", item: .scene("snow", durationMs: 5000, transition: .cut), title: "Snow"),
        ])
        try plan.setWindow(slotID: "m", from: TimeOfDay(hour: 21, minute: 30), until: TimeOfDay(hour: 1, minute: 0))
        let fire = try plan.addMoment(.scene("fire", params: ["palette": .string("amber")]), at: base + 60, durationS: 60,
                                      title: "Fire", now: base)
        let bday = try plan.addMoment(.asset("bday-1"), at: base + 300, durationS: 45, title: "Happy birthday", now: base)
        let playlist = plan.playlist(now: base)

        let report = await SyncEngine(client: clip).sync(
            local: [LocalAsset(id: "loop-1", data: try clipAsset(0x001F)), LocalAsset(id: "bday-1", data: try clipAsset(0xF800))],
            playlist: playlist,
            timeSource: { TimeSync(epoch: Int(clock.now.timeIntervalSince1970), tzOffsetS: local.tzOffsetS) })
        XCTAssertTrue(report.succeeded, "\(report.failures)")
        XCTAssertTrue(report.timeSet)
        let stored = try await clip.playlist()
        XCTAssertEqual(stored, playlist, "windows and queue survive the round trip")
        try await clip.endSession()

        // Projection and panel agree.
        let projection = TimelineProjection.project(playlist, now: base, clock: .synced(at: base), local: local)
        XCTAssertEqual(projection.moments.map(\.fate), [.onTime, .onTime])

        clock.now = base + 30
        var d = await clip.display()
        XCTAssertEqual(d.currentID, "loop-1", "20:00:30: the snow scene is outside its window, only the loop plays")
        clock.now = base + 61
        d = await clip.display()
        XCTAssertEqual(d.key, "scene-fire", "\(fire.id) fires at 20:01")
        clock.now = base + 125
        d = await clip.display()
        XCTAssertEqual(d.currentID, "loop-1")
        clock.now = base + 301
        d = await clip.display()
        XCTAssertEqual(d.currentID, "bday-1", "\(bday.id) fires at 20:05")
        clock.now = base + 400
        let s = try await clip.status()
        XCTAssertEqual(s.queue, .init(pending: 0, nextAt: nil, done: 2))

        // 21:45: the snow scene's window is open and it joins the rotation.
        var sawSnow = false
        for k in 0..<8 {
            clock.now = base + 6300 + TimeInterval(k * 3)
            if await clip.display().key == "scene-snow" { sawSnow = true }
        }
        XCTAssertTrue(sawSnow)
    }

    func testUnsyncedVirtualClipDoesNotFire() async throws {
        let base = Date(timeIntervalSince1970: 1_791_655_200)
        let clock = ClockBox(base)
        let clip = VirtualClipClient(options: .instant, clock: { clock.now })
        var plan = TonightPlan(slots: [RotationSlot(id: "a", item: .asset("loop-1", durationMs: 5000), title: "Loop")])
        try plan.addMoment(.scene("snow", params: [:]), at: base + 60, durationS: 60, title: "Snow", now: base)
        let report = await SyncEngine(client: clip).sync(local: [LocalAsset(id: "loop-1", data: try clipAsset(0x07E0))],
                                                         playlist: plan.playlist(now: base), options: SyncOptions(setTime: false))
        XCTAssertTrue(report.succeeded)
        let status = try await clip.status()
        let projection = TimelineProjection.project(plan.playlist(now: base), now: base,
                                                    clock: ClipClock(status: status, lastSetAt: nil), local: ClipLocalTime(tzOffsetS: 0))
        XCTAssertEqual(projection.moments.first?.fate, .wontFireClockNotSet)
        try await clip.endSession()
        clock.now = base + 70
        let d = await clip.display()
        XCTAssertEqual(d.currentID, "loop-1", "the projection said it won't fire, and it doesn't")
    }
}
