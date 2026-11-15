import CoreGraphics
import XCTest
@testable import PixelClipKit

/// Battery wording, the frame-based size budget (Ken Burns choices), send-failure copy, the
/// joiner's failure reasons and the firmware's system screens.
final class PolishTests: XCTestCase {

    // MARK: Battery

    func testBatteryLevelsAndSymbols() {
        XCTAssertEqual(BatteryReading(pct: 64).level, .normal)
        XCTAssertEqual(BatteryReading(pct: 20).level, .normal)
        XCTAssertEqual(BatteryReading(pct: 19).level, .low)
        XCTAssertEqual(BatteryReading(pct: 10).level, .low)
        XCTAssertEqual(BatteryReading(pct: 9).level, .critical)
        XCTAssertEqual(BatteryReading(pct: 5, onUSB: true).level, .normal, "USB is never a warning")
        XCTAssertEqual(BatteryReading(pct: 40, mv: 3540).level, .critical, "near the 3.5 V Wi‑Fi cutoff")
        XCTAssertEqual(BatteryReading(pct: nil).level, .normal)
        XCTAssertEqual(BatteryReading(pct: 5).symbolName, "battery.0percent")
        XCTAssertEqual(BatteryReading(pct: 30).symbolName, "battery.25percent")
        XCTAssertEqual(BatteryReading(pct: 55).symbolName, "battery.50percent")
        XCTAssertEqual(BatteryReading(pct: 80).symbolName, "battery.75percent")
        XCTAssertEqual(BatteryReading(pct: 95).symbolName, "battery.100percent")
        XCTAssertEqual(BatteryReading(pct: 30, onUSB: true).symbolName, "battery.100percent.bolt")
        XCTAssertEqual(BatteryReading(pct: 150).pct, 100)
        XCTAssertTrue(BatteryReading(pct: 15).suggestsCharging)
        XCTAssertFalse(BatteryReading(pct: 15, onUSB: true).suggestsCharging)
    }

    func testBatteryFromStatusAndWearEstimate() {
        let b = BatteryReading(ClipStatus.Battery(mv: 3720, pct: 18, charging: false, usbPresent: false))
        XCTAssertEqual(b.level, .low)
        XCTAssertEqual(b.wearMinutesLeft, 50)          // 18 % of 5 h = 54 min → 50
        XCTAssertEqual(b.wearLeftText, "about 50 min")
        XCTAssertEqual(BatteryReading(pct: 100).wearLeftText, "about 5 h")
        XCTAssertEqual(BatteryReading(pct: 50).wearLeftText, "about 2 h 30 min")
        XCTAssertEqual(BatteryReading(pct: 1).wearLeftText, "only a few minutes")
        XCTAssertNil(BatteryReading(pct: 50, onUSB: true).wearLeftText)
        XCTAssertTrue(BatteryReading(ClipStatus.Battery(mv: 3900, pct: 70, charging: true)).onUSB)
        XCTAssertEqual(BatteryReading(pct: 8).accessibilityText, "Battery 8 percent, very low")
        XCTAssertEqual(BatteryReading(pct: 64, onUSB: true).accessibilityText, "Battery 64 percent, charging")
    }

    func testVirtualClipBatteryOverrideFollowsTheFirmwareCurve() async throws {
        XCTAssertEqual(VirtualClipClient.millivolts(forPct: 100), 4200)
        XCTAssertEqual(VirtualClipClient.millivolts(forPct: 15), 3710)
        XCTAssertEqual(VirtualClipClient.millivolts(forPct: 0), 3400)
        XCTAssertEqual(VirtualClipClient.millivolts(forPct: 8), 3658)
        let clip = VirtualClipClient()
        await clip.setBattery(pct: 15, usb: false)
        let b = try await clip.status().battery
        XCTAssertEqual(b?.pct, 15)
        XCTAssertEqual(BatteryReading(b).level, .low)
        await clip.setBattery(pct: 5, usb: true)
        let c = try await clip.status().battery
        XCTAssertEqual(BatteryReading(c).symbolName, "battery.100percent.bolt")
    }

    // MARK: Budget

    func testClipBudgetOnlyLimitsFrameBasedAssets() {
        XCTAssertFalse(ClipBudget.isOverLimit(bytes: 9_000_000, frames: 1))
        XCTAssertFalse(ClipBudget.isOverLimit(bytes: 9_000_000, frames: 1, isStrip: true))
        XCTAssertTrue(ClipBudget.isOverLimit(bytes: 4_000_001, frames: 20))
        XCTAssertFalse(ClipBudget.isOverLimit(bytes: 4_000_000, frames: 20))
    }

    // MARK: Send problems

    func testJoinFailuresMapToActionableCopy() {
        XCTAssertEqual(SendProblem(join: .declined), .joinDeclined)
        XCTAssertEqual(SendProblem(join: .wrongPassword), .wrongPassword)
        XCTAssertEqual(SendProblem(join: .notFound), .clipNotFound)
        XCTAssertEqual(SendProblem(join: .noAnswer), .clipNotAnswering)
        XCTAssertTrue(SendProblem.joinDeclined.message.contains("Join"))
        XCTAssertTrue(SendProblem.clipNotFound.needsButtonPress)
        XCTAssertFalse(SendProblem.joinDeclined.needsButtonPress)
        XCTAssertTrue(SendProblem.joinDeclined.needsConnectionHelp)
    }

