import XCTest
@testable import PixelClipKit

// MARK: - The join retry loop, the overlap with the wake, the remembered network

@MainActor
final class JoinLoopTests: XCTestCase {

    func joiner(_ wifi: FakeClipWiFi, bell: ScriptedDoorbell? = nil, interval: Duration = .milliseconds(10),
                window: Duration = .milliseconds(200)) -> HotspotJoiner {
        HotspotJoiner(configurator: FakeConfigurator(wifi: wifi), probeAttempts: 2, probeInterval: .milliseconds(1),
                      doorbell: bell, joinRetryInterval: interval, wakeJoinWindow: window, probe: { wifi.reachable })
    }

    func testRetriesEveryIntervalUntilTheAccessPointIsUp() async {
        let wifi = FakeClipWiFi()
        let j = joiner(wifi)
        // The access point comes up ~60 ms in: the loop keeps asking every 10 ms meanwhile.
        Task { try? await Task.sleep(for: .milliseconds(60)); wifi.apUp = true }
        let s = await j.join(probeFirst: false, retryFor: .seconds(2))
        XCTAssertEqual(s, .joined)
        XCTAssertGreaterThanOrEqual(wifi.calls, 3, "retried while the network wasn't there")
        XCTAssertEqual(j.joinAttempts, wifi.calls)
    }

    func testGivesUpWhenTheWindowRunsOut() async {
        let wifi = FakeClipWiFi()   // never comes up
        let j = joiner(wifi, interval: .milliseconds(20))
        let started = ContinuousClock.now
        let s = await j.join(probeFirst: false, retryFor: .milliseconds(150))
        let took = ContinuousClock.now - started
        guard case .unreachable = s else { return XCTFail("\(s)") }
        XCTAssertEqual(j.failure, .notFound)
        XCTAssertGreaterThanOrEqual(wifi.calls, 4)
        XCTAssertLessThanOrEqual(wifi.calls, 10, "one attempt per interval, not a busy loop")
        XCTAssertLessThan(took, .milliseconds(800))
    }

    func testOtherErrorsStopTheLoopAtOnce() async {
        let j = HotspotJoiner(configurator: ImmediateHotspotConfigurator(error: .userDenied), joinRetryInterval: .milliseconds(5),
                              probe: { false })
        let s = await j.join(probeFirst: false, retryFor: .seconds(5))
        XCTAssertEqual(s, .notJoined)
        XCTAssertEqual(j.failure, .declined)
        XCTAssertEqual(j.joinAttempts, 1)
    }

    func testJoinStartsWhenTheWakeIsAcknowledged() async {
        // The clip acknowledges the write, then takes 150 ms to confirm session_active over Bluetooth.
        let wifi = FakeClipWiFi()
        let bell = ScriptedDoorbell(.hotspotUp, wifi: wifi, confirmAfter: .milliseconds(150))
        let j = joiner(wifi, bell: bell, window: .seconds(2))
        var joinStarted: ContinuousClock.Instant?
        var outcome: DoorbellOutcome?
        let s = await j.wakeAndJoin(onWake: { outcome = $0 }, onJoinStart: { joinStarted = .now })
        XCTAssertEqual(s, .joined)
        XCTAssertEqual(outcome, .woke)
        let accepted = try? XCTUnwrap(bell.time(of: .accepted))
        let confirmed = try? XCTUnwrap(bell.time(of: .hotspotUp))
        let started = try? XCTUnwrap(joinStarted)
        if let accepted, let confirmed, let started {
            XCTAssertGreaterThanOrEqual(started, accepted)
            XCTAssertLessThan(started, confirmed, "joining began before session_active, not after")
        }
        XCTAssertGreaterThanOrEqual(wifi.calls, 1)
    }

    func testLowBatteryAfterTheWriteCancelsTheJoin() async {
        // Accepted, then the clip reports it refused for low battery: stop, don't keep joining.
        let wifi = FakeClipWiFi()
        let bell = ScriptedDoorbell(script: [(.scanning, .zero), (.waking, .zero), (.accepted, .zero), (.failed(.lowBattery), .milliseconds(60))],
                                    wifi: nil)
        let j = joiner(wifi, bell: bell, interval: .milliseconds(10), window: .seconds(3))
        let s = await j.wakeAndJoin()
        guard case .unreachable = s else { return XCTFail("\(s)") }
        XCTAssertEqual(j.failure, .lowBattery)
        let calls = wifi.calls
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(wifi.calls, calls, "the join loop stopped")
        XCTAssertEqual(j.failure, .lowBattery, "and didn't overwrite the outcome")
    }

