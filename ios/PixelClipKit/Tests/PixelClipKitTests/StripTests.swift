import CoreText
import XCTest
@testable import PixelClipKit

/// Scrolling strips (PROTOCOL §2 `is_strip`, §4 `scroll`): codec, timing, the virtual clip's window.
final class StripTests: XCTestCase {
    /// Column x has a colour unique to x (so a screen column tells which strip column it shows).
    func stripFrame(width: Int) -> RGB565Frame {
        frame(width, 240) { x, y in y < 4 ? 0 : UInt16(truncatingIfNeeded: x % 2000 + 1) }
    }

    func testStripRoundTripsThroughTheCodec() throws {
        let strip = stripFrame(width: 3001)
        let data = try HCAEncoder.encodeStrip(strip)
        let file = try HCAFile(data: data)
        XCTAssertTrue(file.isStrip)
        XCTAssertFalse(file.isGlyphAtlas)
        XCTAssertEqual(file.header.flags, HCA.Flags.strip.rawValue)
        XCTAssertEqual(file.width, 3001)
        XCTAssertEqual(file.height, 240)
        XCTAssertEqual(file.frameCount, 1)
        XCTAssertEqual(try file.decodeFrame(0), strip)
        XCTAssertEqual(PlaybackEngine.AssetTiming(file: file).stripWidth, 3001)
        // Geometry limits.
        XCTAssertThrowsError(try HCAEncoder.encodeStrip(stripFrame(width: 8193)))
        XCTAssertThrowsError(try HCAEncoder.encodeStrip(RGB565Frame(width: 600, height: 120)))
        XCTAssertThrowsError(try HCAEncoder.encodeStrip(RGB565Frame(width: 536, height: 240)), "a strip is wider than the screen (≥ 537)")
        XCTAssertNoThrow(try HCAEncoder.encodeStrip(RGB565Frame(width: 8192, height: 240)))
    }

