import XCTest
@testable import PixelClipKit

/// `PIXELCLIP_TAROT_FLOW_PNG=<dir> swift test --filter TarotFlowPNGTests` writes the clip's screens for one whole draw at
/// Medium text, in both orientations (`normal/`, `flipped/`), as the virtual clip composes them (the same layout the firmware draws), walking the screen
/// list with taps (next) only (PROTOCOL §5f.7, §5f.8): waits, armed, shuffle, three, the five lean screens, the three cards'
/// details, the final hold (at most 11 one-page screens besides the shuffle). Skipped otherwise.
final class TarotFlowPNGTests: XCTestCase {
    func testWriteWholeFlow() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PIXELCLIP_TAROT_FLOW_PNG"] else { throw XCTSkip("set PIXELCLIP_TAROT_FLOW_PNG") }
        // §5f.9: both orientations (the hints sit in the BOOT corner: top-right normally, bottom-left flipped).
        for flipped in [false, true] {
            let out = URL(fileURLWithPath: dir).appendingPathComponent(flipped ? "flipped" : "normal")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try await writeFlow(to: out, flipped: flipped)
        }
    }

    private func writeFlow(to out: URL, flipped: Bool) async throws {
        // Like TarotTests.seededClip(), but with the real Dodal deck (108×206) and keys instead of placeholder frames.
        let clock = ClockBox(TarotTests.t0)
        let clip = VirtualClipClient(options: .instant, clock: { clock.now })
        await clip.setOracleSeed(21)
        try await clip.setTime(TimeSync(epoch: Int(TarotTests.t0.timeIntervalSince1970), tzOffsetS: 0))
        let real = try TarotTests.rendered(.fr)
        var o = TarotTests.item
        try await TarotTests.putReader(clip)
        _ = try await clip.putAsset(id: o.deck, data: real.deck, progress: nil)
        _ = try await clip.putAsset(id: o.keys!, data: real.keys, progress: nil)
        o.faceMs = 0; o.pageMs = 0; o.holdMs = 0          // only taps advance (and no idle timeout), so every screen can be captured
        try await clip.putPlaylist(Playlist(items: [o.playlistItem(durationMs: 0, transition: nil)]))
        if flipped { _ = try await clip.putConfig(ClipConfig(orientation: .flipped)) }
        var n = 0
        func shot(_ name: String) async throws {
            let d = await clip.display()
            n += 1
            try TarotTests.writePNG(d.frame, out.appendingPathComponent(String(format: "%02d-%@.png", n, name)))
            print("FLOW \(n) \(name) key=\(d.key)")
        }
        clock.now += 0.5
        try await shot("waits")
        try await clip.oracleTurn()                         // §5f.8: a tap on waits arms
        clock.now += 0.2
        try await shot("armed")
        try await clip.oracleTurn()                         // a tap on armed deals (the seeded row)
        clock.now += 0.6
        try await shot("shuffle")
        clock.now += 0.7
        try await shot("three")
        var st = try await clip.status()
        for _ in 0..<60 {
            try await clip.oracleTurn()                     // next, and only next
            clock.now += 0.2
            st = try await clip.status()
            guard let o = st.oracle else { break }
            switch o.state {
            case .lean: try await shot("lean-\(o.page)")
            case .detail: try await shot("detail-\(o.page)-card\(o.card)")
            case .hold: try await shot("hold")
            default: break
            }
            if o.state == .hold { break }
        }
        print("FLOW three=\(st.oracle?.three ?? []) screens=\(n)")
        XCTAssertEqual(n, 13, "waits, armed, shuffle, three, five lean, three details, hold")
    }
}
