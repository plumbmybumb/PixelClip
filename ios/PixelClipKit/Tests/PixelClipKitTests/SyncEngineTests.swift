import XCTest
@testable import PixelClipKit

final class SyncEngineTests: XCTestCase {

    func local(_ id: String, _ color: UInt16) throws -> LocalAsset { LocalAsset(id: id, data: try clipAsset(color)) }

    func testPlanDiffsBySHA() throws {
        let a = try local("a", 1), b = try local("b", 2), c = try local("c", 3)
        let remote = [
            ClipAsset(id: "a", size: a.data.count, sha256: a.sha256.uppercased(), width: 536, height: 240, frames: 1, atlas: false),
            ClipAsset(id: "b", size: 10, sha256: "stale", width: 536, height: 240, frames: 1, atlas: false),
            ClipAsset(id: "orphan", size: 10, sha256: "x", width: 536, height: 240, frames: 1, atlas: false),
            ClipAsset(id: "reader-font-1a2b3c4d-n", size: 10, sha256: "y", width: 30, height: 48, frames: 13, atlas: true),
        ]
        let pl = Playlist(items: [.asset("a", durationMs: 0), .asset("b", durationMs: 0), .asset("c", durationMs: 0),
                                  .asset("ghost", durationMs: 0), .scene("snow", durationMs: 0)])
        let plan = SyncEngine.plan(local: [a, b, c], playlist: pl, remote: remote, options: SyncOptions(deleteOrphans: true))
        XCTAssertEqual(plan.unchanged, ["a"])
        XCTAssertEqual(plan.uploads.map(\.id), ["b", "c"])
        XCTAssertEqual(plan.uploads.map(\.replaces), [true, false])
        XCTAssertEqual(plan.deletions, ["orphan"])     // reader-font- prefix is protected
        XCTAssertEqual(plan.playlist.items.compactMap(\.id), ["a", "b", "c"])  // ghost dropped
        XCTAssertEqual(plan.playlist.items.last?.type, .scene)

        // Kept ids (the playlist's pictures while it's off) are never orphans.
        var keeping = SyncOptions(deleteOrphans: true)
        keeping.keepIDs = ["orphan"]
        XCTAssertEqual(SyncEngine.plan(local: [a, b, c], playlist: pl, remote: remote, options: keeping).deletions, [])

        let keep = SyncEngine.plan(local: [a], playlist: .empty, remote: remote, options: SyncOptions())
        XCTAssertTrue(keep.deletions.isEmpty)
        XCTAssertTrue(keep.uploads.isEmpty)
        // Queue entries' assets are uploaded too; entries pointing at unknown assets are dropped.
        let q = Playlist(items: [], queue: [QueueEntry(id: "q1", at: 10, type: .asset, asset: "c"),
                                            QueueEntry(id: "q2", at: 20, type: .asset, asset: "ghost"),
                                            QueueEntry(id: "q3", at: 30, type: .scene, scene: "snow")])
        let qp = SyncEngine.plan(local: [a, b, c], playlist: q, remote: [], options: SyncOptions())
        XCTAssertEqual(qp.uploads.map(\.id), ["c"])
        XCTAssertEqual(qp.playlist.queue?.map(\.id), ["q1", "q3"])
        let all = SyncEngine.plan(local: [a, b, c], playlist: .empty, remote: [], options: SyncOptions(uploadEntireLibrary: true))
        XCTAssertEqual(all.uploads.count, 3)
    }

