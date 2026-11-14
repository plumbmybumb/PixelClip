import XCTest
@testable import PixelClipKit

/// The Tonight planner: local time, plan edits + validation, the hour-by-hour projection, summary
/// and reminders. Fixture: the clip is on UTC+2; "now" is 20:10 local on 2026-10-10.
final class ScheduleTests: XCTestCase {
    let tz = 7200
    lazy var local = ClipLocalTime(tzOffsetS: tz)
    /// 2026-10-10 00:00 at UTC+2.
    let midnight = 1_791_583_200

    func at(_ h: Int, _ m: Int, _ s: Int = 0, day: Int = 0) -> Date {
        Date(timeIntervalSince1970: TimeInterval(midnight + day * 86_400 + h * 3600 + m * 60 + s))
    }
    lazy var now = at(20, 10)

    func slot(_ id: String, _ item: PlaylistItem, _ title: String) -> RotationSlot { RotationSlot(id: id, item: item, title: title) }

    lazy var basePlan = TonightPlan(slots: [
        slot("a", .asset("sunset-1a2b", durationMs: 10_000), "Golden Hour"),
        slot("m", PlaylistItem(type: .scene, durationMs: 30_000, scene: "snow"), "Snow"),
    ])

    // MARK: Local time

    func testClipLocalTime() {
        XCTAssertEqual(local.minuteOfDay(now), 20 * 60 + 10)
        XCTAssertEqual(local.startOfHour(at(20, 59, 59)), at(20, 0))
        XCTAssertEqual(local.startOfDay(at(23, 59)), at(0, 0))
        XCTAssertEqual(local.string(at(0, 5)), "00:05")
        XCTAssertEqual(local.string(at(0, 5, 30), seconds: true), "00:05:30")
        XCTAssertEqual(local.string(at(0, 5), seconds: true), "00:05")
        // Picking 00:00 at 20:10 means tonight's midnight; picking 20:05 means five minutes ago (past),
        // 18:00 (more than an hour ago) means tomorrow.
        XCTAssertEqual(local.date(for: TimeOfDay(hour: 0, minute: 0), near: now), at(0, 0, day: 1))
        XCTAssertEqual(local.date(for: TimeOfDay(hour: 20, minute: 5), near: now), at(20, 5))
        XCTAssertEqual(local.date(for: TimeOfDay(hour: 18, minute: 0), near: now), at(18, 0, day: 1))
        XCTAssertEqual(ClipLocalTime.offsetLabel(7200), "UTC+2")
        XCTAssertEqual(ClipLocalTime.offsetLabel(-12_600), "UTC−3:30")
        XCTAssertEqual(ClipLocalTime.offsetLabel(20_700), "UTC+5:45")
        XCTAssertEqual(ClipLocalTime.offsetLabel(0), "UTC")
        // Negative offsets wrap correctly.
        XCTAssertEqual(ClipLocalTime(tzOffsetS: -3600).minuteOfDay(Date(timeIntervalSince1970: 1800)), 23 * 60 + 30)
    }

    // MARK: Moments

    func testAddMomentValidatesTimeAndDuration() throws {
        var plan = basePlan
        XCTAssertThrowsError(try plan.addMoment(.scene("snow", params: [:]), at: at(20, 5), durationS: 60, title: "Snow", now: now)) {
            XCTAssertEqual($0 as? PlanError, .inThePast)
        }
        XCTAssertThrowsError(try plan.addMoment(.scene("snow", params: [:]), at: now, durationS: 60, title: "Snow", now: now)) {
            XCTAssertEqual($0 as? PlanError, .inThePast)
        }
        XCTAssertThrowsError(try plan.addMoment(.scene("snow", params: [:]), at: at(21, 0), durationS: 4, title: "Snow", now: now)) {
            XCTAssertEqual($0 as? PlanError, .durationOutOfRange)
        }
        XCTAssertThrowsError(try plan.addMoment(.scene("snow", params: [:]), at: at(21, 0), durationS: 1801, title: "Snow", now: now)) {
            XCTAssertEqual($0 as? PlanError, .durationOutOfRange)
        }
        try plan.addMoment(.scene("snow", params: [:]), at: at(21, 0), durationS: 5, title: "Short", now: now)
        try plan.addMoment(.scene("snow", params: [:]), at: at(22, 0), durationS: 1800, title: "Long", now: now)
        XCTAssertEqual(plan.moments.map(\.title), ["Short", "Long"])
        for m in plan.moments { XCTAssertTrue(Moment.isValidID(m.id), m.id) }
    }