    func testScrollBlockJSON() throws {
        let json = #"{"type":"asset","id":"msg-bonne-nuit-91ab","scroll":{"px_per_s":80,"direction":"left","gap_px":120,"loops":3},"transition":"fade"}"#
        let item = try ClipJSON.decoder().decode(PlaylistItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.scroll, PlaylistItem.Scroll(pxPerS: 80, direction: .left, gapPx: 120, loops: 3))
        XCTAssertEqual(item.durationMs, 0, "duration_ms may be omitted")
        let back = try jsonObject(try ClipJSON.encoder().encode(item)) as! NSDictionary
        XCTAssertEqual(back["scroll"] as? NSDictionary, ["px_per_s": 80, "direction": "left", "gap_px": 120, "loops": 3])
        // Every scroll key is optional (firmware defaults: 80 px/s, left, no gap, one pass).
        let bare = try ClipJSON.decoder().decode(PlaylistItem.self, from: Data(#"{"type":"asset","id":"m","scroll":{}}"#.utf8))
        XCTAssertEqual(bare.scroll, PlaylistItem.Scroll(pxPerS: 80, direction: .left, gapPx: 0, loops: nil))
    }

    func testLoopTiming() {
        let s = PlaylistItem.Scroll(pxPerS: 100, direction: .left, gapPx: 64, loops: 3)
        // 536 + 3 × 1000 + 2 × 64 = 3664 px at 100 px/s.
        XCTAssertEqual(StripScroller.travelPx(stripWidth: 1000, scroll: s), 3664)
        XCTAssertEqual(StripScroller.durationMs(stripWidth: 1000, scroll: s), 36_640)
        let timing = PlaybackEngine.AssetTiming(frameDurationsMs: [100], stripWidth: 1000)
        let item = PlaylistItem(type: .asset, id: "s", durationMs: 0, transition: .cut, scroll: s)
        XCTAssertEqual(PlaybackEngine.durationMs(of: item, timing: timing), 36_640)
        var timed = item; timed.durationMs = 5000
        XCTAssertEqual(PlaybackEngine.durationMs(of: timed, timing: timing), 5000, "duration_ms wins")
        // Speed clamps to 10…400.
        XCTAssertEqual(StripScroller.speed(PlaylistItem.Scroll(pxPerS: 900)), 400)
        XCTAssertEqual(StripScroller.speed(PlaylistItem.Scroll(pxPerS: 1)), 10)

        // The engine scrolls for exactly the passes, then moves on.
        let t0 = Date(timeIntervalSince1970: 1_760_100_000)
        var e = PlaybackEngine(now: t0)
        e.setPlaylist(Playlist(items: [item, .asset("next", durationMs: 1000, transition: .cut)]), now: t0)
        let tm: (String) -> PlaybackEngine.AssetTiming? = { $0 == "s" ? timing : .init(frameDurationsMs: [100]) }
        XCTAssertEqual(e.state(at: t0, timing: tm).content, .strip(id: "s", copies: []), "enters from the right edge")
        XCTAssertEqual(e.state(at: t0 + 1, timing: tm).content, .strip(id: "s", copies: [436]))
        // 12 s in: offset 1200 → copy 0 at −664, copy 1 at 400.
        XCTAssertEqual(e.state(at: t0 + 12, timing: tm).content, .strip(id: "s", copies: [-664, 400]))
        // Near the end only the third copy is left, leaving at the left edge; no fourth copy follows.
        XCTAssertEqual(e.state(at: t0 + 36.6, timing: tm).content, .strip(id: "s", copies: [536 - 3660 + 2 * 1064]))
        XCTAssertEqual(e.state(at: t0 + 36.7, timing: tm).currentID, "next")

        // As the only rotation item it scrolls on as an endless tape (firmware `single`).
        var solo = PlaybackEngine(now: t0)
        solo.setPlaylist(Playlist(items: [item]), now: t0)
        XCTAssertEqual(solo.state(at: t0 + 40, timing: tm).content, .strip(id: "s", copies: [536 - 4000 + 3 * 1064]),
                       "a fourth copy follows instead of a restart")

        // Rightward strips enter from the left edge.
        let r = PlaylistItem.Scroll(pxPerS: 100, direction: .right, gapPx: 0, loops: 1)
        XCTAssertEqual(StripScroller.copies(offset: 300, stripWidth: 1000, scroll: r, limit: 1), [-700])
        // Repeating for a duration has no limit.
        XCTAssertEqual(StripScroller.copies(offset: 5000, stripWidth: 1000, scroll: PlaylistItem.Scroll(pxPerS: 100, gapPx: 64), limit: nil),
                       [536 - 5000 + 4 * 1064], "copy 4 covers the screen")
        XCTAssertEqual(StripScroller.copies(offset: 5500, stripWidth: 1000, scroll: PlaylistItem.Scroll(pxPerS: 100, gapPx: 64), limit: nil),
                       [536 - 5500 + 4 * 1064, 536 - 5500 + 5 * 1064], "copy 5 enters after the gap")
    }

    func testVirtualClipScrollsTheRightPixels() async throws {
        let base = Date(timeIntervalSince1970: 1_791_655_200)
        let clock = ClockBox(base)
        let clip = VirtualClipClient(options: .instant, clock: { clock.now })
        let strip = stripFrame(width: 1500)
        _ = try await clip.putAsset(id: "msg-1", data: try HCAEncoder.encodeStrip(strip), progress: nil)
        let listed = try await clip.assets()
        XCTAssertEqual(listed.first?.strip, true)
        XCTAssertEqual(listed.first?.width, 1500)
        let wire = try jsonObject(try ClipJSON.encoder().encode(AssetList(assets: listed))) as! NSDictionary
        XCTAssertEqual(((wire["assets"] as? [NSDictionary])?.first)?["strip"] as? Bool, true, "GET /assets reports strip:true")

        // A strip without scroll is a still of its first 536 px; bad scroll blocks are refused.
        await expectHTTP(422, "invalid_playlist") {
            try await clip.putPlaylist(Playlist(items: [PlaylistItem(type: .asset, id: "msg-1", durationMs: 0, scroll: .init(pxPerS: 500))]))
        }
        let scroll = PlaylistItem.Scroll(pxPerS: 100, direction: .left, gapPx: 50, loops: 2)
        try await clip.putPlaylist(Playlist(items: [PlaylistItem(type: .asset, id: "msg-1", durationMs: 0, transition: .cut, scroll: scroll)]))
        try await clip.endSession()

        clock.now = base + 2   // 200 px in: the strip's first 200 columns fill screen x 336…535
        var d = await clip.display()
        XCTAssertEqual(d.currentID, "msg-1")
        for x in [0, 100, 335] { XCTAssertEqual(d.frame.pixels[120 * 536 + x], 0, "black before the strip at x=\(x)") }
        for x in [336, 400, 535] { XCTAssertEqual(d.frame.pixels[120 * 536 + x], strip.pixels[120 * 1500 + (x - 336)], "x=\(x)") }

        clock.now = base + 16   // 1600 px: copy 0 spans −1064…435, gap 436…485, copy 1 from 486
        d = await clip.display()
        XCTAssertEqual(d.frame.pixels[120 * 536 + 0], strip.pixels[120 * 1500 + 1064])
        XCTAssertEqual(d.frame.pixels[120 * 536 + 435], strip.pixels[120 * 1500 + 1499])
        XCTAssertEqual(d.frame.pixels[120 * 536 + 460], 0, "gap_px of black between repeats")
        XCTAssertEqual(d.frame.pixels[120 * 536 + 486], strip.pixels[120 * 1500 + 0])
        XCTAssertEqual(d.frame, StripScroller.window(strip, copies: [-1064, 486]))

        // Same pixels from /screenshot (the frame the panel shows).
        let shot = try await clip.screenshot()
        XCTAssertEqual(shot, d.frame)
    }

    func testTwentyCharacterMarqueeIsTensOfKB() throws {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 100, nil)
        let spec = MarqueeSpec(text: "Bonne nuit les amis!", motion: .scroll, speed: 120)   // 20 characters
        XCTAssertEqual(spec.text.count, 20)
        XCTAssertTrue(MarqueeRenderer.usesStrip(spec))
        // A short message is padded to the minimum strip width (wider than the screen).
        XCTAssertEqual(MarqueeRenderer.renderStrip(MarqueeSpec(text: "Hi", motion: .scroll), font: font)?.width, 537)
        let strip = try XCTUnwrap(MarqueeRenderer.renderStrip(spec, font: font))
        XCTAssertEqual(strip.image.height, 240)
        XCTAssertLessThanOrEqual(strip.width, 8192)
        XCTAssertEqual(strip.scroll, PlaylistItem.Scroll(pxPerS: 120, direction: .left, gapPx: Int((0.4 * 536).rounded())))
        let data = try HCAEncoder.encodeStrip(CreationEncoder().quantize(strip.image))
        XCTAssertLessThan(data.count, 100_000, "a strip is tens of KB, not megabytes (\(data.count) bytes)")
        XCTAssertGreaterThan(data.count, 2_000)
        let frames = MarqueeRenderer.summary(spec, font: font)
        XCTAssertGreaterThan(frames.frames, 50, "the frame-based export would have needed \(frames.frames) frames")
        // LED too; typewriter / bounce / ticker / still stay frame based, and so does a coloured background.
        var led = spec; led.led = true
        XCTAssertNotNil(MarqueeRenderer.renderStrip(led, font: font))
        for m in [MarqueeSpec.Motion.typewriter, .bounce, .ticker, .still] {
            var s = spec; s.motion = m
            XCTAssertFalse(MarqueeRenderer.usesStrip(s))
        }
        var navy = spec; navy.background = RGBAColor(hex: 0x14213D)
        XCTAssertFalse(MarqueeRenderer.usesStrip(navy))
    }
}