    func testFullSyncAgainstVirtualClip() async throws {
        let clip = VirtualClipClient(options: .instant)
        _ = try await clip.putAsset(id: "orphan", data: try clipAsset(77), progress: nil)
        let assets = [try local("a", 1), try local("b", 2)]
        let pl = Playlist(items: [.asset("a", durationMs: 3000), .asset("b", durationMs: 0, loops: 2)])
        let steps = StepBox()
        let report = await SyncEngine(client: clip).sync(local: assets, playlist: pl, options: SyncOptions(deleteOrphans: true),
                                                         timeSource: { TimeSync(epoch: 1_760_100_000, tzOffsetS: 3600) },
                                                         progress: { steps.add($0) })
        XCTAssertTrue(report.succeeded, "\(report.failures)")
        XCTAssertEqual(report.uploaded, ["a", "b"])
        XCTAssertEqual(report.deleted, ["orphan"])
        XCTAssertTrue(report.playlistUpdated && report.timeSet && report.sessionEnded)
        let remotePlaylist = try await clip.playlist()
        XCTAssertEqual(remotePlaylist, pl)
        let log = Array(await clip.requestLog.dropFirst().prefix(7))   // after the setup PUT
        XCTAssertEqual(log, ["GET /assets", "POST /time", "DELETE /assets/orphan", "PUT /assets/a", "PUT /assets/b",
                             "PUT /playlist", "POST /session/end"])
        let progress = steps.values
        XCTAssertEqual(progress.last?.step, .finished)
        XCTAssertEqual(progress.last?.overall, 1)
        XCTAssertEqual(progress.map(\.overall), progress.map(\.overall).sorted(), "progress is monotonic")

        // Second sync: nothing to upload.
        let again = await SyncEngine(client: clip).sync(local: assets, playlist: pl)
        XCTAssertEqual(again.uploaded, [])
        XCTAssertEqual(Set(again.unchanged), ["a", "b"])
    }

    func testPartialFailureDropsOnlyNewItems() async throws {
        let clip = VirtualClipClient(options: .instant)
        let old = try local("old", 5)
        _ = try await clip.putAsset(id: "old", data: old.data, progress: nil)
        await clip.failUploads(of: ["new", "old"])
        let changedOld = try local("old", 6)   // new content for an id the clip already has
        let pl = Playlist(items: [.asset("old", durationMs: 0), .asset("new", durationMs: 0), .asset("ok", durationMs: 0)])
        let report = await SyncEngine(client: clip).sync(local: [changedOld, try local("new", 7), try local("ok", 8)], playlist: pl)
        XCTAssertFalse(report.succeeded)
        XCTAssertEqual(Set(report.failures.compactMap(\.id)), ["old", "new"])
        XCTAssertEqual(report.uploaded, ["ok"])
        XCTAssertEqual(report.droppedFromPlaylist, ["new"])
        XCTAssertTrue(report.playlistUpdated)
        let remote = try await clip.playlist()
        XCTAssertEqual(remote.items.compactMap(\.id), ["old", "ok"])
    }

    func testLostConnectionStopsEarly() async throws {
        let clip = VirtualClipClient(options: .instant)
        await clip.setReachable(false)
        let report = await SyncEngine(client: clip).sync(local: [try local("a", 1)], playlist: Playlist(items: [.asset("a", durationMs: 0)]))
        XCTAssertTrue(report.lostConnection)
        XCTAssertEqual(report.failures.first?.step, "inventory")
        XCTAssertFalse(report.playlistUpdated)
    }

    func testShowNowUploadsOnlyWhenNeeded() async throws {
        let clip = VirtualClipClient(options: .instant)
        let a = try local("a", 1)
        try await SyncEngine(client: clip).showNow(a)
        try await SyncEngine(client: clip).showNow(a, durationMs: 5000)
        let log = await clip.requestLog
        XCTAssertEqual(log.filter { $0.hasPrefix("PUT") }, ["PUT /assets/a"])
        XCTAssertEqual(log.filter { $0.hasPrefix("POST /show") }.count, 2)
    }
}

final class StepBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [SyncProgress] = []
    func add(_ v: SyncProgress) { lock.lock(); _values.append(v); lock.unlock() }
    var values: [SyncProgress] { lock.lock(); defer { lock.unlock() }; return _values }
}