    func testMomentsStaySortedAndPlaylistMatchesProtocol() throws {
        var plan = basePlan
        try plan.setWindow(slotID: "m", from: TimeOfDay(hour: 21, minute: 30), until: TimeOfDay(hour: 1, minute: 0))
        let bday = try plan.addMoment(.asset("happy-bday-3c9a"), at: at(0, 0, day: 1), durationS: 45, title: "Happy birthday", now: now)
        try plan.addMoment(.scene("balls", params: ["palette": .string("candy")]), at: at(22, 0), durationS: 60,
                           transition: .cut, title: "Party", now: now)
        XCTAssertEqual(plan.moments.map(\.title), ["Party", "Happy birthday"])

        let pl = plan.playlist(now: now)
        XCTAssertEqual(pl.items[1].from?.string, "21:30")
        XCTAssertEqual(pl.queue?.map(\.at), [Int(at(22, 0).timeIntervalSince1970), Int(at(0, 0, day: 1).timeIntervalSince1970)])
        XCTAssertEqual(pl.assetIDs, ["sunset-1a2b", "happy-bday-3c9a"])
        let json = try jsonObject(ClipJSON.encoder().encode(pl))
        let expected = try jsonObject("""
        {"version":1,
         "items":[{"type":"asset","id":"sunset-1a2b","duration_ms":10000,"transition":"fade"},
                  {"type":"scene","scene":"snow","duration_ms":30000,"from":"21:30","until":"01:00"}],
         "queue":[{"id":"\(plan.moments[0].id)","at":\(Int(at(22, 0).timeIntervalSince1970)),"type":"scene","scene":"balls",
                   "params":{"palette":"candy"},"duration_ms":60000,"transition":"cut"},
                  {"id":"\(bday.id)","at":\(Int(at(0, 0, day: 1).timeIntervalSince1970)),"type":"asset","asset":"happy-bday-3c9a",
                   "duration_ms":45000,"transition":"fade"}]}
        """)
        XCTAssertEqual(json, expected)
    }

    func testEndedMomentsAreNotSentAndEmptyQueueIsOmitted() throws {
        var plan = basePlan
        try plan.addMoment(.scene("snow", params: [:]), at: at(20, 11), durationS: 60, title: "Soon", now: now)
        XCTAssertEqual(plan.playlist(now: now).queue?.count, 1)
        // Playing: still sent (its id stays done on the clip). Ended: dropped.
        XCTAssertEqual(plan.playlist(now: at(20, 11, 30)).queue?.count, 1)
        XCTAssertNil(plan.playlist(now: at(20, 12)).queue)
        plan.pruneEnded(now: at(20, 12))
        XCTAssertTrue(plan.moments.isEmpty)
        // Editing a past moment is refused.
        var p2 = basePlan
        let m = try p2.addMoment(.scene("snow", params: [:]), at: at(21, 0), durationS: 60, title: "M", now: now)
        XCTAssertThrowsError(try p2.updateMoment(m, now: at(21, 0, 30)))
        var moved = m; moved.at += 600
        XCTAssertNoThrow(try p2.updateMoment(moved, now: now))
        XCTAssertEqual(p2.moments.first?.at, m.at + 600)
    }

