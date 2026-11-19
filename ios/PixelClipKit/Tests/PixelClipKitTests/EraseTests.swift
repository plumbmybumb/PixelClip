import XCTest
@testable import PixelClipKit

/// `POST /erase` (PROTOCOL §4 "Erase"): the virtual clip as the firmware, the fast lane's refusal, the routing, the
/// HTTP request, and a send after an erase.
final class EraseTests: XCTestCase {

    /// A clip with two pictures and a reading (its text, its font and the font's atlases) in the playlist, a queue
    /// entry, a name, a brightness and a set clock.
    private static func fullClip() async throws -> (VirtualClipClient, ReaderDocument) {
        let clip = VirtualClipClient(options: .instant)
        let (doc, file) = ReaderDocument.make(ImportedText(title: "Essai", body: "Un deux trois quatre.", kind: .pasted))
        let font = ReaderTests.testFont
        let pictures = [LocalAsset(id: "a", data: try clipAsset(1)), LocalAsset(id: "b", data: try clipAsset(2, frames: 3))]
        let playlist = Playlist(items: [.reader(text: doc.clipTextID, font: font.id, wpm: 300), .asset("a", durationMs: 5000)],
                                queue: [QueueEntry(id: "q1", at: 4_102_000_000, type: .asset, asset: "b")])
        _ = try await ReaderPusher(client: clip).push(texts: [.init(id: doc.clipTextID, data: file, title: doc.title)], fonts: [font],
                                                      playlist: playlist, libraryAssets: pictures,
                                                      time: TimeSync(epoch: 1_760_100_000, tzOffsetS: 3600))
        _ = try await clip.putConfig(ClipConfig(name: "Clip du soir", brightness: 90))
        return (clip, doc)
    }

    func testEraseRemovesContentAndKeepsTheRest() async throws {
        let (clip, doc) = try await Self.fullClip()
        let before = try await clip.status()
        let assetsBefore = try await clip.assets().count
        XCTAssertGreaterThan(assetsBefore, 2, "the pictures and the font's atlases")
        XCTAssertEqual(before.playlist.current, "reader:\(doc.clipTextID)")
        let configBefore = try await clip.config()

        let report = try await clip.eraseContent()
        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.removed, EraseReport.Removed(assets: assetsBefore, texts: 1, fonts: 1))
        XCTAssertEqual(report.storage, ClipStatus.Storage(total: before.storage.total, used: 0, free: before.storage.total))

        // Nothing listed, the empty playlist, the idle screen.
        let assets = try await clip.assets()
        let texts = try await clip.texts()
        let fonts = try await clip.fonts()
        let playlist = try await clip.playlist()
        XCTAssertTrue(assets.isEmpty)
        XCTAssertTrue(texts.isEmpty)
        XCTAssertTrue(fonts.isEmpty)
        XCTAssertEqual(playlist, .empty)
        XCTAssertTrue(playlist.items.isEmpty && (playlist.queue ?? []).isEmpty)
        let after = try await clip.status()
        XCTAssertEqual(after.storage, report.storage, "the same object as /status.storage")
        XCTAssertNil(after.playlist.current, "the idle screen")
        XCTAssertEqual(after.playlist.count, 0)
        XCTAssertEqual(after.queue?.pending, 0)
        let display = await clip.display()
        XCTAssertNil(display.nowShowing)
        if case .idle = display.content {} else { XCTFail("the panel shows \(display.content), not its idle screen") }
        let reader = try await clip.reader()
        XCTAssertNil(reader.text)