    func testRemembersTheNetworkFirst() async {
        let wifi = FakeClipWiFi(apUp: true)
        let j = joiner(wifi)
        XCTAssertNil(j.lastJoinRemembered)
        let s = await j.join(probeFirst: false)
        XCTAssertEqual(s, .joined)
        XCTAssertEqual(wifi.remembers, [true], "joinOnce = false: iOS asks only the first time")
        XCTAssertEqual(j.lastJoinRemembered, true)
        XCTAssertFalse(j.rememberRefused)
    }

    func testFallsBackToJoinOnceWhenRememberingIsRefused() async {
        let wifi = FakeClipWiFi(apUp: true)
        wifi.refuseRemembered = true
        let j = joiner(wifi)
        let s = await j.join(probeFirst: false)
        XCTAssertEqual(s, .joined)
        XCTAssertEqual(wifi.remembers, [true, false], "refused, then join-once at once")
        XCTAssertEqual(j.lastJoinRemembered, false)
        XCTAssertTrue(j.rememberRefused)
        // Later joins go straight to join-once.
        j.markDisconnected()
        _ = await j.join(probeFirst: false)
        XCTAssertEqual(wifi.remembers, [true, false, false])
        // Forget Clip removes the configuration and tries remembering again next time.
        await j.forgetNetwork()
        XCTAssertEqual(wifi.forgotten, 1)
        XCTAssertFalse(j.rememberRefused)
        XCTAssertNil(j.lastJoinRemembered)
        XCTAssertEqual(j.state, .notJoined)
        wifi.refuseRemembered = false
        _ = await j.join(probeFirst: false)
        XCTAssertEqual(wifi.remembers.last, true)
    }

    func testRememberingCanBeTurnedOff() async {
        let wifi = FakeClipWiFi(apUp: true)
        let j = joiner(wifi)
        j.rememberNetwork = false
        _ = await j.join(probeFirst: false)
        XCTAssertEqual(wifi.remembers, [false])
        XCTAssertEqual(j.lastJoinRemembered, false)
    }

    func testRefusedJoinOnceIsNotFound() async {
        let j = HotspotJoiner(configurator: ImmediateHotspotConfigurator(error: .refused("nope")), probe: { false })
        j.rememberNetwork = false
        let s = await j.join(probeFirst: false)
        guard case .unreachable = s else { return XCTFail("\(s)") }
        XCTAssertEqual(j.failure, .notFound)
    }
}

// MARK: - Skip rules

final class SendSkipRuleTests: XCTestCase {

    func status(epoch: Int, tz: Int = 7200, synced: Bool = true) -> ClipStatus {
        ClipStatus(device: .init(name: "PixelClip", id: "a1b2", fw: "0.2.0", hw: "x", protocolVersion: 1),
                   battery: .init(mv: 3900, pct: 70, charging: false),
                   storage: .init(total: 100, used: 0, free: 100),
                   playlist: .init(count: 1, index: 0, current: nil),
                   time: .init(epoch: epoch, tzOffsetS: tz, synced: synced),
                   session: nil, uptimeS: 10)
    }