    func testOverlapsAndStagger() throws {
        var plan = basePlan
        try plan.addMoment(.scene("snow", params: [:]), at: at(22, 0), durationS: 120, title: "A", now: now)
        try plan.addMoment(.scene("snow", params: [:]), at: at(22, 1), durationS: 60, title: "B", now: now)
        try plan.addMoment(.scene("snow", params: [:]), at: at(22, 1, 30), durationS: 30, title: "C", now: now)
        try plan.addMoment(.scene("snow", params: [:]), at: at(23, 0), durationS: 30, title: "D", now: now)
        XCTAssertEqual(plan.overlaps().map { "\($0.earlier.title)>\($0.later.title)" }, ["A>B", "A>C"])
        XCTAssertTrue(plan.issues(now: now, clock: .synced(at: nil)).contains { if case .overlap = $0.kind { true } else { false } })

        XCTAssertEqual(plan.stagger(now: now), 2)
        XCTAssertEqual(plan.moments.map { local.string($0.start, seconds: true) }, ["22:00", "22:02", "22:03", "23:00"])
        XCTAssertTrue(plan.overlaps().isEmpty)
        XCTAssertFalse(plan.issues(now: now, clock: .synced(at: nil)).contains { if case .overlap = $0.kind { true } else { false } })

        // A moment that has already started is never moved.
        var p2 = basePlan
        try p2.addMoment(.scene("snow", params: [:]), at: at(20, 11), durationS: 120, title: "Now", now: now)
        try p2.addMoment(.scene("snow", params: [:]), at: at(20, 12), durationS: 60, title: "Next", now: now)
        XCTAssertEqual(p2.stagger(now: at(20, 12, 30)), 0)
        XCTAssertEqual(p2.stagger(now: now), 1)
        XCTAssertEqual(local.string(p2.moments[1].start), "20:13")
    }

    // MARK: Windows & rotation

    func testWindowsCrossMidnightAndEmptyWindowIsRefused() throws {
        var plan = basePlan
        try plan.setWindow(slotID: "m", from: TimeOfDay(hour: 21, minute: 30), until: TimeOfDay(hour: 1, minute: 0))
        let snow = plan.slots[1]
        XCTAssertEqual(snow.windowText, "21:30–01:00")
        XCTAssertTrue(snow.item.isActive(atMinuteOfDay: 23 * 60))
        XCTAssertTrue(snow.item.isActive(atMinuteOfDay: 30))
        XCTAssertFalse(snow.item.isActive(atMinuteOfDay: 60))
        XCTAssertFalse(snow.item.isActive(atMinuteOfDay: 21 * 60 + 29))
        XCTAssertEqual(snow.activeMinutesPerDay, 210)

        XCTAssertThrowsError(try plan.setWindow(slotID: "m", from: TimeOfDay(hour: 9, minute: 0), until: TimeOfDay(hour: 9, minute: 0))) {
            XCTAssertEqual($0 as? PlanError, .emptyWindow)
        }
        XCTAssertThrowsError(try plan.setWindow(slotID: "nope", from: nil, until: nil)) { XCTAssertEqual($0 as? PlanError, .unknownSlot) }
        try plan.setWindow(slotID: "a", from: TimeOfDay(hour: 18, minute: 0), until: nil)
        XCTAssertEqual(plan.slots[0].windowText, "after 18:00")
        try plan.setWindow(slotID: "a", from: nil, until: TimeOfDay(hour: 2, minute: 0))
        XCTAssertEqual(plan.slots[0].windowText, "until 02:00")
        plan.clearWindow(slotID: "a")
        XCTAssertNil(plan.slots[0].windowText)
    }