    func testClipErrorsMapToProblems() {
        let full = ClipError.http(status: 413, envelope: ErrorEnvelope(error: "no_space", message: "not enough space on the clip"))
        XCTAssertEqual(SendProblem(clip: full, step: "upload", assetName: "Golden Hour"), .clipFull(asset: "Golden Hour"))
        XCTAssertTrue(SendProblem.clipFull(asset: "Golden Hour").message.contains("“Golden Hour”"))
        let bad = ClipError.http(status: 422, envelope: ErrorEnvelope(error: "sha256_mismatch", message: "body does not match"))
        XCTAssertEqual(SendProblem(clip: bad, step: "upload", assetName: "Orbit"), .assetRejected(asset: "Orbit"))
        XCTAssertEqual(SendProblem(clip: .http(status: 422, envelope: nil), step: "playlist"), .playlistRejected)
        XCTAssertEqual(SendProblem(clip: .unreachable("timed out")), .clipNotAnswering)
        XCTAssertEqual(SendProblem(clip: .unreachable("timed out"), batteryWasLow: true), .lowBatteryEndedSession)
        XCTAssertEqual(SendProblem(error: URLError(.networkConnectionLost), batteryWasLow: true), .lowBatteryEndedSession)
        XCTAssertEqual(SendProblem(clip: .protocolTooNew(2)), .appTooOld)
        XCTAssertEqual(SendProblem(clip: .http(status: 500, envelope: ErrorEnvelope(error: "io_error", message: "x"))), .other)
        XCTAssertEqual(SendProblem(error: nil), .other)
        // A report failure carries its clip error through.
        let f = SyncReport.Failure(id: "a1", step: "upload", message: "raw", clipError: full)
        XCTAssertEqual(SendProblem(failure: f, assetName: "Sunset"), .clipFull(asset: "Sunset"))
    }

    func testNoProblemCopyLeaksRawErrors() {
        let all: [SendProblem] = [.joinDeclined, .wrongPassword, .clipNotFound, .clipNotAnswering, .lowBatteryEndedSession, .tooLowToWake,
                                  .clipFull(asset: nil), .clipFull(asset: "A"), .assetRejected(asset: nil), .playlistRejected,
                                  .appTooOld, .other, .clipPasswordReset, .clipPasswordUnknown]
        for p in all {
            XCTAssertFalse(p.title.isEmpty)
            XCTAssertTrue(p.message.hasSuffix("."), p.message)
            for raw in ["HTTP", "422", "413", "error", "nil", "Optional"] {
                XCTAssertFalse(p.message.contains(raw), "\(p): \(p.message)")
            }
        }
    }

    func testSyncReportFailuresKeepTheClipError() async {
        let clip = VirtualClipClient()
        // A playlist with a scene the clip doesn't know: 422 invalid_playlist.
        let report = await SyncEngine(client: clip).sync(local: [], playlist: Playlist(items: [.scene("disco", durationMs: 0)]),
                                                        options: SyncOptions(setTime: false, endSession: false))
        let f = report.failures.first { $0.step == "playlist" }
        XCTAssertEqual(f?.clipError?.code, "invalid_playlist")
        XCTAssertEqual(f.map { SendProblem(failure: $0) }, .playlistRejected)
    }

    // MARK: Joiner

    @MainActor
    func testJoinerRecordsWhyItFailed() async {
        func joiner(_ answers: [Bool], _ error: HotspotJoinError?) -> HotspotJoiner {
            let script = ProbeScript(answers)
            return HotspotJoiner(configurator: ImmediateHotspotConfigurator(error: error), probeAttempts: 2,
                                 probeInterval: .milliseconds(1), probe: { script.next() })
        }
        var j = joiner([], .userDenied); await j.connect(); XCTAssertEqual(j.failure, .declined)
        j = joiner([], .invalidPassphrase); await j.connect(); XCTAssertEqual(j.failure, .wrongPassword)
        j = joiner([], .unavailable("no network")); await j.connect(); XCTAssertEqual(j.failure, .notFound)
        j = joiner([], nil); await j.connect(); XCTAssertEqual(j.failure, .noAnswer)
        j.markDisconnected(); XCTAssertNil(j.failure)
        j = joiner([false, true], nil); await j.connect(); XCTAssertNil(j.failure)
    }

    // MARK: System screens

    func testSystemScreensMatchTheFirmwareLayout() {
        let img = SystemScreen.message("WiFi: PixelClip-3F2A")
        XCTAssertEqual(img.width, ClipCanvas.width); XCTAssertEqual(img.height, ClipCanvas.height)
        let r = ClipRenderer.rasterize(img, transform: CropTransform(scale: 1))
        // 20 characters at scale 4: (20·6−1)·4 = 476 px wide, centred → starts at x = 30; 28 px tall at y = 106.
        func lit(_ x: Int, _ y: Int) -> Bool { r.bytes[(y * 536 + x) * 4] > 128 }
        var minX = 536, maxX = 0, minY = 240, maxY = 0
        for y in 0..<240 { for x in 0..<536 where lit(x, y) { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
        XCTAssertEqual(minY, 106); XCTAssertEqual(maxY, 106 + 27)
        XCTAssertGreaterThanOrEqual(minX, 30); XCTAssertLessThanOrEqual(maxX, 30 + 476)
        XCTAssertEqual(SystemScreen.textWidth(4, "Done"), 92)
        let off = ClipRenderer.rasterize(SystemScreen.off(), transform: CropTransform(scale: 1))
        XCTAssertTrue(stride(from: 0, to: off.bytes.count, by: 4).allSatisfy { off.bytes[$0] == 0 })
        XCTAssertEqual(SystemScreen.charging(bars: 2).width, 536)
    }

    static func gradient(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in stride(from: 0, to: w, by: 8) {
            ctx.setFillColor(CGColor(srgbRed: Double(x) / Double(w), green: 0.4, blue: 1 - Double(x) / Double(w), alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 8, height: h))
        }
        return ctx.makeImage()!
    }
}
