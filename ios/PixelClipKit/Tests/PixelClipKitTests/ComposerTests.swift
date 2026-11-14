import XCTest
@testable import PixelClipKit

/// One sender: every Send and Tonight's Send PUT the composer's document — Now
/// first, then Tonight's rotation items, moments as the queue — so whichever goes last keeps what
/// the others put there.
final class ComposerTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_791_655_200)   // 2026-10-10 20:00 at UTC+2

    /// Now: a still, timed for rotating (10 s, fade).
    let photo = RotationSlot(id: NowItem.slotID, item: .asset("photo-1", durationMs: 10_000), title: "Photo")

    /// Tonight: an animation until 23:00, a live scene whenever, a moment with the animation and one scene moment.
    func tonightLayer() -> TonightLayer {
        TonightLayer(windows: ["x-anim": .init(from: nil, until: TimeOfDay(hour: 23, minute: 0))],
                     extras: [.init(id: "x-anim", item: .asset("anim-1", durationMs: 0, loops: 2), title: "Anim"),
                              .init(id: "x-sand", item: .scene("sand", params: ["palette": .string("amber")], durationMs: 20_000), title: "Sand")],
                     order: ["x-sand", "x-anim"],
                     moments: [Moment(id: "t-1", at: Int(base.timeIntervalSince1970) + 600, content: .asset("anim-1"), durationS: 45, title: "Anim"),
                               Moment(id: "t-2", at: Int(base.timeIntervalSince1970) + 1200, content: .scene("balls", params: [:]), durationS: 60, title: "Balls")])
    }

    func testNowAloneIsHeldIndefinitely() throws {
        let pl = PlaylistComposer.playlist(.init(now: photo), now: base)
        XCTAssertEqual(pl.items, [PlaylistItem(type: .asset, id: "photo-1", durationMs: 0)])
        XCTAssertNil(pl.queue)
        // Wire format: no transition, duration 0, no queue key.
        XCTAssertEqual(try jsonObject(ClipJSON.encoder().encode(pl)),
                       try jsonObject(#"{"version":1,"items":[{"type":"asset","id":"photo-1","duration_ms":0}]}"#))

        // A strip as Now: its scroll without a pass count (the firmware scrolls a lone strip endlessly).
        let scroll = PlaylistItem.Scroll(pxPerS: 90, direction: .left, gapPx: 120, loops: 2)
        let strip = RotationSlot(id: NowItem.slotID, item: PlaylistItem(type: .asset, id: "marquee", durationMs: 0, transition: .fade, scroll: scroll), title: "Hi")
        let s = PlaylistComposer.playlist(.init(now: strip), now: base).items[0]
        XCTAssertEqual(s.scroll, PlaylistItem.Scroll(pxPerS: 90, direction: .left, gapPx: 120))
        XCTAssertEqual(s.durationMs, 0)
        XCTAssertNil(s.transition)

        // Moments alone don't stop Now from being held.
        var layer = TonightLayer.empty
        layer.moments = tonightLayer().moments
        let withMoments = PlaylistComposer.playlist(.init(now: photo, tonight: layer), now: base)
        XCTAssertEqual(withMoments.items.count, 1)
        XCTAssertEqual(withMoments.items[0].durationMs, 0)
        XCTAssertEqual(withMoments.queue?.map(\.id), ["t-1", "t-2"])
    }

    func testSceneAsNow() {
        let now = NowItem(content: .scene("snow", params: SceneLook.params(scene: "snow", palette: nil)), title: "Snow · mono")
        let slot = now.slot { _ in nil }
        XCTAssertEqual(slot?.item.type, .scene)
        let pl = PlaylistComposer.playlist(.init(now: slot), now: base)
        XCTAssertEqual(pl.items, [PlaylistItem(type: .scene, durationMs: 0, scene: "snow", params: ["palette": .string("mono")])])
        XCTAssertTrue(pl.assetIDs.isEmpty, "a scene needs no upload")
        // Readings too; a picture that's gone from the library drops out.
        XCTAssertEqual(NowItem(content: .reader(text: "t", font: "f", wpm: 300), title: "R").slot { _ in nil }?.item.text, "t")
        XCTAssertNil(NowItem(content: .asset("gone"), title: "Gone").slot { _ in nil })
    }

    func testComposerPutsNowFirstThenTonight() {
        var inputs = PlaylistComposer.Inputs(now: photo, tonight: tonightLayer())
        let pl = PlaylistComposer.playlist(inputs, now: base)
        XCTAssertEqual(pl.items.map(\.type), [.asset, .scene, .asset], "Now, then Tonight's order")
        XCTAssertEqual(pl.items[0], .asset("photo-1", durationMs: 10_000), "next to Tonight's items Now keeps its rotation timing")
        XCTAssertNil(pl.items[0].until)
        XCTAssertEqual(pl.items[2].until, TimeOfDay(hour: 23, minute: 0))
        XCTAssertEqual(pl.items[2].loops, 2)
        XCTAssertEqual(pl.queue?.map(\.id), ["t-1", "t-2"])

        // Moments that ended are left out of the document, not out of the fingerprint.
        let later = PlaylistComposer.playlist(inputs, now: base + 700)
        XCTAssertEqual(later.queue?.map(\.id), ["t-2"])
        XCTAssertEqual(PlaylistComposer.fingerprint(inputs) { _ in "x" }, PlaylistComposer.fingerprint(inputs) { _ in "x" })

        // Strip assets get their scroll block in the rotation and in moments.
        let scroll = PlaylistItem.Scroll(pxPerS: 80, direction: .left, gapPx: 120)
        inputs.scrolls = ["anim-1": scroll]
        let withScroll = PlaylistComposer.playlist(inputs, now: base)
        XCTAssertEqual(withScroll.items.first { $0.id == "anim-1" }?.scroll, scroll)
        XCTAssertEqual(withScroll.queue?.first { $0.asset == "anim-1" }?.scroll, scroll)

        // Tonight's rotation item showing what Now shows is left out (it would play twice).
        var dup = tonightLayer()
        dup.extras.append(.init(id: "x-photo", item: .asset("photo-1", durationMs: 10_000), title: "Photo"))
        XCTAssertEqual(PlaylistComposer.playlist(.init(now: photo, tonight: dup), now: base).items.filter { $0.id == "photo-1" }.count, 1)

        // Without Now: only Tonight's items (and the idle-gap notice can apply again).
        XCTAssertEqual(PlaylistComposer.playlist(.init(tonight: tonightLayer()), now: base).items.count, 2)
        XCTAssertFalse(PlaylistComposer.plan(.init(now: photo, tonight: tonightLayer())).issues(now: base, clock: .synced(at: base))
            .contains { $0.kind == .idleGap }, "Now is on all day")
    }

    func testMigrationKeepsEverything() {
        let lib = [RotationSlot(id: "e-photo", item: .asset("photo-1", durationMs: 10_000), title: "Photo"),
                   RotationSlot(id: "e-anim", item: .asset("anim-1", durationMs: 0, loops: 2), title: "Anim")]
        let old = TonightLayer(windows: ["e-photo": .init(from: nil, until: TimeOfDay(hour: 23, minute: 0))],
                               extras: [.init(id: "x-sand", item: .scene("sand", params: [:], durationMs: 20_000), title: "Sand")],
                               order: ["e-photo", "x-sand", "e-anim"],
                               moments: tonightLayer().moments)
        let r = NowMigration.migrate(library: lib, tonight: old)
        // The photo has a window, so the first item without one (the scene) becomes Now.
        XCTAssertEqual(r.now, NowItem(content: .scene("sand", params: [:]), title: "Sand"))
        XCTAssertEqual(r.moved, 2)
        XCTAssertEqual(r.tonight.order, ["e-photo", "e-anim"])
        XCTAssertEqual(r.tonight.windows["e-photo"]?.until, TimeOfDay(hour: 23, minute: 0))
        XCTAssertNil(r.tonight.windows["e-anim"], "no window: whenever")
        XCTAssertEqual(r.tonight.moments, old.moments)
        XCTAssertEqual(r.tonight.extras.first { $0.id == "e-anim" }?.item.loops, 2)

        // The composed document still has all three items and both moments.
        let now = r.now?.slot { _ in nil }
        let pl = PlaylistComposer.playlist(.init(now: now, tonight: r.tonight), now: base)
        XCTAssertEqual(pl.items.map(\.type), [.scene, .asset, .asset])
        XCTAssertEqual(pl.queue?.count, 2)

        // A plain one-item playlist: Now, nothing moved.
        let one = NowMigration.migrate(library: [lib[1]], tonight: .empty)
        XCTAssertEqual(one.now?.content, .asset("anim-1"))
        XCTAssertEqual(one.moved, 0)
        XCTAssertTrue(one.tonight.extras.isEmpty)
        XCTAssertNil(NowMigration.migrate(library: [], tonight: .empty).now)
    }

    func testPlanRemovals() throws {
        var plan = PlaylistComposer.plan(.init(now: photo, tonight: tonightLayer()))
        // Delete a moment and undo it.
        let gone = try XCTUnwrap(plan.deleteMoment(id: "t-1"))
        XCTAssertEqual(plan.moments.map(\.id), ["t-2"])
        XCTAssertNil(plan.deleteMoment(id: "t-1"))
        plan.restoreMoment(gone)
        plan.restoreMoment(gone)
        XCTAssertEqual(plan.moments.map(\.id), ["t-1", "t-2"], "restored in time order, once")
        // Remove a rotation item; clear a window.
        XCTAssertEqual(plan.deleteSlot(id: "x-sand")?.title, "Sand")
        XCTAssertNil(plan.deleteSlot(id: "x-sand"))
        plan.clearWindow(slotID: "x-anim")
        XCTAssertFalse(plan.slots[0].hasWindow)
        // Clear tonight: everything but Now.
        XCTAssertFalse(plan.isTonightEmpty(now: base))
        let cleared = plan.clearTonight()
        XCTAssertEqual(cleared.slots, 1)
        XCTAssertEqual(cleared.moments, 2)
        XCTAssertTrue(plan.isTonightEmpty(now: base))
        XCTAssertEqual(plan.playlist(now: base).items, [PlaylistItem(type: .asset, id: "photo-1", durationMs: 0)])
        XCTAssertTrue(TonightLayer(moments: [Moment(id: "old", at: 10, content: .scene("snow", params: [:]), durationS: 60, title: "M")]).isEmpty(now: base),
                      "a moment that ended doesn't count")
    }
}