    func testReorderAndDeleteSlots() {
        var plan = TonightPlan(slots: ["a", "b", "c", "d"].map { slot($0, .asset($0, durationMs: 1000), $0.uppercased()) })
        plan.moveSlots(fromOffsets: [0], toOffset: 3)
        XCTAssertEqual(plan.slots.map(\.id), ["b", "c", "a", "d"])
        plan.moveSlots(fromOffsets: [3], toOffset: 0)
        XCTAssertEqual(plan.slots.map(\.id), ["d", "b", "c", "a"])
        plan.moveSlots(fromOffsets: [0, 2], toOffset: 4)
        XCTAssertEqual(plan.slots.map(\.id), ["b", "a", "d", "c"])
        plan.deleteSlot(id: "a")
        XCTAssertEqual(plan.slots.map(\.id), ["b", "d", "c"])
    }

    func testIssues() throws {
        var plan = basePlan
        XCTAssertTrue(plan.issues(now: now, clock: .unsynced).isEmpty, "no moments: an unsynced clock doesn't matter")
        try plan.addMoment(.scene("snow", params: [:]), at: at(21, 0), durationS: 60, title: "M", now: now)
        XCTAssertEqual(plan.issues(now: now, clock: .unsynced).map(\.kind), [.clockNotSynced])
        XCTAssertEqual(plan.issues(now: now, clock: .unknown).map(\.kind), [.clockUnknown])
        XCTAssertTrue(plan.issues(now: now, clock: .synced(at: now)).isEmpty)
        // Windows that leave hours uncovered → idle-screen info.
        try plan.setWindow(slotID: "a", from: TimeOfDay(hour: 18, minute: 0), until: TimeOfDay(hour: 23, minute: 0))
        try plan.setWindow(slotID: "m", from: TimeOfDay(hour: 21, minute: 30), until: TimeOfDay(hour: 1, minute: 0))
        XCTAssertEqual(plan.issues(now: now, clock: .synced(at: now)).map(\.kind), [.idleGap])
        // Past moments are reported as info only; the plan can still be sent.
        XCTAssertTrue(plan.issues(now: at(22, 0), clock: .synced(at: now)).contains { $0.kind == .past(plan.moments[0].id) })
        XCTAssertTrue(plan.canSend(now: now))
        // An empty window slipped in from elsewhere blocks sending.
        plan.slots[0].item.from = TimeOfDay(hour: 9, minute: 0)
        plan.slots[0].item.until = TimeOfDay(hour: 9, minute: 0)
        XCTAssertFalse(plan.canSend(now: now))
    }

    // MARK: Projection

