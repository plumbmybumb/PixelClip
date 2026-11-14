import XCTest
@testable import PixelClipKit

/// PixelClip's playlist (docs/DESIGN.md "Playlist"): untimed entries rotate a minute each while it's on,
/// timed entries are one-off queue entries either way, Now holds when it's off; and the one-time
/// migration from Tonight.
final class PlaylistScheduleTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_791_655_200)   // 2026-10-10 20:00 at UTC+2

    /// Library pictures: a still (10 s rotation timing), a long animation (2 loops), a strip (2 passes).
    func asset(_ id: String) -> PlaylistItem? {
        switch id {
        case "photo": .asset("photo", durationMs: 10_000)
        case "anim": .asset("anim", durationMs: 0, loops: 2)
        case "strip": PlaylistItem(type: .asset, id: "strip", durationMs: 0, transition: .fade,
                                   scroll: .init(pxPerS: 90, direction: .left, gapPx: 120, loops: 2))
        default: nil
        }
    }

    var entries: [PlaylistEntry] {
        [PlaylistEntry(id: "p-1", content: .asset("anim"), name: "Anim"),
         PlaylistEntry(id: "p-2", content: .scene("sand", params: ["palette": .string("amber")]), name: "Sand"),
         PlaylistEntry(id: "p-3", content: .asset("strip"), name: "Hello"),
         PlaylistEntry(id: "p-4", content: .scene("snow", params: [:]), name: "Snow"),
         PlaylistEntry(id: "p-5", content: .asset("photo"), at: base.addingTimeInterval(5400), name: "Birthday"),
         PlaylistEntry(id: "p-6", content: .asset("gone"), name: "Deleted")]
    }

    func testOnRotatesUntimedEntriesAMinuteEachInOrder() {
        let pl = PlaylistComposer.playlist(PlaylistSchedule.inputs(now: nil, entries: entries, isOn: true, asset: asset), now: base)
        XCTAssertEqual(pl.items.map(\.type), [.asset, .scene, .asset, .scene])
        XCTAssertEqual(pl.items.map(\.id), ["anim", nil, "strip", nil])
        for item in pl.items {
            XCTAssertEqual(item.durationMs, 60_000)
            XCTAssertEqual(item.transition, .fade)
            XCTAssertNil(item.loops)
            XCTAssertNil(item.from)
            XCTAssertNil(item.until)
        }
        // The strip keeps its scroll, without a pass count (duration wins).
        XCTAssertEqual(pl.items[2].scroll, .init(pxPerS: 90, direction: .left, gapPx: 120))
        // The timed one is a one-off queue entry, a minute, not in the rotation.
        XCTAssertEqual(pl.queue?.count, 1)
        let q = pl.queue![0]
        XCTAssertEqual(q.asset, "photo")
        XCTAssertEqual(q.at, Int(base.timeIntervalSince1970) + 5400)
        XCTAssertEqual(q.durationMs, 60_000)
        XCTAssertEqual(q.transition, .fade)
        XCTAssertTrue(Moment.isValidID(q.id))
        XCTAssertFalse(pl.items.contains { $0.id == "photo" })
    }

    func testNowPlaysFirstForAMinuteWhenThePlaylistIsOn() {
        let now = NowItem(content: .asset("photo"), title: "Photo")
        let pl = PlaylistComposer.playlist(PlaylistSchedule.inputs(now: now, entries: entries, isOn: true, asset: asset), now: base)
        XCTAssertEqual(pl.items.first?.id, "photo")
        XCTAssertEqual(pl.items.first?.durationMs, 60_000)
        XCTAssertEqual(pl.items.count, 5)
        // An entry showing what Now shows isn't played twice.
        let dup = PlaylistComposer.playlist(PlaylistSchedule.inputs(now: NowItem(content: .asset("anim"), title: "Anim"),
                                                                    entries: entries, isOn: true, asset: asset), now: base)
        XCTAssertEqual(dup.items.compactMap(\.id).filter { $0 == "anim" }.count, 1)
        XCTAssertEqual(dup.items.count, 4)
    }

    func testOffHoldsNowAndTimedEntriesStillFire() {
        let now = NowItem(content: .asset("photo"), title: "Photo")
        let pl = PlaylistComposer.playlist(PlaylistSchedule.inputs(now: now, entries: entries, isOn: false, asset: asset), now: base)
        XCTAssertEqual(pl.items, [PlaylistItem(type: .asset, id: "photo", durationMs: 0)])
        XCTAssertEqual(pl.queue?.map(\.asset), ["photo"])
        // On, but nothing untimed: Now still holds.
        let timedOnly = entries.filter(\.isTimed)
        let held = PlaylistComposer.playlist(PlaylistSchedule.inputs(now: now, entries: timedOnly, isOn: true, asset: asset), now: base)
        XCTAssertEqual(held.items[0].durationMs, 0)
        // A timed entry that has played drops out of the queue.
        let later = PlaylistComposer.playlist(PlaylistSchedule.inputs(now: now, entries: entries, isOn: false, asset: asset),
                                              now: base.addingTimeInterval(5400 + 61))
        XCTAssertNil(later.queue)
    }

    func testQueueIDChangesWithTheTimeAndStaysValid() {
        var e = PlaylistEntry(id: "p-0123abcd", content: .scene("snow", params: [:]), at: base, name: "Snow")
        let first = e.queueID
        e.at = base.addingTimeInterval(60)
        XCTAssertNotEqual(first, e.queueID)
        XCTAssertNil(PlaylistEntry(content: .scene("snow", params: [:]), name: "x").queueID)
        let long = PlaylistEntry(id: String(repeating: "é\"x", count: 30), content: .scene("snow", params: [:]), at: base, name: "x")
        XCTAssertTrue(Moment.isValidID(long.queueID!))
        XCTAssertTrue(PlaylistEntry.makeID().hasPrefix("p-"))
        XCTAssertEqual(PlaylistEntry.makeID().count, 10)
        XCTAssertTrue(e.isPast(now: base.addingTimeInterval(61)))
        XCTAssertFalse(e.isPast(now: base))
    }

    func testEntriesRoundTripThroughJSON() throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode([PlaylistEntry].self, from: enc.encode(entries))
        XCTAssertEqual(back, entries)
    }

    func testUpcomingTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 7200)!
        let at2130 = PlaylistSchedule.upcoming(hour: 21, minute: 30, after: base, calendar: cal)
        XCTAssertEqual(at2130.timeIntervalSince(base), 5400)
        let at1900 = PlaylistSchedule.upcoming(hour: 19, minute: 0, after: base, calendar: cal)
        XCTAssertEqual(at1900.timeIntervalSince(base), 23 * 3600)
    }

    func testMigratesTonightOnce() {
        let layer = TonightLayer(
            windows: ["x-anim": .init(from: nil, until: TimeOfDay(hour: 23, minute: 0))],
            extras: [.init(id: "x-anim", item: .asset("anim", durationMs: 0, loops: 2), title: "Anim"),
                     .init(id: "x-sand", item: .scene("sand", params: ["palette": .string("amber")], durationMs: 20_000), title: "Sand"),
                     .init(id: "x-fire", item: .scene("fire", durationMs: 30_000), title: "Fire")],
            order: ["x-sand", "x-anim", "x-fire"],
            moments: [Moment(id: "t-2", at: Int(base.timeIntervalSince1970) + 1200, content: .scene("balls", params: [:]), durationS: 60, title: "Balls"),
                      Moment(id: "t-1", at: Int(base.timeIntervalSince1970) + 600, content: .asset("photo"), durationS: 45, title: "Photo"),
                      Moment(id: "t-0", at: Int(base.timeIntervalSince1970) - 600, content: .scene("snow", params: [:]), durationS: 60, title: "Over")])
        let out = PlaylistMigration.entries(from: layer, now: base)
        XCTAssertEqual(out.map(\.name), ["Sand", "Anim", "Fire", "Photo", "Balls"])
        XCTAssertEqual(out.map(\.isTimed), [false, false, false, true, true])
        XCTAssertEqual(out[0].content, .scene("sand", params: ["palette": .string("amber")]))
        XCTAssertEqual(out[1].content, .asset("anim"))
        XCTAssertEqual(out[2].content, .scene("fire", params: [:]))
        XCTAssertEqual(out[3].at, base.addingTimeInterval(600))
        XCTAssertEqual(Set(out.map(\.id)).count, out.count)
        XCTAssertTrue(PlaylistMigration.entries(from: .empty, now: base).isEmpty)

        let legacy = PlaylistMigration.entries(fromLegacy: [RotationSlot(id: "a", item: .asset("photo", durationMs: 10_000), title: "Photo"),
                                                            RotationSlot(id: "b", item: PlaylistItem(type: .clock, durationMs: 0), title: "Clock")])
        XCTAssertEqual(legacy.map(\.content), [.asset("photo")])
    }

    /// How Home matches `/status.playlist.current` to Now or a playlist entry.
    func testClipCurrentIDNamesWhatTheStatusReports() {
        XCTAssertEqual(MomentContent.asset("pic-1").clipCurrentID, "pic-1")
        XCTAssertEqual(MomentContent.scene("fire", params: [:]).clipCurrentID, "scene:fire")
        XCTAssertEqual(MomentContent.reader(text: "text-1", font: "f", wpm: 300).clipCurrentID, "reader:text-1")
        XCTAssertEqual(MomentContent.oracle(OracleItem(id: "tarot-reader-fr-1", deck: "d", keys: "k")).clipCurrentID, "oracle:tarot-reader-fr-1")
        // The same strings the virtual clip reports while each plays.
        XCTAssertEqual(PlaylistItem.asset("pic-1", durationMs: 0).id, "pic-1")
    }
}