        // Kept: the config, the clock, the session.
        let configAfter = try await clip.config()
        XCTAssertEqual(configAfter, configBefore)
        XCTAssertEqual(configAfter.name, "Clip du soir")
        XCTAssertTrue(after.time.synced)
        XCTAssertEqual(after.time.tzOffsetS, 3600)
        XCTAssertGreaterThanOrEqual(after.time.epoch, before.time.epoch)
        let inSession = await clip.isInSession
        XCTAssertTrue(inSession, "the Wi‑Fi session stays open")
    }

    func testEraseTwiceAnswersZeros() async throws {
        let (clip, _) = try await Self.fullClip()
        _ = try await clip.eraseContent()
        let again = try await clip.eraseContent()
        XCTAssertEqual(again.removed, EraseReport.Removed(assets: 0, texts: 0, fonts: 0))
        XCTAssertEqual(again.storage.used, 0)
        // An empty clip from the start answers the same.
        let fresh = try await VirtualClipClient(options: .instant).eraseContent()
        XCTAssertEqual(fresh.removed, EraseReport.Removed(assets: 0, texts: 0, fonts: 0))
    }

    func testEraseNeedsTheConfirmation() async throws {
        let (clip, _) = try await Self.fullClip()
        await expectHTTP(400, "confirm_required") { _ = try await clip.erase(confirm: nil) }
        await expectHTTP(400, "confirm_required") { _ = try await clip.erase(confirm: "yes") }
        let assets = try await clip.assets()
        let playlist = try await clip.playlist()
        XCTAssertFalse(assets.isEmpty, "nothing changed")
        XCTAssertEqual(playlist.items.count, 2)
        // Firmware that predates it.
        let old = VirtualClipClient(options: .init(latency: .zero, bytesPerSecond: 0, legacyFirmware: true))
        await expectHTTP(404, "not_found") { _ = try await old.eraseContent() }
    }

    @MainActor
    func testFastLaneRefusesErase() async throws {
        let (clip, _) = try await Self.fullClip()
        XCTAssertFalse(FastLaneRoute("POST", "/erase").isEligible)
        XCTAssertTrue(FastLaneRoute("POST", "/erase").isWiFiOnly)
        let body = try ClipJSON.encoder().encode(EraseRequest())
        let answer = await VirtualFastLane.respond(to: FastLaneRequest("POST", "/erase", body: body), clip: clip)
        XCTAssertEqual(answer.status, 413)
        XCTAssertTrue(String(decoding: answer.body, as: UTF8.self).contains("use_wifi"))
        // The fast-lane client doesn't even try.
        let lane = VirtualFastLane(clip: clip, timing: .instant)
        lane.setConnected(true)
        let client = FastLaneClipClient(transport: BLETransport(link: lane))
        do { _ = try await client.eraseContent(); XCTFail("erased over Bluetooth") } catch let e as FastLaneError {
            XCTAssertEqual(e, .needsWiFi)
        }
        // A request that reached the clip over Bluetooth anyway is refused there too.
        do {
            _ = try await VirtualClipClient.$transport.withValue(.bluetooth) { try await clip.eraseContent() }
            XCTFail("erased over Bluetooth")
        } catch let ClipError.http(status, env) {
            XCTAssertEqual(status, 413)
            XCTAssertEqual(env?.error, "use_wifi")
        }
        let assets = try await clip.assets()
        XCTAssertFalse(assets.isEmpty, "nothing was erased")
    }

    @MainActor
    func testSmartClientOpensWiFiForErase() async throws {
        let (clip, _) = try await Self.fullClip()
        let lane = VirtualFastLane(clip: clip, timing: .instant)
        lane.setConnected(true)
        let http = CountingClipClient(clip)
        let links = FakeLinks(lane: FastLaneClipClient(transport: BLETransport(link: lane)))
        let smart = SmartClipClient(http: http, links: links)
        _ = try await smart.status()
        XCTAssertEqual(links.records.last?.transport, .bluetooth)
        let report = try await smart.eraseContent()
        XCTAssertEqual(report.removed.texts, 1)
        XCTAssertEqual(links.wifiOpens, 1, "the erase opens the clip's Wi‑Fi")
        XCTAssertEqual(links.records.last?.transport, .wifi)
        XCTAssertEqual(links.records.last?.fellBack, false, "never tried over Bluetooth")
        let calls = await http.calls
        XCTAssertEqual(calls, ["POST /erase"])
    }

    /// The phone forgot what the clip had: the next send uploads everything it needs and plays.
    func testASendAfterAnEraseUploadsEverythingAgain() async throws {
        let clip = VirtualClipClient(options: .instant)
        let local = [LocalAsset(id: "a", data: try clipAsset(1)), LocalAsset(id: "b", data: try clipAsset(2))]
        let playlist = Playlist(items: [.asset("a", durationMs: 3000), .asset("b", durationMs: 3000)])
        let first = await SyncEngine(client: clip).sync(local: local, playlist: playlist, options: SyncOptions(deleteOrphans: true))
        XCTAssertTrue(first.succeeded, "\(first.failures)")
        XCTAssertEqual(first.uploaded, ["a", "b"])

        _ = try await clip.eraseContent()
        let afterErase = try await clip.playlist()
        let send = await SyncEngine(client: clip).sync(local: local, playlist: playlist,
                                                       options: SyncOptions(deleteOrphans: true, skipUnchangedPlaylist: true,
                                                                            clipPlaylist: afterErase))
        XCTAssertTrue(send.succeeded, "\(send.failures)")
        XCTAssertEqual(send.uploaded, ["a", "b"], "everything goes up again")
        XCTAssertTrue(send.unchanged.isEmpty)
        XCTAssertFalse(send.playlistSkipped)
        let now = try await clip.playlist()
        XCTAssertEqual(now, playlist)
        let status = try await clip.status()
        XCTAssertEqual(status.playlist.current, "a", "it plays")
    }

    /// The real client's request against a stubbed clip: `POST /erase {"confirm":"erase"}`, the answer decoded.
    func testHTTPRequest() async throws {
        IMUStub.reset()
        let client = HTTPClipClient(baseURL: URL(string: "http://imu.test")!, protocolClasses: [IMUStub.self])
        IMUStub.respond("/erase", 200, #"{"ok":true,"removed":{"assets":7,"texts":2,"fonts":1},"storage":{"total":12582912,"used":0,"free":12582912}}"#)
        let r = try await client.eraseContent()
        XCTAssertEqual(r, EraseReport(removed: .init(assets: 7, texts: 2, fonts: 1), storage: .init(total: 12_582_912, used: 0, free: 12_582_912)))
        IMUStub.respond("/erase", 500, #"{"ok":false,"error":"erase_failed","message":"could not remove everything"}"#)
        await expectHTTP(500, "erase_failed") { _ = try await client.eraseContent() }
        // "Send it again": a plain failure with Try again, not one that needs the button or help.
        let failed = SendProblem(error: ClipError.http(status: 500, envelope: ErrorEnvelope(error: "erase_failed", message: "")), step: "erase")
        XCTAssertEqual(failed, .other)
        XCTAssertFalse(failed.needsConnectionHelp || failed.needsButtonPress)
        // A full clip may take ~20 s to erase: far longer than the 6 s small requests get.
        XCTAssertGreaterThanOrEqual(HTTPClipClient.eraseTimeout, 60)
        let reqs = IMUStub.requests
        XCTAssertEqual(reqs.map(\.method), ["POST", "POST"])
        XCTAssertEqual(reqs.map(\.path), ["/erase", "/erase"])
        XCTAssertEqual(String(decoding: reqs[0].body, as: UTF8.self), #"{"confirm":"erase"}"#)
        IMUStub.reset()
    }
}