    func testProjectionHourByHourWithCrossMidnightWindow() throws {
        var plan = basePlan
        try plan.setWindow(slotID: "m", from: TimeOfDay(hour: 21, minute: 30), until: TimeOfDay(hour: 1, minute: 0))
        try plan.setWindow(slotID: "a", from: nil, until: TimeOfDay(hour: 23, minute: 0))
        let p = TimelineProjection.project(plan.playlist(now: now), now: now, clock: .synced(at: now), local: local)

        XCTAssertEqual(p.hours.first?.label, "20:00")
        XCTAssertEqual(p.hours.last?.label, "08:00")
        XCTAssertEqual(p.hours.count, 13)
        func row(_ label: String) -> TimelineProjection.Hour { p.hours.first { $0.label == label }! }
        XCTAssertEqual(row("20:00").activeItems, [0]); XCTAssertEqual(row("20:00").fullItems, [0])
        XCTAssertEqual(row("21:00").activeItems, [0, 1]); XCTAssertEqual(row("21:00").fullItems, [0])
        XCTAssertEqual(row("22:00").fullItems, [0, 1])
        XCTAssertEqual(row("23:00").activeItems, [1]); XCTAssertEqual(row("23:00").idleMinutes, 0)
        // "until 23:00" with no start = 00:00–23:00, so the asset is back after midnight.
        XCTAssertEqual(row("00:00").fullItems, [0, 1])
        XCTAssertEqual(row("01:00").activeItems, [0]); XCTAssertEqual(row("01:00").idleMinutes, 0)

        // Spans: the asset until 23:00, the scene 21:30 → 01:00 across midnight; the asset again from 00:00.
        let snow = p.spans.filter { $0.itemIndex == 1 }
        XCTAssertEqual(snow.count, 1)
        XCTAssertEqual(snow[0].start, at(21, 30)); XCTAssertEqual(snow[0].end, at(1, 0, day: 1))
        let asset = p.spans.filter { $0.itemIndex == 0 }
        XCTAssertEqual(asset.map(\.start), [at(20, 0), at(0, 0, day: 1)])
        XCTAssertEqual(asset.first?.end, at(23, 0))

        XCTAssertEqual(p.showing(at: at(22, 0), items: plan.slots.map(\.item)), .rotation([0, 1]))
        XCTAssertEqual(p.showing(at: at(3, 0, day: 1), items: plan.slots.map(\.item)), .rotation([0]))
        XCTAssertEqual(p.showing(at: at(23, 30), items: plan.slots.map(\.item)), .rotation([1]))
        try plan.setWindow(slotID: "a", from: TimeOfDay(hour: 20, minute: 0), until: TimeOfDay(hour: 23, minute: 0))
        let p2 = TimelineProjection.project(plan.playlist(now: now), now: now, clock: .synced(at: now), local: local)
        XCTAssertEqual(p2.showing(at: at(3, 0, day: 1), items: plan.slots.map(\.item)), .idle)
        XCTAssertEqual(p2.hours.first { $0.label == "03:00" }?.idleMinutes, 60)
        XCTAssertEqual(p2.hours.first { $0.label == "01:00" }?.activeItems, [])
    }

    func testProjectionMomentsFollowFirmwareQueueRules() throws {
        var plan = basePlan
        try plan.addMoment(.scene("snow", params: [:]), at: at(22, 0), durationS: 900, title: "Long", now: now)          // 22:00–22:15
        try plan.addMoment(.scene("snow", params: [:]), at: at(22, 1), durationS: 60, title: "Covered", now: now)        // would start 14 min late → skipped
        try plan.addMoment(.scene("snow", params: [:]), at: at(22, 10), durationS: 60, title: "Waits", now: now)         // starts 22:15 (5 min late), full minute
        try plan.addMoment(.asset("bday"), at: at(0, 0, day: 1), durationS: 45, title: "Bday", now: now)
        let ids = Dictionary(uniqueKeysWithValues: plan.moments.map { ($0.title, $0.id) })
        let p = TimelineProjection.project(plan.playlist(now: now), now: now, clock: .synced(at: now), local: local)
        let fate = Dictionary(uniqueKeysWithValues: p.moments.map { ($0.id, $0) })

        XCTAssertEqual(fate[ids["Long"]!]?.fate, .onTime)
        XCTAssertEqual(fate[ids["Covered"]!]?.fate, .skipped(after: ids["Long"]!))
        XCTAssertEqual(fate[ids["Waits"]!]?.fate, .delayed(seconds: 300, after: ids["Long"]!))
        XCTAssertEqual(fate[ids["Waits"]!]?.start, at(22, 15))
        XCTAssertEqual(fate[ids["Waits"]!]?.end, at(22, 16))
        XCTAssertEqual(fate[ids["Bday"]!]?.fate, .onTime)
        XCTAssertEqual(p.hours.first { $0.label == "22:00" }?.moments.count, 3)
        XCTAssertEqual(p.hours.first { $0.label == "00:00" }?.moments.map(\.id), [ids["Bday"]!])
        XCTAssertEqual(p.upcoming.count, 4, "planned moments still ahead, including the one the clip will skip")
        XCTAssertEqual(p.showing(at: at(22, 15, 30), items: plan.slots.map(\.item)), .moment(ids["Waits"]!))
        XCTAssertEqual(p.showing(at: at(22, 5), items: plan.slots.map(\.item)), .moment(ids["Long"]!))

        // Later: one playing, earlier ones past.
        let later = TimelineProjection.project(plan.playlist(now: now), now: at(22, 15, 10), clock: .synced(at: now), local: local)
        XCTAssertEqual(later.moments.first { $0.id == ids["Long"]! }?.fate, .past)
        XCTAssertEqual(later.moments.first { $0.id == ids["Waits"]! }?.fate, .playingNow)
    }