    func testTimeRules() {
        let now = Date(timeIntervalSince1970: 1_760_100_000)
        let ok = status(epoch: 1_760_100_000)
        // Synced, right zone, no drift, synced from here 3 min ago: skip.
        XCTAssertFalse(SendSkipRules.needsTimeSync(status: ok, readAt: now, lastSyncedAt: now.addingTimeInterval(-180), now: now, tzOffsetS: 7200))
        // Not synced (never, > 24 h, or rebuilt from the anchor).
        XCTAssertTrue(SendSkipRules.needsTimeSync(status: status(epoch: 1_760_100_000, synced: false), readAt: now,
                                                 lastSyncedAt: now, now: now, tzOffsetS: 7200))
        // Older than 10 minutes, or never from this iPhone.
        XCTAssertTrue(SendSkipRules.needsTimeSync(status: ok, readAt: now, lastSyncedAt: now.addingTimeInterval(-601), now: now, tzOffsetS: 7200))
        XCTAssertFalse(SendSkipRules.needsTimeSync(status: ok, readAt: now, lastSyncedAt: now.addingTimeInterval(-599), now: now, tzOffsetS: 7200))
        XCTAssertTrue(SendSkipRules.needsTimeSync(status: ok, readAt: now, lastSyncedAt: nil, now: now, tzOffsetS: 7200))
        // Drift over 2 s, or another time zone (summer time ended).
        XCTAssertTrue(SendSkipRules.needsTimeSync(status: status(epoch: 1_760_100_003), readAt: now, lastSyncedAt: now, now: now, tzOffsetS: 7200))
        XCTAssertTrue(SendSkipRules.needsTimeSync(status: ok, readAt: now, lastSyncedAt: now, now: now, tzOffsetS: 3600))
        // Unknown status.
        XCTAssertTrue(SendSkipRules.needsTimeSync(status: nil, readAt: now, lastSyncedAt: now, now: now))
    }

