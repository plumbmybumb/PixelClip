import Foundation

/// How a scrolling strip (PROTOCOL §2 `is_strip`, §4 `scroll`) moves across the 536-px screen.
/// Shared by the playback engine, the virtual clip, the previews and the library's timings.
///
/// Matches the firmware's `strip_compose` (player.c; see README "Firmware alignment and gaps"):
/// - The strip enters from the right edge for `left` (from the left edge for `right`) and moves at
///   `px_per_s`, clamped to 10–400. Copies repeat every `width + gap_px` pixels with black between.
/// - With `duration_ms == 0` the item plays `loops` passes (min 1): the strip enters, goes by
///   `loops` times, and the last copy leaves the screen completely, so the travel is
///   `536 + loops × width + (loops − 1) × gap_px` pixels.
/// - With `duration_ms > 0` the copies repeat for as long as the item plays.
public enum StripScroller {
    public static let canvasWidth = ClipCanvas.width

    public static func speed(_ scroll: PlaylistItem.Scroll) -> Int {
        min(max(scroll.pxPerS, PlaylistItem.Scroll.speedRange.lowerBound), PlaylistItem.Scroll.speedRange.upperBound)
    }

    public static func loops(_ scroll: PlaylistItem.Scroll) -> Int { max(1, scroll.loops ?? 1) }

    /// Distance between the left edges of consecutive copies.
    public static func period(stripWidth: Int, scroll: PlaylistItem.Scroll) -> Int { max(1, stripWidth + max(0, scroll.gapPx)) }

    /// Pixels travelled over `loops` passes until the last copy has left the screen.
    public static func travelPx(stripWidth: Int, scroll: PlaylistItem.Scroll, canvasWidth: Int = canvasWidth) -> Int {
        let n = loops(scroll)
        return canvasWidth + n * stripWidth + (n - 1) * max(0, scroll.gapPx)
    }

    /// Length of a `loops`-pass item (`duration_ms == 0`).
    public static func durationMs(stripWidth: Int, scroll: PlaylistItem.Scroll, canvasWidth: Int = canvasWidth) -> Int {
        let travel = travelPx(stripWidth: stripWidth, scroll: scroll, canvasWidth: canvasWidth)
        let v = speed(scroll)
        return (travel * 1000 + v - 1) / v
    }

    /// Pixels travelled `t` ms into the item.
    public static func offsetPx(atMs t: Int, scroll: PlaylistItem.Scroll) -> Int { max(0, t) * speed(scroll) / 1000 }

    /// Screen x of the left edge of every copy at least partly visible after travelling `offset`
    /// pixels. `limit` caps the number of copies (the `loops` passes); nil repeats forever.
    public static func copies(offset: Int, stripWidth: Int, scroll: PlaylistItem.Scroll, limit: Int?,
                              canvasWidth: Int = canvasWidth) -> [Int] {
        let p = period(stripWidth: stripWidth, scroll: scroll)
        var out: [Int] = []
        // Copy k (k ≥ 0) for `left`: x = canvas − offset + k·p. For `right`: x = offset − width − k·p.
        let firstK: Int
        switch scroll.direction {
        case .left:
            // Visible when x < canvas and x + width > 0 → k > (offset − canvas − width) / p.
            firstK = max(0, Int((Double(offset - canvasWidth - stripWidth) / Double(p)).rounded(.down)) + 1)
        case .right:
            // x = offset − width − k·p; visible when x < canvas → k > (offset − width − canvas) / p.
            firstK = max(0, Int((Double(offset - stripWidth - canvasWidth) / Double(p)).rounded(.down)) + 1)
        }
        var k = firstK
        while limit.map({ k < $0 }) ?? true {
            let x = scroll.direction == .left ? canvasWidth - offset + k * p : offset - stripWidth - k * p
            let visible = x < canvasWidth && x + stripWidth > 0
            if visible { out.append(x) }
            // Past the screen in the direction new copies come from: no more visible copies.
            if scroll.direction == .left ? x >= canvasWidth : x + stripWidth <= 0 { break }
            k += 1
        }
        return out
    }

    /// The 536-wide screen: black with the strip's copies at `xs` (row-wise copies, like the device).
    public static func window(_ strip: RGB565Frame, copies xs: [Int], canvasWidth: Int = canvasWidth) -> RGB565Frame {
        let H = strip.height, W = strip.width
        var out = [UInt16](repeating: 0, count: canvasWidth * H)
        strip.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for x in xs {
                    let x0 = max(0, x), x1 = min(canvasWidth, x + W)
                    guard x0 < x1 else { continue }
                    let n = x1 - x0
                    for y in 0..<H {
                        let s = y * W + (x0 - x), d = y * canvasWidth + x0
                        dst.baseAddress!.advanced(by: d).update(from: src.baseAddress!.advanced(by: s), count: n)
                    }
                }
            }
        }
        return RGB565Frame(width: canvasWidth, height: H, pixels: out)
    }

    /// A strip uploaded without `scroll`: a still of its first 536 px.
    public static func firstScreen(_ strip: RGB565Frame, canvasWidth: Int = canvasWidth) -> RGB565Frame {
        window(strip, copies: [0], canvasWidth: canvasWidth)
    }
}