    func testUnsyncedClockMeansNothingFires() throws {
        var plan = basePlan
        try plan.addMoment(.scene("snow", params: [:]), at: at(21, 0), durationS: 60, title: "A", now: now)
        try plan.addMoment(.scene("snow", params: [:]), at: at(21, 0, 30), durationS: 60, title: "B", now: now)
        let p = TimelineProjection.project(plan.playlist(now: now), now: now, clock: .unsynced, local: local)
        XCTAssertEqual(p.moments.map(\.fate), [.wontFireClockNotSet, .wontFireClockNotSet])
        XCTAssertEqual(p.moments.map(\.start), plan.moments.map(\.start))
        XCTAssertFalse(p.moments.contains { $0.fate.fires })
        XCTAssertEqual(p.showing(at: at(21, 0, 10), items: plan.slots.map(\.item)), .rotation([0, 1]))
        XCTAssertEqual(TonightSummary.clockText(.unsynced, now: now), "clock not set")

        let unknown = TimelineProjection.project(plan.playlist(now: now), now: now, clock: .unknown, local: local)
        XCTAssertEqual(unknown.moments.first?.fate, .needsClockCheck)

        let status = ClipStatus(device: .init(name: "PixelClip", id: "7c1e", fw: "x", hw: "x", protocolVersion: 1), battery: nil,
                                storage: .init(total: 1, used: 0, free: 1), playlist: .init(count: 0, index: -1, current: nil),
                                time: .init(epoch: 0, tzOffsetS: 0, synced: false), session: nil, uptimeS: 0)
        XCTAssertEqual(ClipClock(status: status, lastSetAt: nil), .unsynced)
        XCTAssertEqual(ClipClock(status: nil, lastSetAt: nil), .unknown)
        var synced = status; synced.time.synced = true
        XCTAssertEqual(ClipClock(status: synced, lastSetAt: now), .synced(at: now))
    }

    /// The projection agrees with the PlaybackEngine (which drives the virtual clip) on which rotation
    /// items are eligible and when a non-overlapping moment is on screen.
    func testProjectionAgreesWithPlaybackEngine() throws {
        var plan = basePlan
        try plan.setWindow(slotID: "m", from: TimeOfDay(hour: 21, minute: 30), until: TimeOfDay(hour: 1, minute: 0))
        try plan.setWindow(slotID: "a", from: TimeOfDay(hour: 20, minute: 0), until: TimeOfDay(hour: 22, minute: 0))
        try plan.addMoment(.scene("snow", params: [:]), at: at(23, 0), durationS: 60, title: "M", now: now)
        try plan.addMoment(.scene("sand", params: [:]), at: at(0, 0, day: 1), durationS: 30, title: "S", now: now)
        let pl = plan.playlist(now: now)
        let p = TimelineProjection.project(pl, now: now, clock: .synced(at: now), local: local)
        var engine = PlaybackEngine(now: now)
        engine.tzOffsetS = tz
        engine.clockSynced = true
        engine.setPlaylist(pl, now: now)
        let timing: (String) -> PlaybackEngine.AssetTiming? = { _ in .init(frameDurationsMs: [100]) }
        var t = now
        while t < p.end {
            let st = engine.state(at: t, timing: timing)
            switch p.showing(at: t, items: pl.items) {
            case .moment(let id): XCTAssertEqual(st.queueID, id, "\(local.string(t))")
            case .idle: XCTAssertEqual(st.content, .idle, "\(local.string(t))")
            case .rotation(let active):
                XCTAssertNil(st.queueID, "\(local.string(t))")
                let idx = try XCTUnwrap(st.playlistIndex, "\(local.string(t))")
                XCTAssertTrue(active.contains(idx), "\(local.string(t)): engine shows \(idx), projection \(active)")
            }
            t.addTimeInterval(20)
        }
    }