    func testPlaylistRules() {
        let a = Playlist(items: [.asset("golden-hour-70c9", durationMs: 0, transition: .cut)])
        XCTAssertTrue(SendSkipRules.playlistUnchanged(a, onClip: a))
        XCTAssertFalse(SendSkipRules.playlistUnchanged(a, onClip: nil))
        var b = a
        b.items[0].durationMs = 10_000
        XCTAssertFalse(SendSkipRules.playlistUnchanged(b, onClip: a))
        // Parsed, not text: an empty queue equals no queue, and key order doesn't matter.
        var withQueue = a
        withQueue.queue = []
        XCTAssertTrue(SendSkipRules.playlistUnchanged(withQueue, onClip: a))
        let fromText = try? ClipJSON.decoder().decode(Playlist.self, from: Data(#"{"items":[{"duration_ms":0,"id":"golden-hour-70c9","type":"asset","transition":"cut"}],"version":1}"#.utf8))
        XCTAssertTrue(SendSkipRules.playlistUnchanged(a, onClip: fromText))
        // A reading started at a word always goes out (the clip restarts it on a PUT).
        var reading = Playlist(items: [PlaylistItem(type: .reader, durationMs: 0)])
        reading.items[0].text = "t-1"; reading.items[0].font = "f-1"; reading.items[0].fromWord = 12
        XCTAssertFalse(SendSkipRules.playlistUnchanged(reading, onClip: reading))
    }
}

/// The skip rules end to end against the virtual clip: a second identical send is the inventory
/// read and nothing else.
final class SendSkipVirtualClipTests: XCTestCase {

    func testSecondSendSkipsTimeAndPlaylist() async throws {
        let clip = VirtualClipClient(options: .instant)
        let engine = SyncEngine(client: clip)
        let asset = LocalAsset(id: "golden-hour-70c9", data: try clipAsset(0xF800))
        let playlist = Playlist(items: [.asset(asset.id, durationMs: 0, transition: .cut)])
        let options = { (setTime: Bool, onClip: Playlist?) in
            SyncOptions(deleteOrphans: true, setTime: setTime, endSession: false, skipUnchangedPlaylist: true, clipPlaylist: onClip)
        }

        // First send to a fresh clip: the clock isn't synced, so the rule says set it.
        var st = try await clip.status()
        var readAt = Date()
        XCTAssertTrue(SendSkipRules.needsTimeSync(status: st, readAt: readAt, lastSyncedAt: nil))
        let first = await engine.sync(local: [asset], playlist: playlist, options: options(true, try await clip.playlist()))
        XCTAssertTrue(first.succeeded)
        XCTAssertTrue(first.timeSet)
        XCTAssertTrue(first.playlistUpdated)
        XCTAssertFalse(first.playlistSkipped)
        let syncedAt = Date()

        // Same send a minute later (well, now): synced, recent, same playlist.
        st = try await clip.status()
        readAt = Date()
        let needsTime = SendSkipRules.needsTimeSync(status: st, readAt: readAt, lastSyncedAt: syncedAt)
        XCTAssertFalse(needsTime)
        let before = await clip.requestLog.count
        let second = await engine.sync(local: [asset], playlist: playlist, options: options(needsTime, try await clip.playlist()))
        let log = await Array(clip.requestLog.dropFirst(before))
        XCTAssertTrue(second.succeeded)
        XCTAssertTrue(second.playlistSkipped)
        XCTAssertTrue(second.playlistInPlace)
        XCTAssertFalse(second.timeSet)
        XCTAssertEqual(log, ["GET /playlist", "GET /assets"], "no POST /time, no upload, no PUT /playlist")

        // A different Now goes out.
        let other = LocalAsset(id: "blue-hour-11aa", data: try clipAsset(0x001F))
        let changed = Playlist(items: [.asset(other.id, durationMs: 0, transition: .cut)])
        let third = await engine.sync(local: [asset, other], playlist: changed, options: options(false, try await clip.playlist()))
        XCTAssertTrue(third.playlistUpdated)
        XCTAssertEqual(third.uploaded, [other.id])
        let onClip = try await clip.playlist()
        XCTAssertEqual(onClip, changed)
    }

    func testEngineReadsThePlaylistItselfWhenNotGiven() async throws {
        let clip = VirtualClipClient(options: .instant)
        let engine = SyncEngine(client: clip)
        let asset = LocalAsset(id: "cat-anim-2c1d", data: try clipAsset(0x07E0))
        let playlist = Playlist(items: [.asset(asset.id, durationMs: 0, transition: .cut)])
        _ = await engine.sync(local: [asset], playlist: playlist, options: SyncOptions(endSession: false))
        let r = await engine.sync(local: [asset], playlist: playlist,
                                  options: SyncOptions(setTime: false, endSession: false, skipUnchangedPlaylist: true))
        XCTAssertTrue(r.playlistSkipped)
        let log = await clip.requestLog
        XCTAssertEqual(log.filter { $0 == "PUT /playlist" }.count, 1)
    }

    func testReplacedAssetStillPutsThePlaylist() async throws {
        // Same id, new content: the playlist JSON is identical but it's sent anyway (conservative).
        let clip = VirtualClipClient(options: .instant)
        let engine = SyncEngine(client: clip)
        let v1 = LocalAsset(id: "note-77", data: try clipAsset(0xF800))
        let v2 = LocalAsset(id: "note-77", data: try clipAsset(0x001F))
        let playlist = Playlist(items: [.asset("note-77", durationMs: 0, transition: .cut)])
        _ = await engine.sync(local: [v1], playlist: playlist, options: SyncOptions(endSession: false))
        let r = await engine.sync(local: [v2], playlist: playlist,
                                  options: SyncOptions(setTime: false, endSession: false, skipUnchangedPlaylist: true))
        XCTAssertTrue(r.playlistUpdated)
        XCTAssertFalse(r.playlistSkipped)
    }
}

// MARK: - Timings

final class SendTimelineTests: XCTestCase {
    func testSummaryInOrderWithTotalAndBackgroundEnd() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var t = SendTimeline()
        t.begin(at: t0)
        t.start(.wake, at: t0)
        t.start(.join, at: t0.addingTimeInterval(1.2))     // overlaps: starts when the wake is acknowledged
        t.end(.wake, at: t0.addingTimeInterval(1.2))
        t.end(.join, at: t0.addingTimeInterval(4.6))
        t.start(.upload, at: t0.addingTimeInterval(4.8))
        t.end(.upload, at: t0.addingTimeInterval(5.6))
        t.finish(at: t0.addingTimeInterval(6.1))
        XCTAssertEqual(t.summary, "wake 1.20 s · join 3.40 s · upload 0.80 s · total 6.10 s")
        t.start(.end, at: t0.addingTimeInterval(6.1))
        t.end(.end, at: t0.addingTimeInterval(6.4))
        XCTAssertEqual(t.summary, "wake 1.20 s · join 3.40 s · upload 0.80 s · total 6.10 s (end 0.30 s after)")
        // First end wins; an unstarted step ended is zero-length; long totals lose a decimal.
        t.end(.wake, at: t0.addingTimeInterval(9))
        XCTAssertEqual(t.seconds(.wake) ?? 0, 1.2, accuracy: 0.0001)
        t.end(.connect, at: t0)
        XCTAssertEqual(t.seconds(.connect), 0)
        XCTAssertEqual(SendTimeline.format(12.345), "12.3 s")
        XCTAssertEqual(SendTimeline().summary, "")
    }
}