    // MARK: Summary & reminders

    func testSummaryLine() throws {
        var plan = basePlan
        try plan.setWindow(slotID: "m", from: TimeOfDay(hour: 21, minute: 30), until: nil)
        try plan.addMoment(.asset("bday"), at: at(0, 0, day: 1), durationS: 45, title: "Happy birthday", now: now)
        try plan.addMoment(.scene("balls", params: [:]), at: at(22, 0), durationS: 60, title: "Party", now: now)
        try plan.addMoment(.scene("snow", params: [:]), at: at(23, 0), durationS: 60, title: "Snow", now: now)
        let p = TimelineProjection.project(plan.playlist(now: now), now: now, clock: .synced(at: now.addingTimeInterval(-150)), local: local)
        XCTAssertEqual(TonightSummary.line(plan: plan, projection: p, now: now),
                       "3 moments tonight · Snow after 21:30 · clock synced 2 min ago")
        // With several windows the first slot's leads.
        try plan.setWindow(slotID: "a", from: nil, until: TimeOfDay(hour: 23, minute: 0))
        XCTAssertEqual(TonightSummary.parts(plan: plan, projection: p, now: now)[1], "Golden Hour until 23:00 (+1 more)")
        let empty = TimelineProjection.project(basePlan.playlist(now: now), now: now, clock: .unknown, local: local)
        XCTAssertEqual(TonightSummary.line(plan: basePlan, projection: empty, now: now), "No moments yet · clock not checked")
        XCTAssertEqual(TonightSummary.relative(now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertEqual(TonightSummary.relative(now.addingTimeInterval(-7300), now: now), "2 h ago")
        XCTAssertEqual(TonightSummary.duration(90), "1 min 30 s")
        XCTAssertEqual(TonightSummary.duration(45), "45 s")
    }

    func testRemindersFireFiveMinutesBefore() throws {
        var plan = basePlan
        try plan.addMoment(.asset("bday"), at: at(0, 0, day: 1), durationS: 45, title: "Happy birthday", now: now)
        try plan.addMoment(.scene("snow", params: [:]), at: at(20, 13), durationS: 60, title: "Too soon", now: now)
        let phone = TimeZone(secondsFromGMT: tz)!
        let r = MomentReminders.plan(plan.moments, deviceName: "PixelClip", timeZone: phone, now: now)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].fireAt, at(23, 55))
        XCTAssertEqual(r[0].body, "PixelClip will show “Happy birthday” at 00:00.")
        XCTAssertTrue(r[0].id.hasPrefix(MomentReminders.idPrefix))
        // Formatted in the phone's zone, not the clip's.
        let ny = MomentReminders.plan(plan.moments, deviceName: "PixelClip", timeZone: TimeZone(secondsFromGMT: -4 * 3600)!, now: now)
        XCTAssertEqual(ny.first?.body, "PixelClip will show “Happy birthday” at 18:00.")
    }

    func testMomentIDs() {
        var rng = SeededRNG(7)
        var seen = Set<String>()
        for i in 0..<500 {
            let id = Moment.makeID(at: 1_791_583_200 + i % 3, existing: seen, using: &rng)
            XCTAssertTrue(Moment.isValidID(id), id)
            XCTAssertTrue(seen.insert(id).inserted)
        }
        XCTAssertFalse(Moment.isValidID(""))
        XCTAssertFalse(Moment.isValidID("has space"))
        XCTAssertFalse(Moment.isValidID(String(repeating: "x", count: 41)))
        XCTAssertFalse(Moment.isValidID("quote\"d"))
    }
}
